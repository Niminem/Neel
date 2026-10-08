## t_window.nim - window table, connection mapping, resolver, lifecycle, and
## one round trip through the real server.
##
## Unit tests inject a fake launcher (records the URL and arguments, returns a
## process-less handle, never starts a browser) and fake close/send procs with
## hand-made `ConnId`s. The integration test wires the real Task 6 server the
## way `startApp` will (handler binds before `upgrade()`, `onOpen` /
## `onClose` / `onMessage` call into `window.nim`). Every wait and read is
## bounded (3 s max); grace periods are short (300 ms).

import std/[unittest, json, locks, os, monotimes, times, typedthreads, net,
            nativesockets, strutils, options, uri, algorithm]
import neel/[window, jsproxy, protocol, server, websocket, http, expose,
             browser, frontend]

const
  IoTimeout = 3000
    ## Milliseconds any single wait or client read may take.
  Grace = 300
    ## Grace period used by every test (>= MinGracePeriodMs).
  Startup = 700
    ## Startup timeout used by the unit tests.
  Base = "http://127.0.0.1:1234"
  Key = [0x37'u8, 0xFA, 0x21, 0x3D]
    ## RFC 6455 section 5.7 example masking key.
  RfcKey = "dGhlIHNhbXBsZSBub25jZQ=="
    ## RFC 6455 section 1.3 example `Sec-WebSocket-Key`.
  ConnA = ConnId(11)
  ConnB = ConnId(22)
  ConnC = ConnId(33)

let fakeSearch = BrowserSearch(
  found: some FoundBrowser(browser: Chrome, path: "/fake/chrome"))

# --- fakes -----------------------------------------------------------------------

type
  Launch = tuple[url, userDataDir: string; opts: LaunchOptions]

  Fake = object
    ## Shared between the test thread, the injected procs, and script
    ## threads; `lock` guards everything below it.
    lock: Lock
    closes: seq[tuple[conn: ConnId; code: int]]
    launches: seq[Launch]
    sent: seq[tuple[conn: ConnId; text: string]]
    opened: seq[int]   # window ids passed to onWindowOpen
    closed: seq[int]   # window ids passed to onWindowClose
    failLaunch: bool
    table: PendingTable

var fake: Fake
initLock fake.lock

proc fakeClose(conn: ConnId; code: int): bool {.gcsafe.} =
  {.cast(gcsafe).}: # test global, guarded by its lock
    acquire fake.lock
    fake.closes.add((conn, code))
    release fake.lock
  true

proc fakeLaunch(url, userDataDir: string; opts: LaunchOptions): BrowserHandle
    {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire fake.lock
    fake.launches.add((url, userDataDir, opts))
    let fail = fake.failLaunch
    release fake.lock
  if fail:
    raise newException(NeelBrowserError, "fake launcher refused")
  # Stand in for Chromium creating its profile directory.
  createDir(userDataDir)
  BrowserHandle(kind: lkAppWindow, browser: Chrome, path: "/fake/chrome",
                args: @["--app=" & url], url: url, userDataDir: userDataDir)

proc fakeSend(conn: ConnId; text: string): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire fake.lock
    fake.sent.add((conn, text))
    release fake.lock
  true

proc hookOpen(w: Window) {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire fake.lock
    fake.opened.add w.id
    release fake.lock

proc hookClose(w: Window) {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire fake.lock
    fake.closed.add w.id
    release fake.lock

proc resetFake() =
  acquire fake.lock
  fake.closes = @[]
  fake.launches = @[]
  fake.sent = @[]
  fake.opened = @[]
  fake.closed = @[]
  fake.failLaunch = false
  release fake.lock
  fake.table = newPendingTable()

proc launches(): seq[Launch] =
  acquire fake.lock
  result = fake.launches
  release fake.lock

proc closes(): seq[tuple[conn: ConnId; code: int]] =
  acquire fake.lock
  result = fake.closes
  release fake.lock

proc sentMsgs(): seq[tuple[conn: ConnId; msg: Msg]] =
  acquire fake.lock
  for (conn, text) in fake.sent:
    result.add((conn, decode(text)))
  release fake.lock

proc openedIds(): seq[int] =
  acquire fake.lock
  result = fake.opened
  release fake.lock

proc closedIds(): seq[int] =
  acquire fake.lock
  result = fake.closed
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

proc ids(ws: seq[Window]): seq[int] =
  for w in ws:
    result.add w.id

template winTest(name: string; body: untyped) =
  test name:
    resetFake()
    initWindows(fakeClose, fake.table, Base, fakeSearch, launcher = fakeLaunch,
                gracePeriodMs = Grace, startupTimeoutMs = Startup,
                onWindowOpen = hookOpen, onWindowClose = hookClose)
    initJsBridge(fakeSend, resolveWindow, fake.table)
    try:
      body
    finally:
      clearCurrentWindow()
      resetJsBridge()
      teardownWindows()

proc connect(windowId: int; conn: ConnId) =
  ## bind + onOpen, the way a successful upgrade plays out.
  doAssert bindConnection(windowId, conn)
  connectionOpened(conn)

# --- script threads --------------------------------------------------------------

type
  ScriptKind = enum
    skQuit        ## sleep `delayMs`, then `quitApp()`
    skReconnect   ## sleep `delayMs`, bind + open `conn`, sleep `delayMs2`, close it
    skWaiter      ## `w.js.wait(2000).foo()` and record the exception kind

  Script = object
    kind: ScriptKind
    delayMs, delayMs2: int
    windowId: int
    conn: ConnId
    w: Window
    disconnected: bool

proc runScript(s: ptr Script) {.thread.} =
  case s.kind
  of skQuit:
    sleep(s.delayMs)
    quitApp()
  of skReconnect:
    sleep(s.delayMs)
    connect(s.windowId, s.conn)
    sleep(s.delayMs2)
    connectionClosed(s.conn)
  of skWaiter:
    try:
      discard s.w.js.wait(2000).foo()
    except NeelDisconnectedError:
      s.disconnected = true
    except CatchableError:
      discard

template withScript(s: var Script; body: untyped) =
  var th: Thread[ptr Script]
  createThread(th, runScript, addr s)
  try:
    body
  finally:
    joinThread(th)

# --- opening ---------------------------------------------------------------------

suite "window: opening":
  winTest "ids start at 1 and increase; Window carries a matching js proxy":
    let w1 = openWindow()
    let w2 = openWindow("/two")
    check w1.id == 1
    check w2.id == 2
    check w1.js.windowId == 1
    check w2.js.windowId == 2
    check w1.isOpen
    check not w1.isConnected
    check windows().ids == @[1, 2]
    check window(2) == some w2
    check window(3).isNone

  winTest "the launch URL carries ?window=<id> and the per-window profile dir":
    discard openWindow()
    discard openWindow("/two?x=1")
    let l = launches()
    check l.len == 2
    check l[0].url == Base & "/?window=1"
    check l[0].userDataDir == userDataDirFor(1)
    check l[1].url == Base & "/two?x=1&window=2"
    check l[1].userDataDir == userDataDirFor(2)

  test "launchUrl handles queries, fragments, missing slashes, trailing slashes":
    check launchUrl(Base, "/", 1) == Base & "/?window=1"
    check launchUrl(Base & "/", "/", 1) == Base & "/?window=1"
    check launchUrl(Base, "/a/b.html", 7) == Base & "/a/b.html?window=7"
    check launchUrl(Base, "/a?x=1&y=2", 3) == Base & "/a?x=1&y=2&window=3"
    check launchUrl(Base, "/a#top", 4) == Base & "/a?window=4#top"
    check launchUrl(Base, "/a?x=1#top", 5) == Base & "/a?x=1&window=5#top"
    check launchUrl(Base, "index.html", 6) == Base & "/index.html?window=6"
    check launchUrl(Base, "", 2) == Base & "/?window=2"
    expect AssertionDefect:
      discard launchUrl(Base, "/", 0)

  test "size, position, and extraFlags override and extend the defaults":
    resetFake()
    initWindows(fakeClose, fake.table, Base, fakeSearch, launcher = fakeLaunch,
                defaultOpts = LaunchOptions(size: some((640, 480)),
                                            extraFlags: @["--a"]),
                gracePeriodMs = Grace, startupTimeoutMs = Startup)
    try:
      discard openWindow()
      discard openWindow("/x", size = some((800, 600)), position = some((10, 20)),
                         extraFlags = @["--b"])
      let l = launches()
      check l[0].opts == LaunchOptions(size: some((640, 480)), extraFlags: @["--a"])
      check l[1].opts.size == some((800, 600))
      check l[1].opts.position == some((10, 20))
      check l[1].opts.extraFlags == @["--a", "--b"]
    finally:
      teardownWindows()

  winTest "a failing launcher drops the record and the id is not reused":
    acquire fake.lock
    fake.failLaunch = true
    release fake.lock
    expect NeelBrowserError:
      discard openWindow()
    check windows().len == 0
    check window(1).isNone
    acquire fake.lock
    fake.failLaunch = false
    release fake.lock
    check openWindow().id == 2
    check windows().ids == @[2]

  winTest "windows() lists open windows in id order":
    var ws: seq[Window]
    for i in 1 .. 5:
      ws.add openWindow()
    closeWindow(ws[1])
    closeWindow(ws[3])
    check windows().ids == @[1, 3, 5]
    check not ws[1].isOpen
    check ws[2].isOpen

# --- mapping ---------------------------------------------------------------------

suite "window: connection mapping":
  winTest "bindConnection accepts known ids and refuses unknown or closed ones":
    let w = openWindow()
    check bindConnection(1, ConnA)
    check windowIdOf(ConnA) == 1
    check w.isConnected
    check not bindConnection(99, ConnB)
    check not bindConnection(0, ConnB)
    check not bindConnection(-1, ConnB)
    check windowIdOf(ConnB) == NoWindow
    closeWindow(w)
    check not bindConnection(1, ConnB)

  winTest "a reconnect re-associates and the old connection's close does not clear it":
    let w = openWindow()
    connect(1, ConnA)
    check connectionCount() == 1
    # Refresh: the new connection's handler runs before the old onClose.
    connect(1, ConnB)
    check windowIdOf(ConnA) == NoWindow
    check windowIdOf(ConnB) == 1
    check connectionCount() == 2
    connectionClosed(ConnA)
    check w.isConnected
    check windowIdOf(ConnB) == 1
    check resolveWindow(1).conn == ConnB
    check connectionCount() == 1
    connectionClosed(ConnB)
    check not w.isConnected
    check w.isOpen            # still open: may reconnect within the grace period
    check windowIdOf(ConnB) == NoWindow
    check connectionCount() == 0
    check openedIds() == @[1]  # the refresh did not fire onWindowOpen again
    check closedIds().len == 0

  winTest "the resolver returns a live route with a stable allocator or an empty route":
    let w = openWindow()
    check resolveWindow(1).ids.isNil
    check resolveWindow(2).ids.isNil
    check bindConnection(1, ConnA)
    let r = resolveWindow(1)
    check r.conn == ConnA
    check not r.ids.isNil
    check r.ids[].nextId() == 1
    check resolveWindow(1).ids == r.ids
    check r.ids[].nextId() == 2
    # Through the bridge: the current window and an explicit proxy.
    withCurrentWindow(1):
      js.foo(1)
    w.js.bar()
    expect NeelTimeoutError:
      discard w.js.wait(20).baz()
    let msgs = sentMsgs()
    check msgs.len == 3
    check msgs[0].conn == ConnA
    check msgs[0].msg.name == "foo"
    check msgs[1].conn == ConnA
    check msgs[2].msg.id == 3   # same allocator as above
    connectionClosed(ConnA)
    check resolveWindow(1).ids.isNil
    expect NeelNoWindowError:
      w.js.qux()

  winTest "currentWindow follows withCurrentWindow":
    let w = openWindow()
    check currentWindow().isNone
    withCurrentWindow(1):
      check currentWindow() == some w
      check currentWindow().get.js.windowId == 1
    withCurrentWindow(7):
      check currentWindow().isNone
    check currentWindow().isNone
    closeWindow(w)
    withCurrentWindow(1):
      check currentWindow().isNone

  winTest "connectionClosed fails pending waiters on that connection":
    let w = openWindow()
    connect(1, ConnA)
    var s = Script(kind: skWaiter, w: w)
    withScript(s):
      check waitUntil(IoTimeout, proc(): bool = fake.table.pendingCount == 1)
      connectionClosed(ConnA)
    check s.disconnected
    check fake.table.pendingCount == 0

  winTest "hooks and counts ignore connections that were never bound":
    connectionOpened(ConnC)
    check connectionCount() == 1
    check windowIdOf(ConnC) == NoWindow
    connectionClosed(ConnC)
    check connectionCount() == 0
    check openedIds().len == 0

# --- closing ---------------------------------------------------------------------

suite "window: closing":
  winTest "closeWindow closes with 1000, tears the handle down, refuses later binds":
    let w = openWindow()
    connect(1, ConnA)
    let dir = launches()[0].userDataDir
    check dirExists(dir)
    closeWindow(w)
    check closes() == @[(ConnA, CloseNormal)]
    check not dirExists(dir)
    check not w.isOpen
    check not w.isConnected
    check windows().len == 0
    check not bindConnection(1, ConnB)
    check resolveWindow(1).ids.isNil
    check closedIds() == @[1]
    # Idempotent.
    closeWindow(w)
    check closes().len == 1
    check closedIds() == @[1]
    # The connection's onClose frees the record; the count still balances.
    connectionClosed(ConnA)
    check connectionCount() == 0
    check windowIdOf(ConnA) == NoWindow

  winTest "closeWindow of a window that never connected sends nothing":
    let w = openWindow()
    let dir = launches()[0].userDataDir
    closeWindow(w)
    check closes().len == 0
    check not dirExists(dir)
    check windows().len == 0
    check closedIds() == @[1]
    check openedIds().len == 0

  winTest "closeWindow with an unknown id is a no-op":
    closeWindow(Window(id: 42, js: initJsProxy(42)))
    check closes().len == 0
    check closedIds().len == 0

# --- lifecycle -------------------------------------------------------------------

suite "window: lifecycle":
  winTest "the last close starts the grace period and waitForAppExit returns erLastWindowClosed":
    let w = openWindow()
    connect(1, ConnA)
    check openedIds() == @[1]
    let dir = launches()[0].userDataDir
    connectionClosed(ConnA)
    let t0 = getMonoTime()
    check waitForAppExit() == erLastWindowClosed
    let took = elapsedMs(t0)
    check took >= Grace - 50
    check took < Grace + 700
    # The disconnected window was retired on the way out.
    check not w.isOpen
    check windows().len == 0
    check closedIds() == @[1]
    check not dirExists(dir)

  winTest "a connection opening within the grace period cancels it":
    discard openWindow()
    connect(1, ConnA)
    connectionClosed(ConnA)
    var s = Script(kind: skReconnect, delayMs: 100, delayMs2: 150,
                   windowId: 1, conn: ConnB)
    let t0 = getMonoTime()
    var reason: ExitReason
    withScript(s):
      reason = waitForAppExit()
    let took = elapsedMs(t0)
    check reason == erLastWindowClosed
    check took >= 100 + 150 + Grace - 50
    check took < 100 + 150 + Grace + 700
    check openedIds() == @[1]
    check closedIds() == @[1]

  winTest "quitApp from another thread returns erQuit at once and leaves windows open":
    let w = openWindow()
    connect(1, ConnA)
    var s = Script(kind: skQuit, delayMs: 50)
    let t0 = getMonoTime()
    var reason: ExitReason
    withScript(s):
      reason = waitForAppExit()
    check reason == erQuit
    check elapsedMs(t0) < 1000
    check w.isOpen
    check w.isConnected
    check closedIds().len == 0
    # startApp then shuts the server down (onClose) and tears down.
    connectionClosed(ConnA)
    let dir = launches()[0].userDataDir
    teardownWindows()
    check closedIds() == @[1]
    check not dirExists(dir)
    check windows().len == 0

  winTest "quitApp before any window returns erQuit immediately":
    quitApp()
    let t0 = getMonoTime()
    check waitForAppExit() == erQuit
    check elapsedMs(t0) < 200

  winTest "a window that never connects times out with erStartupTimeout":
    discard openWindow()
    let dir = launches()[0].userDataDir
    let t0 = getMonoTime()
    check waitForAppExit() == erStartupTimeout
    let took = elapsedMs(t0)
    check took >= Startup - 50
    check took < Startup + 700
    check windows().len == 0
    check closedIds() == @[1]
    check openedIds().len == 0
    check not dirExists(dir)

  winTest "no window at all times out with erStartupTimeout":
    let t0 = getMonoTime()
    check waitForAppExit() == erStartupTimeout
    let took = elapsedMs(t0)
    check took >= Startup - 50
    check took < Startup + 700

  winTest "a window that is still loading defers the exit past the grace period":
    discard openWindow()
    connect(1, ConnA)
    discard openWindow("/second")   # never connects
    connectionClosed(ConnA)
    let t0 = getMonoTime()
    check waitForAppExit() == erLastWindowClosed
    let took = elapsedMs(t0)
    check took >= Startup - 50      # not Grace
    check took < Startup + 700
    check closedIds() == @[1, 2]    # 1 retired at Grace, 2 at Startup
    check windows().len == 0

  winTest "a user-closed window is retired after the grace period while another lives on":
    let w1 = openWindow()
    let w2 = openWindow()
    connect(1, ConnA)
    connect(2, ConnB)
    connectionClosed(ConnB)
    var s = Script(kind: skQuit, delayMs: Grace + 200)
    var reason: ExitReason
    withScript(s):
      reason = waitForAppExit()
    check reason == erQuit
    check windows() == @[w1]
    check not w2.isOpen
    check closedIds() == @[2]
    check openedIds() == @[1, 2]
    check connectionCount() == 1

  test "initWindows refuses a grace period below the shim's first retry delay":
    resetFake()
    expect AssertionDefect:
      initWindows(fakeClose, fake.table, Base, fakeSearch, launcher = fakeLaunch,
                  gracePeriodMs = MinGracePeriodMs - 1)
    check windows().len == 0   # nothing was initialised
    check DefaultGracePeriodMs >= MinGracePeriodMs

# --- integration -----------------------------------------------------------------

type
  Integ = object
    srv: Server
    table: PendingTable

  WsClient = object
    sock: Socket
    decoder: FrameDecoder
    buf: string

var integ: Integ

proc integSend(conn: ConnId; text: string): bool {.gcsafe.} =
  {.cast(gcsafe).}: # the Server ref is written once before listen
    integ.srv.send(conn, text)

proc integClose(conn: ConnId; code: int): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    integ.srv.close(conn, code)

proc integDispatch(name: string; args: seq[JsonNode]): JsonNode {.gcsafe.} =
  ## Stands in for the generated dispatcher.
  case name
  of "whoami": %currentWindowId()
  of "count": %connectionCount()
  of "openAnother": %openWindow("/second").id
  of "closeMe":
    closeWindow(currentWindow().get)
    newJNull()
  else: raiseUnknownProc(name)

proc integRequest(conn: ConnId; req: HttpRequest): RequestAction {.gcsafe.} =
  ## The Task 13 `/ws` recipe: validate, bind, then upgrade.
  if req.path == WsPath and isWebSocketUpgrade(req):
    var windowId = 0
    for (k, v) in decodeQuery(req.query):
      if k == WindowQueryParam:
        try:
          windowId = parseInt(v)
        except ValueError:
          windowId = 0
    if windowId > 0 and bindConnection(windowId, conn):
      return upgrade()
    return respond(initResponse(403, "forbidden", "text/plain"))
  respond(notFound())

proc integMessage(conn: ConnId; text: string) {.gcsafe.} =
  let m = decode(text)
  case m.kind
  of msgCall:
    var reply: Option[Msg]
    withCurrentWindow(windowIdOf(conn)):
      reply = handleCall(m, integDispatch)
    if reply.isSome:
      {.cast(gcsafe).}:
        discard integ.srv.send(conn, encode(reply.get))
  of msgRet, msgErr:
    {.cast(gcsafe).}:
      discard integ.table.complete(conn, m.id, m)

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

proc handshake(port: int; windowId: int): tuple[client: WsClient; status: string] =
  result.client.sock = newSocket(buffered = false)
  result.client.sock.connect("127.0.0.1", Port(port))
  result.client.decoder = initFrameDecoder(frClient)
  result.client.sock.send(
    "GET " & WsPath & "?" & TokenQueryParam & "=t&" & WindowQueryParam & "=" &
    $windowId & " HTTP/1.1\r\nHost: 127.0.0.1\r\n" &
    "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
    "Sec-WebSocket-Key: " & RfcKey & "\r\n" &
    "Sec-WebSocket-Version: 13\r\n\r\n")
  result.status = result.client.sock.recvLine(IoTimeout)
  while true:
    let line = result.client.sock.recvLine(IoTimeout)
    if line.len == 0 or line == "\r\n":
      break

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

proc readMsg(c: var WsClient): Msg =
  let f = c.readFrame()
  doAssert f.opcode == opText, "expected a text frame, got " & $f.opcode
  decode(f.payload)

proc sendMsg(c: WsClient; m: Msg) =
  c.sock.send(encodeText(encode(m), Key))

suite "window: integration with the server":
  test "bind-before-upgrade, refresh, two windows, closeWindow, count-driven exit":
    resetFake()
    integ.table = newPendingTable()
    integ.srv = newServer(onRequest = integRequest, onMessage = integMessage,
                          onOpen = connectionOpened, onClose = connectionClosed,
                          workers = 4, queueCapacity = 32, closeTimeoutMs = 500)
    try:
      integ.srv.listen(0)
      let base = "http://127.0.0.1:" & $integ.srv.port
      initWindows(integClose, integ.table, base, fakeSearch,
                  launcher = fakeLaunch, gracePeriodMs = Grace,
                  startupTimeoutMs = 2000, onWindowOpen = hookOpen,
                  onWindowClose = hookClose)
      initJsBridge(integSend, resolveWindow, integ.table, defaultTimeoutMs = 2000)
      let w1 = openWindow()
      check launches()[0].url == base & "/?window=1"
      # An unknown window id is refused before the upgrade.
      let bad = handshake(integ.srv.port, 7)
      check bad.status.startsWith("HTTP/1.1 403")
      bad.client.sock.close()
      check connectionCount() == 0
      # The real window connects; the handler bound it before the 101.
      var (c1, st1) = handshake(integ.srv.port, 1)
      check st1.startsWith("HTTP/1.1 101")
      c1.sendMsg(callMsg("whoami", @[], id = 1))
      check c1.readMsg() == retMsg(1, %1)
      check waitUntil(IoTimeout, proc(): bool = connectionCount() == 1)
      check w1.isConnected
      check openedIds() == @[1]
      # An exposed proc on a worker opens a second window.
      c1.sendMsg(callMsg("openAnother", @[], id = 2))
      check c1.readMsg() == retMsg(2, %2)
      check windows().ids == @[1, 2]
      check launches()[1].url == base & "/second?window=2"
      # Refresh of window 1: same id, new connection.
      c1.sock.close()
      check waitUntil(IoTimeout, proc(): bool = connectionCount() == 0)
      var (c2, st2) = handshake(integ.srv.port, 1)
      check st2.startsWith("HTTP/1.1 101")
      c2.sendMsg(callMsg("whoami", @[], id = 3))
      check c2.readMsg() == retMsg(3, %1)
      check waitUntil(IoTimeout, proc(): bool = connectionCount() == 1)
      check openedIds() == @[1]
      # Window 2 connects too, then its user closes it.
      var (c3, st3) = handshake(integ.srv.port, 2)
      check st3.startsWith("HTTP/1.1 101")
      c3.sendMsg(callMsg("count", @[], id = 4))
      check waitUntil(IoTimeout, proc(): bool = connectionCount() == 2)
      check c3.readMsg().kind == msgRet
      check openedIds() == @[1, 2]
      c3.sock.close()
      check waitUntil(IoTimeout, proc(): bool = connectionCount() == 1)
      # closeWindow from inside the exposed proc: the browser sees a 1000.
      c2.sendMsg(callMsg("closeMe", @[], id = 5))
      var sawClose = false
      for _ in 0 .. 1:
        let f = c2.readFrame()
        if f.opcode == opClose:
          check decodeClose(f).code == CloseNormal
          sawClose = true
          break
      check sawClose
      c2.sock.send(encodeClose(CloseNormal, "", Key))
      c2.sock.close()
      check not w1.isOpen
      # Nothing is connected: the grace period runs out and the app exits.
      let t0 = getMonoTime()
      check waitForAppExit() == erLastWindowClosed
      let took = elapsedMs(t0)
      check took < IoTimeout
      check connectionCount() == 0
      check windows().len == 0
      check sorted(closedIds()) == @[1, 2]
      check integ.table.pendingCount == 0
    finally:
      integ.srv.shutdown()
      resetJsBridge()
      teardownWindows()
