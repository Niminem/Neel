## t_jsproxy.nim - the `js` proxy: dot-operator expansion, routing, waits, the
## bridge seam, and one round trip through the real server.
##
## Unit tests inject a recording send proc and a fake two-window resolver via
## `initJsBridge`; the integration test plugs in `Server.send` and a scripted
## WebSocket client. Every wait and read is bounded (3 s max).

import std/[unittest, json, locks, os, monotimes, times, typedthreads, net,
            nativesockets, strutils, options]
import neel/[jsproxy, protocol, server, websocket, http, expose]

const
  IoTimeout = 3000
    ## Milliseconds any single wait or client read may take.
  Key = [0x37'u8, 0xFA, 0x21, 0x3D]
    ## RFC 6455 section 5.7 example masking key.
  RfcKey = "dGhlIHNhbXBsZSBub25jZQ=="
    ## RFC 6455 section 1.3 example `Sec-WebSocket-Key`.
  ConnA = ConnId(101)
  ConnB = ConnId(202)
  WinA = 1
  WinB = 2

type
  Color = enum
    red, green, blue
  Point = object
    x, y: int

# --- fake bridge -------------------------------------------------------------------

type
  Fake = object
    ## Shared between the test thread, the injected procs, and replier
    ## threads; `lock` guards `sent` and `sendOk`.
    lock: Lock
    sent: seq[tuple[conn: ConnId; text: string]]
    sendOk: bool
    idsA, idsB: IdAllocator
    table: PendingTable

var fake: Fake
initLock fake.lock

proc fakeSend(conn: ConnId; text: string): bool {.gcsafe.} =
  {.cast(gcsafe).}: # test global, guarded by its lock
    acquire fake.lock
    fake.sent.add((conn, text))
    result = fake.sendOk
    release fake.lock

proc fakeResolve(windowId: int): WindowRoute {.gcsafe.} =
  {.cast(gcsafe).}: # the allocators are plain atomics on a test global
    case windowId
    of WinA: WindowRoute(conn: ConnA, ids: addr fake.idsA)
    of WinB: WindowRoute(conn: ConnB, ids: addr fake.idsB)
    else: WindowRoute()

proc sentRaw(): seq[tuple[conn: ConnId; text: string]] =
  acquire fake.lock
  result = fake.sent
  release fake.lock

proc sentMsgs(): seq[tuple[conn: ConnId; msg: Msg]] =
  for (conn, text) in sentRaw():
    result.add((conn, decode(text)))

proc setSendOk(ok: bool) =
  acquire fake.lock
  fake.sendOk = ok
  release fake.lock

proc elapsedMs(t0: MonoTime): int =
  int((getMonoTime() - t0).inMilliseconds)

proc waitUntil(deadlineMs: int; cond: proc(): bool): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = deadlineMs)
  while getMonoTime() < deadline:
    if cond():
      return true
    sleep(1)
  cond()

template jsTest(name: string; body: untyped) =
  test name:
    acquire fake.lock
    fake.sent = @[]
    fake.sendOk = true
    release fake.lock
    fake.table = newPendingTable()
    initJsBridge(fakeSend, fakeResolve, fake.table)
    try:
      body
    finally:
      clearCurrentWindow()
      resetJsBridge()

# --- replier threads -------------------------------------------------------------------

type
  ReplyMode = enum
    rmRet, rmErr, rmDisconnect

  Replier = object
    ## Waits for the first `call` with an id sent to `conn`, then answers it
    ## through the pending table from its own thread.
    conn: ConnId
    mode: ReplyMode
    delayMs: int
    value: JsonNode
    errKind, errMsg: string
    found: bool
    call: Msg
    completed: bool

proc findCall(conn: ConnId; call: var Msg): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire fake.lock
    for (c, text) in fake.sent:
      if c == conn:
        let m = decode(text)
        if m.kind == msgCall and m.hasId:
          call = m
          result = true
          break
    release fake.lock

proc replier(r: ptr Replier) {.thread.} =
  let deadline = getMonoTime() + initDuration(milliseconds = IoTimeout)
  var call: Msg
  while getMonoTime() < deadline and not findCall(r.conn, call):
    sleep(1)
  if call.kind != msgCall or not call.hasId:
    return
  r.found = true
  r.call = call
  if r.delayMs > 0:
    sleep(r.delayMs)
  {.cast(gcsafe).}:
    case r.mode
    of rmRet:
      r.completed = fake.table.complete(r.conn, call.id, retMsg(call.id, r.value))
    of rmErr:
      r.completed = fake.table.complete(r.conn, call.id,
                                        errMsg(call.id, r.errKind, r.errMsg))
    of rmDisconnect:
      discard fake.table.disconnect(r.conn)

