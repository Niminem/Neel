## t_server.nim - integration tests against the IO loop with a std/net client.
##
## Every server uses `port = 0`, every socket operation is bounded by a
## timeout, and every server is shut down in a `finally`.

import std/[unittest, net, nativesockets, strutils, algorithm, os, locks,
            monotimes, times, tables]
import neel/[server, http, websocket]

const
  IoTimeout = 3000
    ## Milliseconds any single client read may take before the test fails.
  Key = [0x37'u8, 0xFA, 0x21, 0x3D]
    ## RFC 6455 section 5.7 example masking key.
  RfcKey = "dGhlIHNhbXBsZSBub25jZQ=="
    ## RFC 6455 section 1.3 example `Sec-WebSocket-Key`.
  RfcAccept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

type
  State = object
    ## Shared between the test thread and the hooks (through a `ptr`).
    lock: Lock
    opened: seq[ConnId]
    closed: seq[ConnId]
    messages: seq[string]
    requests: int

  WsClient = object
    sock: Socket
    decoder: FrameDecoder
    buf: string

  Bag = object
    ## Shutdown-ordering state shared with the hooks (through a `ptr`).
    lock: Lock
    closes: int
    workersSeen: int     # worker threads that ran `noteWorker`
    workersExited: int   # ... and have since exited
    grown: Table[int, string]  # storage allocated on workers

var workerNoted {.threadvar.}: bool

# --- helpers ---------------------------------------------------------------------

proc waitUntil(deadlineMs: int; cond: proc(): bool): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = deadlineMs)
  while getMonoTime() < deadline:
    if cond():
      return true
    sleep(1)
  cond()

proc rehome[T](x: var T) =
  ## Replaces `x` with a copy made on the calling thread; the original's
  ## blocks are freed now, while the threads that allocated them still live.
  let copy = x
  x = copy

proc releaseState(st: ptr State): BeforeJoinHook =
  ## `shutdown`'s `beforeJoin` for a `State` the hooks grew on workers, so
  ## the test thread can keep reading it and free it after the join.
  result = proc() {.gcsafe.} =
    acquire st.lock
    rehome(st.opened)
    rehome(st.closed)
    rehome(st.messages)
    release st.lock

proc snapshot(st: ptr State): State =
  acquire st.lock
  result.opened = st.opened
  result.closed = st.closed
  result.messages = st.messages
  result.requests = st.requests
  release st.lock

proc startServer(st: ptr State): Server =
  var srv: Server
  let onRequest: RequestHandler = proc(conn: ConnId; req: HttpRequest): RequestAction {.gcsafe.} =
    acquire st.lock
    inc st.requests
    release st.lock
    if req.httpMethod notin {hmGet, hmHead}:
      return respond(methodNotAllowed())
    case req.path
    of "/ws":
      upgrade()
    of "/hello":
      respond(okResponse("hello " & req.query, "text/plain"))
    of "/boom":
      raise newException(ValueError, "handler failure")
    of "/upgrade-anything":
      upgrade()
    else:
      respond(notFound())
  let onMessage: MessageHandler = proc(conn: ConnId; message: string) {.gcsafe.} =
    acquire st.lock
    st.messages.add message
    release st.lock
    discard srv.send(conn, message)
  let onOpen: ConnectionHandler = proc(conn: ConnId) {.gcsafe.} =
    acquire st.lock
    st.opened.add conn
    release st.lock
  let onClose: ConnectionHandler = proc(conn: ConnId) {.gcsafe.} =
    acquire st.lock
    st.closed.add conn
    release st.lock
  srv = newServer(onRequest = onRequest, onMessage = onMessage,
                  onOpen = onOpen, onClose = onClose,
                  workers = 4, queueCapacity = 32, closeTimeoutMs = 500)
  srv.listen(0)
  srv

proc connect(port: int): Socket =
  result = newSocket(buffered = false)
  result.connect("127.0.0.1", Port(port))

proc recvSome(sock: Socket; maxLen = 65536): string =
  ## Whatever is readable within `IoTimeout` (`""` on EOF). `net.recv(size,
  ## timeout)` on an unbuffered socket insists on `size` bytes, so wait with
  ## `select` and do one raw read instead.
  var fds = @[sock.getFd()]
  if selectRead(fds, IoTimeout) == 0:
    raise newException(TimeoutError, "read timed out")
  result = newString(maxLen)
  let n = sock.recv(addr result[0], maxLen)
  if n < 0:
    raiseOSError(osLastError())
  result.setLen(n)