template withReplier(r: var Replier; body: untyped) =
  var th: Thread[ptr Replier]
  createThread(th, replier, addr r)
  try:
    body
  finally:
    joinThread(th)

# --- expansion -------------------------------------------------------------------

suite "js: expansion":
  jsTest "js.foo(1, \"x\", true) sends a fire-and-forget call":
    setCurrentWindow(WinA)
    js.foo(1, "x", true)
    let raw = sentRaw()
    check raw.len == 1
    check raw[0].conn == ConnA
    check raw[0].text == """{"t":"call","name":"foo","args":[1,"x",true]}"""
    let m = decode(raw[0].text)
    check m == callMsg("foo", @[%1, %"x", %true])
    check not m.hasId
    check fake.table.pendingCount == 0

  jsTest "js.noArgs() sends an empty args array":
    setCurrentWindow(WinA)
    js.noArgs()
    check sentRaw()[0].text == """{"t":"call","name":"noArgs","args":[]}"""

  jsTest "arguments are encoded the way exposed-proc results are":
    setCurrentWindow(WinA)
    let pts = @[Point(x: 3, y: 4)]
    js.draw(Point(x: 1, y: 2), @[1, 2, 3], green, 2.5, pts, %*{"k": [nil]},
            newJNull(), "s" & "tr", 7 - 1)
    let m = sentMsgs()[0].msg
    check m.name == "draw"
    check m.args == @[%*{"x": 1, "y": 2}, %*[1, 2, 3], %"green", %2.5,
                      %*[{"x": 3, "y": 4}], %*{"k": [nil]}, newJNull(),
                      %"str", %6]
    check m.args[0] == convertResult(Point(x: 1, y: 2))
    check m.args[2] == convertResult(green)

  jsTest "js.wait.foo(1) sends with a positive id and blocks for the reply":
    setCurrentWindow(WinA)
    var r = Replier(conn: ConnA, mode: rmRet, delayMs: 40, value: %*{"ok": true})
    let t0 = getMonoTime()
    var v: JsonNode
    withReplier(r):
      v = js.wait.foo(1)
    check elapsedMs(t0) >= 35
    check v == %*{"ok": true}
    check r.found
    check r.completed
    check r.call.id > 0
    check r.call.name == "foo"
    check r.call.args == @[%1]
    check sentRaw()[0].text.startsWith("""{"t":"call","id":""")
    check fake.table.pendingCount == 0

  jsTest "js.wait(50).foo() honours its timeout":
    setCurrentWindow(WinA)
    let t0 = getMonoTime()
    expect NeelTimeoutError:
      discard js.wait(50).foo()
    let took = elapsedMs(t0)
    check took >= 45   # `inMilliseconds` truncates; the deadline is 50 ms
    check took < 1000
    check fake.table.pendingCount == 0
    let m = sentMsgs()[0].msg
    check m.hasId
    check m.name == "foo"
    check m.args.len == 0

  jsTest "ids come from the window's allocator and increase per connection":
    setCurrentWindow(WinA)
    expect NeelTimeoutError: discard js.wait(1).a()
    expect NeelTimeoutError: discard js.wait(1).b()
    expect NeelTimeoutError: discard initJsProxy(WinB).wait(1).c()
    let msgs = sentMsgs()
    check msgs[0].msg.id > 0
    check msgs[1].msg.id == msgs[0].msg.id + 1
    check msgs[2].conn == ConnB
    check msgs[2].msg.id > 0

  test "bare js.foo without parentheses does not compile; js.foo() is void":
    check not compiles(js.foo)
    check not compiles((let x = js.foo(); x))
    check compiles((let v: JsonNode = js.wait.foo(); v))

  test "the proxies are plain int objects":
    check js.windowId == CurrentWindow
    check js.wait.timeoutMs == UseDefaultTimeout
    check js.wait(250).timeoutMs == 250
    check initJsProxy(7).windowId == 7
    check initJsProxy(7).wait.windowId == 7
    check sizeof(JsProxy) == sizeof(int)
    check sizeof(JsWaitProxy) == 2 * sizeof(int)

# --- routing ---------------------------------------------------------------------

type
  ThreadProbe = object
    windowId: int
    raised: bool

proc probe(p: ptr ThreadProbe) {.thread.} =
  p.windowId = currentWindowId()
  try:
    js.foo()
  except NeelNoWindowError:
    p.raised = true
  except CatchableError:
    discard

suite "js: routing":
  jsTest "js.foo() goes to the thread's current window":
    withCurrentWindow(WinA):
      js.a()
    withCurrentWindow(WinB):
      js.b()
    let msgs = sentMsgs()
    check msgs.len == 2
    check msgs[0].conn == ConnA
    check msgs[0].msg.name == "a"
    check msgs[1].conn == ConnB
    check msgs[1].msg.name == "b"

  jsTest "an explicit proxy targets its window regardless of the thread-local":
    let win = initJsProxy(WinB)
    withCurrentWindow(WinA):
      win.foo(1)
      js.bar()
    clearCurrentWindow()
    win.baz()
    expect NeelTimeoutError:
      discard win.wait(20).qux()
    let msgs = sentMsgs()
    check msgs.len == 4
    check msgs[0].conn == ConnB
    check msgs[1].conn == ConnA
    check msgs[2].conn == ConnB
    check msgs[3].conn == ConnB
    check msgs[3].msg.hasId

  jsTest "withCurrentWindow restores the previous window, also on an exception":
    check currentWindowId() == NoWindow
    setCurrentWindow(WinA)
    withCurrentWindow(WinB):
      check currentWindowId() == WinB
      withCurrentWindow(WinA):
        check currentWindowId() == WinA
      check currentWindowId() == WinB
    check currentWindowId() == WinA
    try:
      withCurrentWindow(WinB):
        raise newException(ValueError, "boom")
    except ValueError:
      discard
    check currentWindowId() == WinA
    clearCurrentWindow()
    check currentWindowId() == NoWindow

  jsTest "no current window raises NeelNoWindowError for both proxies":
    expect NeelNoWindowError:
      js.foo()
    expect NeelNoWindowError:
      discard js.wait.foo()
    expect NeelNoWindowError:
      discard js.wait(10).foo()
    check sentRaw().len == 0
    check fake.table.pendingCount == 0

  jsTest "a window id that is not connected raises NeelNoWindowError":
    withCurrentWindow(99):
      expect NeelNoWindowError:
        js.foo()
    expect NeelNoWindowError:
      initJsProxy(99).foo()
    expect NeelNoWindowError:
      discard initJsProxy(99).wait.foo()
    check sentRaw().len == 0
    check fake.table.pendingCount == 0

  jsTest "an uninitialised bridge raises NeelNoWindowError":
    resetJsBridge()
    setCurrentWindow(WinA)
    expect NeelNoWindowError:
      js.foo()
    expect NeelNoWindowError:
      discard initJsProxy(WinA).wait.foo()
    check sentRaw().len == 0

  jsTest "the current window is per thread":
    setCurrentWindow(WinA)
    var p: ThreadProbe
    var th: Thread[ptr ThreadProbe]
    createThread(th, probe, addr p)
    joinThread(th)
    check p.windowId == NoWindow
    check p.raised
    check currentWindowId() == WinA
    check sentRaw().len == 0

# --- waits -----------------------------------------------------------------------

suite "js: waits":
  jsTest "a ret delivered through PendingTable.complete from another thread is returned":
    setCurrentWindow(WinA)
    var r = Replier(conn: ConnA, mode: rmRet, delayMs: 10, value: %42)
    var n: int
    withReplier(r):
      n = js.wait.answer().to(int)
    check n == 42
    check r.completed
    check fake.table.pendingCount == 0

  jsTest "an err reply raises NeelRemoteError with the forwarded kind":
    setCurrentWindow(WinA)
    var r = Replier(conn: ConnA, mode: rmErr, delayMs: 10,
                    errKind: "TypeError", errMsg: "x is not a function")
    var raised = false
    withReplier(r):
      try:
        discard js.wait.foo("x")
      except NeelRemoteError as e:
        raised = true
        check e.kind == "TypeError"
        check e.msg == "x is not a function"
    check raised
    check fake.table.pendingCount == 0

  jsTest "the bridge's default timeout applies to js.wait without an argument":
    resetJsBridge()
    initJsBridge(fakeSend, fakeResolve, fake.table, defaultTimeoutMs = 80)
    setCurrentWindow(WinA)
    let t0 = getMonoTime()
    expect NeelTimeoutError:
      discard js.wait.foo()
    let took = elapsedMs(t0)
    check took >= 75   # `inMilliseconds` truncates; the deadline is 80 ms
    check took < 1000
    check fake.table.pendingCount == 0

  jsTest "a send proc that returns false raises NeelDisconnectedError and leaves nothing pending":
    setCurrentWindow(WinA)
    setSendOk(false)
    expect NeelDisconnectedError:
      discard js.wait.foo(1)
    check fake.table.pendingCount == 0
    let msgs = sentMsgs()
    check msgs.len == 1   # the send was attempted, with an id
    check msgs[0].msg.hasId
    # Fire-and-forget never learns about the failure.
    js.bar()
    check sentRaw().len == 2

  jsTest "disconnect during a wait raises NeelDisconnectedError":
    setCurrentWindow(WinA)
    var r = Replier(conn: ConnA, mode: rmDisconnect, delayMs: 30)
    let t0 = getMonoTime()
    withReplier(r):
      expect NeelDisconnectedError:
        discard js.wait.foo()
    check elapsedMs(t0) < 2000
    check r.found
    check fake.table.pendingCount == 0