proc recvExact(sock: Socket; n: int): string =
  while result.len < n:
    let chunk = sock.recvSome(n - result.len)
    if chunk.len == 0:
      raise newException(IOError, "connection closed early")
    result.add chunk

proc readResponse(sock: Socket): tuple[status: int; headers: seq[(string, string)]; body: string] =
  let statusLine = sock.recvLine(IoTimeout)
  doAssert statusLine.startsWith("HTTP/1.1 "), "bad status line: " & statusLine
  result.status = parseInt(statusLine.split(' ')[1])
  while true:
    let line = sock.recvLine(IoTimeout)
    if line.len == 0 or line == "\r\n":
      break
    let colon = line.find(':')
    result.headers.add((line[0 ..< colon], line[colon + 1 .. ^1].strip()))
  var length = 0
  for (name, value) in result.headers:
    if cmpIgnoreCase(name, "Content-Length") == 0:
      length = parseInt(value)
  if length > 0:
    result.body = sock.recvExact(length)

proc header(r: tuple[status: int; headers: seq[(string, string)]; body: string];
            name: string): string =
  for (n, v) in r.headers:
    if cmpIgnoreCase(n, name) == 0:
      return v

proc atEof(sock: Socket): bool =
  ## True when the peer has closed: a read returns nothing or fails.
  try:
    sock.recvSome(1).len == 0
  except OSError:
    true

proc handshake(port: int; path = "/ws"; key = RfcKey): WsClient =
  result.sock = connect(port)
  result.decoder = initFrameDecoder(frClient)
  result.sock.send("GET " & path & " HTTP/1.1\r\nHost: 127.0.0.1\r\n" &
                   "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
                   "Sec-WebSocket-Key: " & key & "\r\n" &
                   "Sec-WebSocket-Version: 13\r\n\r\n")
  let r = result.sock.readResponse()
  doAssert r.status == 101, "upgrade failed with " & $r.status

proc readFrame(c: var WsClient): Frame =
  while true:
    let r = c.decoder.decodeFrame(c.buf)
    if r.status == fsComplete:
      c.buf.delete(0 ..< r.consumed)
      return r.frame
    let chunk = c.sock.recvSome()
    if chunk.len == 0:
      raise newException(IOError, "connection closed while waiting for a frame")
    c.buf.add chunk

proc openedId(st: ptr State; index: int): ConnId =
  ## Waits for the `index`-th `onOpen` and returns its id.
  doAssert waitUntil(IoTimeout, proc(): bool = snapshot(st).opened.len > index),
           "onOpen did not fire"
  snapshot(st).opened[index]

proc noteWorker(bag: ptr Bag) {.gcsafe.} =
  ## Once per worker thread: count the thread now and again when it exits.
  if workerNoted:
    return
  workerNoted = true
  acquire bag.lock
  inc bag.workersSeen
  release bag.lock
  onThreadDestruction(proc() {.closure, gcsafe, raises: [].} =
    acquire bag.lock
    inc bag.workersExited
    release bag.lock)

proc startBagServer(bag: ptr Bag; workers, queueCapacity: int): Server =
  ## Upgrades everything; messages grow `bag.grown` on the workers, `onClose`
  ## counts. Neither hook replies, so nothing captures the `Server`.
  let onRequest: RequestHandler = proc(conn: ConnId; req: HttpRequest): RequestAction {.gcsafe.} =
    upgrade()
  let onMessage: MessageHandler = proc(conn: ConnId; message: string) {.gcsafe.} =
    noteWorker(bag)
    acquire bag.lock
    bag.grown[bag.grown.len] = message & " " & $int(conn)
    release bag.lock
  let onClose: ConnectionHandler = proc(conn: ConnId) {.gcsafe.} =
    noteWorker(bag)
    sleep(2)
    acquire bag.lock
    inc bag.closes
    release bag.lock
  result = newServer(onRequest = onRequest, onMessage = onMessage,
                     onClose = onClose, workers = workers,
                     queueCapacity = queueCapacity, closeTimeoutMs = 500)
  result.listen(0)