# --- escape hatch ----------------------------------------------------------------

suite "js: escape hatch":
  jsTest "jsSend / jsCallWait reach names that collide with Nim procs":
    setCurrentWindow(WinA)
    jsSend(js, "echo", @[%"x"])
    jsSend(js, "repr", @[])
    expect NeelTimeoutError:
      discard jsCallWait(js.wait(20), "len", @[%"abc"])
    let msgs = sentMsgs()
    check msgs.len == 3
    check msgs[0].msg == callMsg("echo", @[%"x"])
    check msgs[1].msg == callMsg("repr", @[])
    check msgs[2].msg.name == "len"
    check msgs[2].msg.hasId

  jsTest "dynamic names and explicit proxies work through the escape hatch":
    let name = "handler" & $3
    jsSend(initJsProxy(WinB), name, @[%1])
    let msgs = sentMsgs()
    check msgs[0].conn == ConnB
    check msgs[0].msg.name == "handler3"

  jsTest "js.wait.foo(...).to(T) chains":
    setCurrentWindow(WinA)
    var r = Replier(conn: ConnA, mode: rmRet, value: %*{"x": 1, "y": 2})
    var p: Point
    withReplier(r):
      p = js.wait.point().to(Point)
    check p == Point(x: 1, y: 2)

# --- integration -----------------------------------------------------------------

type
  Integ = object
    ## State of the integration test, shared with the server hooks.
    lock: Lock
    srv: Server
    table: PendingTable
    conn: ConnId
    connected: bool
    ids: IdAllocator
    replies: seq[Msg]

  WsClient = object
    sock: Socket
    decoder: FrameDecoder
    buf: string

var integ: Integ

proc integSend(conn: ConnId; text: string): bool {.gcsafe.} =
  {.cast(gcsafe).}: # the Server ref is written once before listen
    integ.srv.send(conn, text)

proc integResolve(windowId: int): WindowRoute {.gcsafe.} =
  ## Window 1 is whatever connection upgraded last (Task 12 keeps a table).
  {.cast(gcsafe).}:
    acquire integ.lock
    if windowId == 1 and integ.connected:
      result = WindowRoute(conn: integ.conn, ids: addr integ.ids)
    release integ.lock

proc integDispatch(name: string; args: seq[JsonNode]): JsonNode {.gcsafe.} =
  ## Stands in for the generated dispatcher: an "exposed proc" that calls
  ## back into the browser and returns what it answered.
  case name
  of "trigger": js.wait.foo(args[0])
  of "triggerTimeout": js.wait(100).slow()
  else: raiseUnknownProc(name)

proc integRequest(conn: ConnId; req: HttpRequest): RequestAction {.gcsafe.} =
  if req.path == "/ws" and isWebSocketUpgrade(req):
    {.cast(gcsafe).}:
      acquire integ.lock
      integ.conn = conn
      integ.connected = true
      release integ.lock
    upgrade()
  else:
    respond(notFound())

proc integMessage(conn: ConnId; text: string) {.gcsafe.} =
  ## The Task 13 `onMessage` recipe.
  let m = decode(text)
  case m.kind
  of msgCall:
    var reply: Option[Msg]
    withCurrentWindow(1):
      reply = handleCall(m, integDispatch)
    if reply.isSome:
      {.cast(gcsafe).}:
        acquire integ.lock
        integ.replies.add reply.get
        release integ.lock
        discard integ.srv.send(conn, encode(reply.get))
  of msgRet, msgErr:
    {.cast(gcsafe).}:
      discard integ.table.complete(conn, m.id, m)

proc integClose(conn: ConnId) {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire integ.lock
    if integ.conn == conn:
      integ.connected = false
    release integ.lock
    discard integ.table.disconnect(conn)

proc lastReplyKind(): string =
  acquire integ.lock
  if integ.replies.len > 0 and integ.replies[^1].kind == msgErr:
    result = integ.replies[^1].error.kind
  release integ.lock

proc recvSome(sock: Socket; maxLen = 65536): string =
  ## Whatever is readable within `IoTimeout` (`""` on EOF); see t_server.nim.
  var fds = @[sock.getFd()]
  if selectRead(fds, IoTimeout) == 0:
    raise newException(TimeoutError, "read timed out")
  result = newString(maxLen)
  let n = sock.recv(addr result[0], maxLen)
  if n < 0:
    raiseOSError(osLastError())
  result.setLen(n)

proc handshake(port: int): WsClient =
  result.sock = newSocket(buffered = false)
  result.sock.connect("127.0.0.1", Port(port))
  result.decoder = initFrameDecoder(frClient)
  result.sock.send("GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\n" &
                   "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
                   "Sec-WebSocket-Key: " & RfcKey & "\r\n" &
                   "Sec-WebSocket-Version: 13\r\n\r\n")
  let statusLine = result.sock.recvLine(IoTimeout)
  doAssert statusLine.startsWith("HTTP/1.1 101"), "upgrade failed: " & statusLine
  while true:
    let line = result.sock.recvLine(IoTimeout)
    if line.len == 0 or line == "\r\n":
      break

proc readMsg(c: var WsClient): Msg =
  while true:
    let r = c.decoder.decodeFrame(c.buf)
    if r.status == fsComplete:
      c.buf.delete(0 ..< r.consumed)
      doAssert r.frame.opcode == opText, "expected a text frame"
      return decode(r.frame.payload)
    let chunk = c.sock.recvSome()
    if chunk.len == 0:
      raise newException(IOError, "connection closed while waiting for a frame")
    c.buf.add chunk

proc sendMsg(c: WsClient; m: Msg) =
  c.sock.send(encodeText(encode(m), Key))

proc integRelease() {.gcsafe.} =
  ## `shutdown`'s `beforeJoin`, as in `runApp`: the replies and the pending
  ## table were grown on workers, so they are freed while those still live.
  {.cast(gcsafe).}:
    resetJsBridge()
    acquire integ.lock
    integ.replies = @[]
    release integ.lock
    integ.table = nil

suite "js: integration with the server":
  test "a worker's js.wait round-trips through the real server":
    initLock integ.lock
    integ.table = newPendingTable()
    integ.replies = @[]
    integ.connected = false
    integ.srv = newServer(onRequest = integRequest, onMessage = integMessage,
                          onClose = integClose, workers = 4,
                          queueCapacity = 32, closeTimeoutMs = 500)
    initJsBridge(integSend, integResolve, integ.table, defaultTimeoutMs = 2000)
    try:
      integ.srv.listen(0)
      var c = handshake(integ.srv.port)
      # ret: the client answers the Nim -> JS call and the exposed proc's
      # reply carries that value back.
      c.sendMsg(callMsg("trigger", @[%1], id = 1))
      let call = c.readMsg()
      check call.kind == msgCall
      check call.hasId
      check call.name == "foo"
      check call.args == @[%1]
      c.sendMsg(retMsg(call.id, %"pong"))
      check c.readMsg() == retMsg(1, %"pong")
      # err: the JS error kind is forwarded through NeelRemoteError.
      c.sendMsg(callMsg("trigger", @[%2], id = 2))
      let call2 = c.readMsg()
      check call2.id > call.id
      c.sendMsg(errMsg(call2.id, "TypeError", "boom"))
      check c.readMsg() == errMsg(2, "TypeError", "boom")
      # timeout: nobody answers `slow`.
      c.sendMsg(callMsg("triggerTimeout", @[], id = 3))
      let call3 = c.readMsg()
      check call3.name == "slow"
      let t0 = getMonoTime()
      let err3 = c.readMsg()
      check elapsedMs(t0) < IoTimeout
      check err3.kind == msgErr
      check err3.id == 3
      check err3.error.kind == "NeelTimeoutError"
      # disconnect: the socket dies while a worker waits; onClose ->
      # disconnect fails the waiter and the reply can no longer be sent.
      c.sendMsg(callMsg("trigger", @[%4], id = 4))
      let call4 = c.readMsg()
      check call4.name == "foo"
      c.sock.close()
      check waitUntil(IoTimeout, proc(): bool = lastReplyKind() == "NeelDisconnectedError")
      check integ.table.pendingCount == 0
      acquire integ.lock
      check not integ.connected
      release integ.lock
    finally:
      integ.srv.shutdown(beforeJoin = integRelease)
      deinitLock integ.lock