template serverTest(name: string; body: untyped) =
  test name:
    var st {.inject.}: State
    initLock st.lock
    let stp {.inject.} = addr st
    let srv {.inject.} = startServer(stp)
    try:
      body
    finally:
      srv.shutdown(beforeJoin = releaseState(stp))
      deinitLock st.lock

# --- tests -----------------------------------------------------------------------

suite "server: lifecycle":
  test "listen on port 0 reports an ephemeral port; shutdown is idempotent":
    var st: State
    initLock st.lock
    let srv = startServer(addr st)
    try:
      check srv.port > 0
      check srv.running
    finally:
      srv.shutdown()
      check not srv.running
      srv.shutdown()
      check not srv.running
      deinitLock st.lock

  test "shutdown before listen is a no-op":
    let srv = newServer()
    srv.shutdown()
    check not srv.running
    check srv.port == 0

suite "server: HTTP":
  serverTest "request goes through the handler and the response comes back":
    let sock = connect(srv.port)
    sock.send("GET /hello?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    let r = sock.readResponse()
    check r.status == 200
    check r.body == "hello x=1"
    check r.header("Content-Type") == "text/plain"
    check r.header("Connection") == "keep-alive"
    check snapshot(stp).requests == 1
    sock.close()

  serverTest "keep-alive: two pipelined requests on one socket are answered in order":
    let sock = connect(srv.port)
    sock.send("GET /hello?a HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n" &
              "GET /hello?b HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    let r1 = sock.readResponse()
    let r2 = sock.readResponse()
    check r1.body == "hello a"
    check r2.body == "hello b"
    sock.send("GET /hello?c HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
    let r3 = sock.readResponse()
    check r3.body == "hello c"
    check r3.header("Connection") == "close"
    check sock.atEof()
    sock.close()

  serverTest "garbage gets a 400 and the connection is closed":
    let sock = connect(srv.port)
    sock.send("GARBAGE\r\n\r\n")
    let r = sock.readResponse()
    check r.status == 400
    check r.header("Connection") == "close"
    check sock.atEof()
    check snapshot(stp).requests == 0
    sock.close()

  serverTest "unknown path is 404, other methods 405, HEAD has no body":
    let sock = connect(srv.port)
    sock.send("GET /nope HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    check sock.readResponse().status == 404
    sock.send("POST /hello HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 3\r\n\r\nabc")
    let r405 = sock.readResponse()
    check r405.status == 405
    check r405.header("Allow") == "GET, HEAD"
    sock.send("HEAD /hello?h HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    # Read the head manually: Content-Length is present but no body follows.
    let statusLine = sock.recvLine(IoTimeout)
    check statusLine.startsWith("HTTP/1.1 200")
    var contentLength = ""
    while true:
      let line = sock.recvLine(IoTimeout)
      if line.len == 0 or line == "\r\n":
        break
      if line.startsWith("Content-Length:"):
        contentLength = line.split(':')[1].strip()
    check contentLength == $"hello h".len
    sock.send("GET /hello?after HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    check sock.readResponse().body == "hello after" # nothing leaked from HEAD
    sock.close()

  serverTest "a raising handler becomes a 500 and the connection survives":
    let sock = connect(srv.port)
    sock.send("GET /boom HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    check sock.readResponse().status == 500
    sock.send("GET /hello?ok HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    check sock.readResponse().body == "hello ok"
    sock.close()

suite "server: WebSocket":
  serverTest "upgrade handshake produces the RFC 6455 accept value":
    let sock = connect(srv.port)
    sock.send("GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: WebSocket\r\n" &
              "Connection: keep-alive, Upgrade\r\nSec-WebSocket-Key: " & RfcKey &
              "\r\nSec-WebSocket-Version: 13\r\n\r\n")
    let r = sock.readResponse()
    check r.status == 101
    check r.header("Sec-WebSocket-Accept") == RfcAccept
    check cmpIgnoreCase(r.header("Upgrade"), "websocket") == 0
    check cmpIgnoreCase(r.header("Connection"), "Upgrade") == 0
    check r.header("Content-Length") == ""
    check r.body == ""
    discard openedId(stp, 0)
    sock.close()

  serverTest "upgrade() for a request without upgrade headers is a 400":
    let sock = connect(srv.port)
    sock.send("GET /upgrade-anything HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    let r = sock.readResponse()
    check r.status == 400
    check sock.atEof()
    check snapshot(stp).opened.len == 0
    sock.close()

  serverTest "text message is echoed":
    var c = handshake(srv.port)
    c.sock.send(encodeText("ping!", Key))
    let f = c.readFrame()
    check f.opcode == opText
    check f.fin
    check not f.masked
    check f.payload == "ping!"
    check snapshot(stp).messages == @["ping!"]
    c.sock.close()

  serverTest "fragmented message is delivered and echoed whole":
    var c = handshake(srv.port)
    c.sock.send(encodeText("Hel", Key, fin = false))
    c.sock.send(encodeContinuation("lo, ", Key, fin = false))
    c.sock.send(encodeContinuation("world", Key, fin = true))
    let f = c.readFrame()
    check f.opcode == opText
    check f.payload == "Hello, world"
    check snapshot(stp).messages == @["Hello, world"]
    c.sock.close()

  serverTest "large message crossing several reads is echoed":
    var c = handshake(srv.port)
    let big = repeat("0123456789", 20_000) # 200 000 bytes
    c.sock.send(encodeText(big, Key))
    let f = c.readFrame()
    check f.payload.len == big.len
    check f.payload == big
    c.sock.close()

  serverTest "ping is answered with a pong carrying the same payload":
    var c = handshake(srv.port)
    c.sock.send(encodePing("are you there?", Key))
    let f = c.readFrame()
    check f.opcode == opPong
    check f.payload == "are you there?"
    check snapshot(stp).messages.len == 0
    c.sock.close()

  serverTest "binary message is refused with 1003":
    var c = handshake(srv.port)
    c.sock.send(encodeBinary("\x00\x01", Key))
    let f = c.readFrame()
    check f.opcode == opClose
    check decodeClose(f).code == CloseUnsupportedData
    check c.sock.atEof()
    check waitUntil(IoTimeout, proc(): bool = snapshot(stp).closed.len == 1)
    c.sock.close()

  serverTest "malformed (unmasked) frame is refused with 1002":
    var c = handshake(srv.port)
    c.sock.send(encodeText("not masked"))
    let f = c.readFrame()
    check f.opcode == opClose
    check decodeClose(f).code == CloseProtocolError
    check c.sock.atEof()
    c.sock.close()

  serverTest "oversized frame is refused with 1009 before the payload arrives":
    var c = handshake(srv.port)
    var header = encodeText("", Key)
    # Rewrite the length to a 64-bit declaration far above the default limit.
    header[1] = char(0x80 or 127)
    header.setLen(2)
    for shift in countdown(56, 0, 8):
      header.add char(byte((0x1_0000_0000'u64 shr shift) and 0xFF))
    for b in Key:
      header.add char(b)
    c.sock.send(header)
    let f = c.readFrame()
    check f.opcode == opClose
    check decodeClose(f).code == CloseMessageTooBig
    c.sock.close()

  serverTest "client-initiated close is answered with the echoed code and the socket closes":
    var c = handshake(srv.port)
    discard openedId(stp, 0)
    c.sock.send(encodeClose(CloseNormal, "bye", Key))
    let f = c.readFrame()
    check f.opcode == opClose
    let info = decodeClose(f)
    check info.code == CloseNormal
    check info.reason == ""
    check c.sock.atEof()
    check waitUntil(IoTimeout, proc(): bool = snapshot(stp).closed.len == 1)
    c.sock.close()

  serverTest "client close without a status code is answered with 1000":
    var c = handshake(srv.port)
    c.sock.send(encodeClose(CloseNoStatus, "", Key))
    let f = c.readFrame()
    check decodeClose(f).code == CloseNormal
    check c.sock.atEof()
    c.sock.close()

  serverTest "server-initiated close sends the frame and waits for the reply":
    var c = handshake(srv.port)
    let id = openedId(stp, 0)
    check srv.close(id, CloseGoingAway, "shutting down")
    check not srv.close(id) # already closing
    let f = c.readFrame()
    check f.opcode == opClose
    let info = decodeClose(f)
    check info.code == CloseGoingAway
    check info.reason == "shutting down"
    check not srv.send(id, "too late")
    c.sock.send(encodeCloseReply(info, Key))
    check c.sock.atEof()
    check waitUntil(IoTimeout, proc(): bool = snapshot(stp).closed == @[id])
    c.sock.close()

  serverTest "server-initiated close gives up after the close timeout":
    var c = handshake(srv.port)
    let id = openedId(stp, 0)
    let t0 = getMonoTime()
    check srv.close(id)
    discard c.readFrame() # the close frame; we never reply
    check c.sock.atEof()
    let elapsed = (getMonoTime() - t0).inMilliseconds
    check elapsed >= 400 # closeTimeoutMs = 500 in the fixture
    check elapsed < IoTimeout
    c.sock.close()

  serverTest "close on an unknown connection is refused":
    check not srv.close(ConnId(424242))
    check not srv.send(ConnId(424242), "nobody home")

  serverTest "open/close callbacks fire exactly once per connection":
    var clients: seq[WsClient]
    for i in 0 ..< 3:
      clients.add handshake(srv.port)
    check waitUntil(IoTimeout, proc(): bool = snapshot(stp).opened.len == 3)
    let opened = snapshot(stp).opened
    check opened[0] != opened[1]
    check opened[1] != opened[2]
    check opened[0] != opened[2]
    # Plain HTTP connections do not count as opened.
    let plain = connect(srv.port)
    plain.send("GET /hello HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    discard plain.readResponse()
    plain.close()
    clients[0].sock.send(encodeClose(CloseNormal, "", Key)) # clean close
    clients[1].sock.close()                                  # abrupt close
    check waitUntil(IoTimeout, proc(): bool = snapshot(stp).closed.len == 2)
    sleep(50)
    var snap = snapshot(stp)
    check snap.opened.len == 3
    check snap.closed.len == 2
    for id in snap.closed:
      check id in opened
    check snap.closed[0] != snap.closed[1]
    clients[2].sock.close()
    check waitUntil(IoTimeout, proc(): bool = snapshot(stp).closed.len == 3)

  serverTest "send from a non-IO thread arrives":
    var c = handshake(srv.port)
    let id = openedId(stp, 0)
    check srv.send(id, "from the test thread")
    let f = c.readFrame()
    check f.opcode == opText
    check f.payload == "from the test thread"
    # And from a freshly created thread.
    type Ctx = object
      srv: ptr Server
      id: ConnId
    proc sender(ctx: ptr Ctx) {.thread.} =
      discard ctx.srv[].send(ctx.id, "from another thread")
    var ctx = Ctx(srv: unsafeAddr srv, id: id)
    var th: Thread[ptr Ctx]
    createThread(th, sender, addr ctx)
    joinThread(th)
    let g = c.readFrame()
    check g.payload == "from another thread"
    c.sock.close()

  serverTest "several messages in one TCP segment are all handled":
    # Each message is its own pool task, so handlers for one connection may
    # run concurrently and the echo order is not guaranteed (serializing per
    # connection would deadlock a handler that waits for a reply on the same
    # connection); only completeness is checked.
    var c = handshake(srv.port)
    c.sock.send(encodeText("one", Key) & encodeText("two", Key) & encodeText("three", Key))
    var got: seq[string]
    for i in 0 ..< 3:
      got.add c.readFrame().payload
    check sorted(got) == @["one", "three", "two"]
    check sorted(snapshot(stp).messages) == @["one", "three", "two"]
    c.sock.close()

  test "a full pool queue pauses the connection instead of dropping messages":
    # One worker, room for one queued task, a slow handler: of six messages
    # sent at once the first runs, the second queues, and the rest must wait
    # in the socket until the IO loop can hand them over.
    proc run() =
      var srv: Server
      let onRequest: RequestHandler = proc(conn: ConnId; req: HttpRequest): RequestAction {.gcsafe.} =
        upgrade()
      let onMessage: MessageHandler = proc(conn: ConnId; message: string) {.gcsafe.} =
        sleep(60)
        discard srv.send(conn, message)
      srv = newServer(onRequest = onRequest, onMessage = onMessage,
                      workers = 1, queueCapacity = 1)
      srv.listen(0)
      try:
        var c = handshake(srv.port)
        var all = ""
        for i in 0 ..< 6:
          all.add encodeText("m" & $i, Key)
        c.sock.send(all)
        var got: seq[string]
        for i in 0 ..< 6:
          got.add c.readFrame().payload
        check sorted(got) == @["m0", "m1", "m2", "m3", "m4", "m5"]
        c.sock.close()
      finally:
        srv.shutdown()
    run()

  serverTest "shutdown with connections still open returns and tells the peers":
    var a = handshake(srv.port)
    var b = handshake(srv.port)
    let http = connect(srv.port)
    discard openedId(stp, 1)
    let t0 = getMonoTime()
    srv.shutdown(beforeJoin = releaseState(stp))
    check (getMonoTime() - t0).inMilliseconds < IoTimeout
    check not srv.running
    # Upgraded peers get a best-effort 1001 then EOF; the plain socket just EOFs.
    for c in [addr a, addr b]:
      let f = c[].readFrame()
      check f.opcode == opClose
      check decodeClose(f).code == CloseGoingAway
      check c[].sock.atEof()
    check http.atEof()
    # onClose ran for both before shutdown returned (the pool was drained).
    let snap = snapshot(stp)
    check snap.closed.len == 2
    check snap.opened.len == 2
    # Nothing accepts any more.
    expect OSError:
      discard connect(srv.port)
    a.sock.close()
    b.sock.close()
    http.close()

# Nim's allocator cannot free a block once the thread that allocated it has
# exited (on Windows that is an intermittent SIGSEGV in `addToSharedFreeList`).
# These tests pin down the ordering that prevents it; see NOTES.md.
suite "server: shutdown ordering":
  test "beforeJoin runs after every onClose, with the IO thread and the workers alive":
    var bag: Bag
    initLock bag.lock
    let bagp = addr bag
    let srv = startBagServer(bagp, workers = 3, queueCapacity = 16)
    var clients: seq[WsClient]
    try:
      for i in 0 ..< 4:
        clients.add handshake(srv.port)
      check srv.ioThreadRunning
      var atHook = (closes: -1, exited: -1, ioAlive: false)
      srv.shutdown(beforeJoin = proc() {.gcsafe.} =
        acquire bagp.lock
        atHook.closes = bagp.closes
        atHook.exited = bagp.workersExited
        release bagp.lock
        {.cast(gcsafe).}: # `srv` is a test-block global; this runs on the test thread
          atHook.ioAlive = srv.ioThreadRunning)
      check atHook.closes == 4
      check atHook.exited == 0
      check atHook.ioAlive
      check not srv.ioThreadRunning
      acquire bag.lock
      check bag.workersSeen >= 1
      check bag.workersExited == bag.workersSeen
      release bag.lock
    finally:
      srv.shutdown()
      for c in clients:
        c.sock.close()
      deinitLock bag.lock

  test "beforeJoin runs at once before listen and after a completed shutdown":
    let fresh = newServer()
    var ran = 0
    fresh.shutdown(beforeJoin = proc() {.gcsafe.} = inc ran)
    check ran == 1
    var bag: Bag
    initLock bag.lock
    let srv = startBagServer(addr bag, workers = 1, queueCapacity = 4)
    srv.shutdown()
    srv.shutdown(beforeJoin = proc() {.gcsafe.} = inc ran)
    check ran == 2
    deinitLock bag.lock

  test "50 create/shutdown cycles with open connections and queued work":
    # The crash this guards against needed the IO thread to have grown its
    # tables and to have queued `onClose` tasks at shutdown, and workers to
    # have grown shared state that is freed afterwards. Every round does all
    # three; without the ordering it fails intermittently, on Windows mostly.
    for round in 0 ..< 50:
      var bag: Bag
      initLock bag.lock
      let bagp = addr bag
      var clients: seq[WsClient]
      block:
        let srv = startBagServer(bagp, workers = 2, queueCapacity = 8)
        try:
          for i in 0 ..< 6:
            clients.add handshake(srv.port)
          for c in clients:
            c.sock.send(encodeText("a", Key) & encodeText("b", Key) &
                        encodeText("c", Key))
        finally:
          srv.shutdown(beforeJoin = proc() {.gcsafe.} =
            acquire bagp.lock
            bagp.grown = default(Table[int, string])
            release bagp.lock)
        # Leaving the block destroys the server: its tables and pool go too.
      check bag.closes == 6
      check bag.workersExited == bag.workersSeen
      for c in clients:
        c.sock.close()
      deinitLock bag.lock
