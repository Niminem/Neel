## t_neel.nim - end-to-end smoke test of `startApp` through the public surface.
##
## `startApp` runs on a thread with a fake launcher installed through
## `neel/testhooks` (no browser ever starts); the fake receives the launch URL exactly like a browser would and
## hands the ephemeral port to the test thread. The test thread then plays the
## browser with a scripted HTTP/WebSocket client: fetches `/neel.js` (with and
## without a `Referer`), the index page, a nested asset, a 404, a 405, the
## no-browser page, is refused on `/ws` with a wrong token or window and on
## every route with a foreign `Host`, `Origin`, or cross-site fetch, upgrades
## with the right ones, calls exposed procs, answers a Nim -> JS call, opens
## and closes a second window (a stale page of a closed window gets a 404
## shim, never the surviving window's), and
## finally either calls `quitApp()` through an exposed proc (first run, disk
## assets) or just disconnects and lets the grace period end the app (second
## run, embedded assets). Every wait and read is bounded (3 s max).

import std/[unittest, locks, os, monotimes, times, typedthreads, net,
            nativesockets, strutils, uri]
# `std/json` and `std/options` are deliberately *not* imported here: this
# file uses `%`, `getInt`, `some`, `isNone`, ... through `import neel`'s
# re-export, so the whole suite checks that applications get them for free.
import neel
import neel/[protocol, websocket, frontend, browser, testhooks]

const
  IoTimeout = 3000
    ## Milliseconds any single wait or client read may take.
  Grace = 300
    ## Grace period for both runs (>= MinGracePeriodMs).
  Key = [0x37'u8, 0xFA, 0x21, 0x3D]
    ## RFC 6455 section 5.7 example masking key.
  RfcKey = "dGhlIHNhbXBsZSBub25jZQ=="
    ## RFC 6455 section 1.3 example `Sec-WebSocket-Key`.
  FixtureDir = currentSourcePath().parentDir / "fixtures" / "web"

# --- exposed procs ---------------------------------------------------------------

proc add(a, b: int): int {.expose.} =
  a + b

proc askJs(x: int): int {.expose.} =
  ## Round trip back into the client: blocks for the browser's answer.
  js.wait(2000).jsDouble(x).getInt

proc whichWindow(): int {.expose.} =
  currentWindow().get.id

proc stop() {.expose.} =
  quitApp()

# --- shared state between the app thread and the test thread -----------------------

type
  Shared = object
    lock: Lock
    port: int               # set by the fake launcher from the launch URL
    launches: seq[string]   # launch URLs, in order
    userDataDirs: seq[string]
    done: bool
    reason: ExitReason
    failure: string         # exception message if startApp raised
    workersSeen: int        # workers that ran `markWorker`
    workersExited: int      # ... and have since exited
    exitedAtWindowClose: int  # `workersExited` when `onWindowClose` ran
    sweeps: int             # `recordSweep` calls
    sweepOpenWindows: int   # `windows().len` when it ran
    sweepDirsLeft: int      # launched profile dirs still on disk when it ran
    sweepExited: int        # `workersExited` when it ran
    sweepAfterReturn: bool  # `startApp` had already returned when it ran
    windowOpens: int        # `countOpen` calls
    windowCloses: int       # `countClose` calls

var shared: Shared
initLock shared.lock

var workerMarked {.threadvar.}: bool

proc markWorker() {.expose.} =
  ## Arranges for this worker thread's exit to be counted.
  if workerMarked:
    return
  workerMarked = true
  {.cast(gcsafe).}: # test global guarded by its lock
    acquire shared.lock
    inc shared.workersSeen
    release shared.lock
  onThreadDestruction(proc() {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      acquire shared.lock
      inc shared.workersExited
      release shared.lock)

proc openSecond(): int {.expose.} =
  openWindow("/sub/page.html").id

proc closeSecond(id: int) {.expose.} =
  closeWindow(requireWindow(id))

proc recordWindowClose(w: Window) {.gcsafe.} =
  ## `onWindowClose`: `teardownWindows` fires it for a window still open at
  ## exit, from `shutdown`'s `beforeJoin`, so no worker may have exited yet.
  {.cast(gcsafe).}:
    acquire shared.lock
    shared.exitedAtWindowClose = shared.workersExited
    release shared.lock

proc countOpen(w: Window) {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire shared.lock
    inc shared.windowOpens
    release shared.lock

proc countClose(w: Window) {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire shared.lock
    inc shared.windowCloses
    release shared.lock

proc recordSweep() {.gcsafe.} =
  ## The test profile sweep: must run once, last, with every window, profile dir, and
  ## worker of the run already gone, and before `startApp` returns.
  {.cast(gcsafe).}:
    let open = windows().len
    acquire shared.lock
    inc shared.sweeps
    shared.sweepOpenWindows = open
    shared.sweepDirsLeft = 0
    for d in shared.userDataDirs:
      if dirExists(d):
        inc shared.sweepDirsLeft
    shared.sweepExited = shared.workersExited
    shared.sweepAfterReturn = shared.done
    release shared.lock

proc fakeLaunch(url, userDataDir: string; opts: LaunchOptions): BrowserHandle
    {.gcsafe.} =
  ## Stands in for the browser: records the URL, publishes the port.
  createDir(userDataDir) # like Chromium creating its profile
  {.cast(gcsafe).}: # test global guarded by its lock
    acquire shared.lock
    shared.launches.add url
    shared.userDataDirs.add userDataDir
    shared.port = parseInt(parseUri(url).port)
    release shared.lock
  BrowserHandle(kind: lkAppWindow, browser: Chrome, path: "/fake/chrome",
                args: @["--app=" & url], url: url, userDataDir: userDataDir)

proc finish(reason: ExitReason; failure = "") =
  acquire shared.lock
  shared.reason = reason
  shared.failure = failure
  shared.done = true
  release shared.lock

proc appThread(run: int) {.thread.} =
  ## Runs `startApp` the way an application's main thread would. Run 1
  ## serves the fixture from disk; run 2 embeds it at compile time. The
  ## `{.cast(gcsafe).}` is only because `startApp` is not meant to run on a
  ## thread; the test thread never touches Neel's state directly.
  {.cast(gcsafe).}:
    setTestLauncher(fakeLaunch)
    setTestProfileSweep(recordSweep)
    try:
      case run
      of 1:
        let reason = startApp(webDir = "fixtures/web", embedAssets = false,
                              browsers = @[], gracePeriodMs = Grace,
                              startupTimeoutMs = 2000, callTimeoutMs = 2000,
                              workers = 4, queueCapacity = 32,
                              onWindowClose = recordWindowClose)
        finish(reason)
      of 2:
        let reason = startApp("fixtures/web", embedAssets = true,
                              browsers = @[], gracePeriodMs = Grace,
                              startupTimeoutMs = 2000, callTimeoutMs = 2000,
                              workers = 4, queueCapacity = 32)
        finish(reason)
      else:
        let reason = startApp(webDir = "fixtures/web", embedAssets = false,
                              serve = false, startPath = "/sub/page.html",
                              browsers = @[], gracePeriodMs = Grace,
                              startupTimeoutMs = 2000, callTimeoutMs = 2000,
                              workers = 4, queueCapacity = 32,
                              onWindowOpen = countOpen, onWindowClose = countClose)
        finish(reason)
    except CatchableError as e:
      finish(erStartupTimeout, "startApp raised " & $e.name & ": " & e.msg)
    finally:
      setTestLauncher(nil)
      setTestProfileSweep(nil)

const
  ServeOrigins = @["https://MyApp.Example.com:443", "http://tunnel.example:8080"]
    ## `allowedOrigins` of the serve-mode run (normalized by Neel).
  ServeStartupTimeout = 300
    ## Passed to the serve-mode run, which must ignore it.

proc serveThread(args: (int, string)) {.thread.} =
  ## `startApp` in serve mode on port `args[0]` with `startPath = args[1]`.
  ## The fake launcher and the recording sweep are
  ## installed so the test can check that neither runs; the nonexistent
  ## `browserPath` would raise `NeelBrowserError` if `findBrowser` ran.
  {.cast(gcsafe).}:
    setTestLauncher(fakeLaunch)
    setTestProfileSweep(recordSweep)
    try:
      let reason = startApp(webDir = "fixtures/web", embedAssets = false,
                            serve = true, port = args[0],
                            allowedOrigins = ServeOrigins,
                            startPath = args[1],
                            browsers = @[Chrome], browserPath = "/no/such/browser",
                            gracePeriodMs = Grace,
                            startupTimeoutMs = ServeStartupTimeout,
                            callTimeoutMs = 2000, workers = 4, queueCapacity = 32,
                            onWindowOpen = countOpen, onWindowClose = countClose)
      finish(reason)
    except CatchableError as e:
      finish(erStartupTimeout, "startApp raised " & $e.name & ": " & e.msg)
    finally:
      setTestLauncher(nil)
      setTestProfileSweep(nil)

proc resetShared() =
  acquire shared.lock
  shared.port = 0
  shared.launches = @[]
  shared.userDataDirs = @[]
  shared.done = false
  shared.failure = ""
  shared.workersSeen = 0
  shared.workersExited = 0
  shared.exitedAtWindowClose = -1
  shared.sweeps = 0
  shared.sweepOpenWindows = -1
  shared.sweepDirsLeft = -1
  shared.sweepExited = -1
  shared.sweepAfterReturn = false
  shared.windowOpens = 0
  shared.windowCloses = 0
  release shared.lock

proc sharedPort(): int =
  acquire shared.lock
  result = shared.port
  release shared.lock

proc isDone(): bool =
  acquire shared.lock
  result = shared.done
  release shared.lock

proc waitUntil(deadlineMs: int; cond: proc(): bool): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = deadlineMs)
  while getMonoTime() < deadline:
    if cond():
      return true
    sleep(2)
  cond()

# --- scripted client ---------------------------------------------------------------

type
  HttpReply = object
    status: int
    headers: seq[(string, string)]
    body: string

  WsClient = object
    sock: Socket
    decoder: FrameDecoder
    buf: string

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

proc freePort(): int =
  ## A port that was free a moment ago: bind an ephemeral one, read it,
  ## release it. Serve mode refuses `port = 0`.
  let s = newSocket()
  defer: s.close()
  s.bindAddr(Port(0), "127.0.0.1")
  int(s.getLocalAddr()[1])

proc canConnect(port: int): bool =
  ## Whether something accepts TCP connections on `127.0.0.1:port`.
  let s = newSocket(buffered = false)
  defer: s.close()
  try:
    s.connect("127.0.0.1", Port(port), timeout = 500)
    true
  except OSError, TimeoutError:
    false

proc header(r: HttpReply; name: string): string =
  for (k, v) in r.headers:
    if cmpIgnoreCase(k, name) == 0:
      return v
  ""

proc ownHost(port: int): string =
  "127.0.0.1:" & $port

proc http(port: int; target: string; httpMethod = "GET";
          headers: seq[(string, string)] = @[]; host = ""): HttpReply =
  ## One request on its own connection (`Connection: close`), read to EOF.
  ## `host` replaces the `Host` a Neel page would send.
  let sock = newSocket(buffered = false)
  defer: sock.close()
  sock.connect("127.0.0.1", Port(port))
  var text = httpMethod & " " & target & " HTTP/1.1\r\nHost: " &
             (if host.len > 0: host else: ownHost(port)) & "\r\n" &
             "Connection: close\r\n"
  for (k, v) in headers:
    text.add k & ": " & v & "\r\n"
  text.add "\r\n"
  sock.send(text)
  var raw = ""
  let deadline = getMonoTime() + initDuration(milliseconds = IoTimeout)
  while getMonoTime() < deadline:
    let chunk = sock.recvSome()
    if chunk.len == 0:
      break
    raw.add chunk
  let headerEnd = raw.find("\r\n\r\n")
  doAssert headerEnd > 0, "no header block in: " & raw
  let lines = raw[0 ..< headerEnd].split("\r\n")
  result.status = parseInt(lines[0].split(' ')[1])
  for line in lines[1 .. ^1]:
    let colon = line.find(':')
    result.headers.add((line[0 ..< colon], line[colon + 1 .. ^1].strip()))
  result.body = raw[headerEnd + 4 .. ^1]

const OwnOrigin = "<own>"
  ## `handshake`'s default: the `Origin` a Neel page sends.

proc handshake(port: int; token: string; windowId: int; host = "";
               origin = OwnOrigin; headers: seq[(string, string)] = @[]):
    tuple[client: WsClient; status: string] =
  ## A WebSocket upgrade as a Neel page sends it. `host` replaces the `Host`,
  ## `origin` the `Origin` (`""` sends none), `headers` are added.
  result.client.sock = newSocket(buffered = false)
  result.client.sock.connect("127.0.0.1", Port(port))
  result.client.decoder = initFrameDecoder(frClient)
  var text = "GET " & WsPath & "?" & TokenQueryParam & "=" & token & "&" &
    WindowQueryParam & "=" & $windowId & " HTTP/1.1\r\nHost: " &
    (if host.len > 0: host else: ownHost(port)) & "\r\n" &
    "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
    "Sec-WebSocket-Key: " & RfcKey & "\r\n" &
    "Sec-WebSocket-Version: 13\r\n"
  let o = if origin == OwnOrigin: "http://" & ownHost(port) else: origin
  if o.len > 0:
    text.add "Origin: " & o & "\r\n"
  for (k, v) in headers:
    text.add k & ": " & v & "\r\n"
  text.add "\r\n"
  result.client.sock.send(text)
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

proc tokenIn(shim: string): string =
  ## The launch token rendered into `const TOKEN = "...";`.
  const marker = "const TOKEN = \""
  let start = shim.find(marker)
  doAssert start >= 0, "no TOKEN line in the rendered shim"
  let first = start + marker.len
  shim[first ..< shim.find('"', first)]

template appRun(run: int; body: untyped) =
  ## Starts `startApp` on a thread, runs `body` with `port` bound, then waits
  ## (bounded) for the app to end and joins the thread.
  resetShared()
  var th: Thread[int]
  createThread(th, appThread, run)
  try:
    check waitUntil(IoTimeout, proc(): bool = sharedPort() != 0)
    let port {.inject.} = sharedPort()
    acquire shared.lock
    let early = shared.failure
    release shared.lock
    doAssert port != 0, "startApp did not launch a window within " & $IoTimeout &
      " ms" & (if early.len > 0: " (" & early & ")" else: "")
    body
  finally:
    if not waitUntil(IoTimeout, isDone):
      # Last resort so a failing test cannot hang the suite: the app ends by
      # itself once asked to quit.
      quitApp()
    joinThread(th)
  acquire shared.lock
  let failure = shared.failure
  release shared.lock
  check failure == ""

template serveRun(port: int; startPath: string; body: untyped) =
  ## `appRun` for serve mode: nothing is launched, so the test waits for
  ## window 1 to exist instead of a launch URL.
  resetShared()
  var th: Thread[(int, string)]
  createThread(th, serveThread, (port, startPath))
  try:
    check waitUntil(IoTimeout, proc(): bool = isDone() or windows().len == 1)
    acquire shared.lock
    let early = shared.failure
    release shared.lock
    doAssert not isDone(), "serve-mode startApp ended early: " & early
    body
  finally:
    if not waitUntil(IoTimeout, isDone):
      quitApp()
    joinThread(th)
  acquire shared.lock
  let failure = shared.failure
  release shared.lock
  check failure == ""

type
  Attempt = object
    ## A `startApp` call that is expected to raise before starting.
    serve: bool
    port: int
    origins: seq[string]
    error: string   # "<exception name>: <message>", or "" if it returned

proc attemptThread(a: ptr Attempt) {.thread.} =
  {.cast(gcsafe).}:
    setTestLauncher(fakeLaunch)
    setTestProfileSweep(recordSweep)
    try:
      startApp(webDir = "fixtures/web", embedAssets = false, serve = a.serve,
               port = a.port, allowedOrigins = a.origins, browsers = @[],
               gracePeriodMs = Grace, startupTimeoutMs = 300)
    except CatchableError as e:
      a.error = $e.name & ": " & e.msg
    finally:
      setTestLauncher(nil)
      setTestProfileSweep(nil)
      finish(erQuit)

proc attemptStart(serve: bool; port: int; origins: seq[string]): string =
  ## Runs `startApp` on a thread (so a missing refusal cannot hang the
  ## suite) and returns what it raised.
  resetShared()
  var a = Attempt(serve: serve, port: port, origins: origins)
  var th: Thread[ptr Attempt]
  createThread(th, attemptThread, addr a)
  if not waitUntil(IoTimeout, isDone):
    quitApp()
  joinThread(th)
  a.error

proc nothingStarted(): bool =
  ## No launch, no sweep, no hook since the last `resetShared`.
  acquire shared.lock
  result = shared.launches.len == 0 and shared.sweeps == 0 and
           shared.windowOpens == 0 and shared.windowCloses == 0
  release shared.lock

proc readUntilClose(c: var WsClient; maxFrames = 3): int =
  ## The close code of the first close frame among the next `maxFrames`
  ## frames, or -1.
  for _ in 1 .. maxFrames:
    let f = c.readFrame()
    if f.opcode == opClose:
      return decodeClose(f).code
  -1

proc opens(): int =
  acquire shared.lock
  result = shared.windowOpens
  release shared.lock

proc closes(): int =
  acquire shared.lock
  result = shared.windowCloses
  release shared.lock

# --- tests -----------------------------------------------------------------------

var firstToken = ""

suite "neel: startApp end to end":
  test "disk assets: routes, shim, upgrade checks, calls both ways, quitApp":
    appRun(1):
      let base = "http://127.0.0.1:" & $port
      acquire shared.lock
      check shared.launches == @[base & "/?window=1"]
      let profileDir = shared.userDataDirs[0]
      let sweptAtStart = shared.sweeps
      release shared.lock
      check sweptAtStart == 0 # the sweep never runs before or during launch
      check dirExists(profileDir)

      # /neel.js for window 1, named by the page URL in Referer.
      let shim = http(port, NeelJsPath, headers = @[("Referer", base & "/?window=1")])
      check shim.status == 200
      check shim.header("Content-Type") == "application/javascript"
      check shim.header("Cache-Control") == "no-store"
      let token = tokenIn(shim.body)
      firstToken = token
      check token.len == 32
      check token.allCharsInSet({'0' .. '9', 'a' .. 'f'})
      check ("const WINDOW_ID = 1;") in shim.body
      const exposedNames = @["add", "askJs", "whichWindow", "stop", "markWorker",
                             "openSecond", "closeSecond"]
      check ("const EXPOSED = " & jsStringArrayLiteral(exposedNames) & ";") in shim.body
      check shim.body == renderNeelJs(token, 1, exposedNames)
      # A page that names no window (no Referer, an unparsable one, no
      # `window=`) gets the single open window.
      check http(port, NeelJsPath).body == shim.body
      check http(port, NeelJsPath, headers = @[("Referer", "not a url")]).body == shim.body
      check http(port, NeelJsPath, headers = @[("Referer", base & "/")]).body == shim.body
      check http(port, NeelJsPath, headers = @[("Referer", base & "/?window=x")]).body ==
        shim.body
      # A page that names a window which is not open never gets another
      # window's shim.
      let stale = http(port, NeelJsPath, headers = @[("Referer", base & "/?window=9")])
      check stale.status == 404
      check stale.body == "neel.js: window 9 is not open; this page belongs to a " &
        "window Neel has closed"
      check token notin stale.body

      # Assets through the real server.
      let index = http(port, "/")
      check index.status == 200
      check index.header("Content-Type") == "text/html"
      check index.header("Accept-Ranges") == "bytes"
      check index.body == readFile(FixtureDir / "index.html")
      check http(port, "/?window=1").body == index.body
      let nested = http(port, "/sub/page.html")
      check nested.status == 200
      check nested.body == readFile(FixtureDir / "sub" / "page.html")
      check http(port, "/missing.js").status == 404
      check http(port, "/../neel.nimble").status == 404
      check http(port, "/", "POST").status == 405
      let head = http(port, "/app.js", "HEAD")
      check head.status == 200
      check head.body == ""
      check head.header("Content-Length") == $readFile(FixtureDir / "app.js").len
      let blob = http(port, "/media/blob.bin", headers = @[("Range", "bytes=0-3")])
      check blob.status == 206
      check blob.body == "\x00\x01\x02\x03"

      # The no-browser page needs no token and leaks none.
      let page = http(port, NoBrowserPath)
      check page.status == 200
      check page.header("Content-Type").startsWith("text/html")
      check token notin page.body
      check "fallback" in page.body
      check "browserPath" in page.body

      # /ws: token and window id are both required.
      let wrongToken = handshake(port, (if token[0] == '0': "1" else: "0") &
                                       token[1 .. ^1], 1)
      check wrongToken.status.startsWith("HTTP/1.1 403")
      wrongToken.client.sock.close()
      let wrongWindow = handshake(port, token, 2)
      check wrongWindow.status.startsWith("HTTP/1.1 403")
      wrongWindow.client.sock.close()
      let noToken = handshake(port, "", 1)
      check noToken.status.startsWith("HTTP/1.1 403")
      noToken.client.sock.close()
      check http(port, WsPath).status == 403

      # Requests that did not come from a Neel page are refused before any
      # route sees them (`requestRefusal`; docs/GUIDE.md "Security"): another
      # host name (DNS rebinding), another site's page, a WebSocket from
      # another origin.
      for target in ["/", NeelJsPath, NoBrowserPath]:
        for host in ["attacker.example:" & $port, "localhost:" & $port, "127.0.0.1"]:
          let rebound = http(port, target, host = host)
          check rebound.status == 403
          check rebound.body == "neel: refused: the Host header must be " & ownHost(port)
        let crossSite = http(port, target, headers = @[("Sec-Fetch-Site", "cross-site")])
        check crossSite.status == 403
        check crossSite.body == "neel: refused: cross-site request"
        check token notin crossSite.body
        # Even a top-level navigation (a link on another site) is refused.
        let crossNav = http(port, target, headers = @[("Sec-Fetch-Site", "cross-site"),
            ("Sec-Fetch-Mode", "navigate"), ("Sec-Fetch-Dest", "document")])
        check crossNav.status == 403
        check crossNav.body == "neel: refused: cross-site request"
      check http(port, NeelJsPath, headers = @[("Sec-Fetch-Site", "same-origin")]).body ==
        shim.body
      check http(port, "/", headers = @[("Sec-Fetch-Site", "none")]).status == 200
      let noHeaders = newSeq[(string, string)]()
      for (host, origin, extra) in [
          ("attacker.example:" & $port, OwnOrigin, noHeaders),
          ("", "http://attacker.example", noHeaders),
          ("", "http://127.0.0.1:" & $(port + 1), noHeaders),
          ("", "", noHeaders),
          ("", OwnOrigin, @[("Sec-Fetch-Site", "cross-site")])]:
        let refused = handshake(port, token, 1, host = host, origin = origin,
                                headers = extra)
        check refused.status.startsWith("HTTP/1.1 403")
        refused.client.sock.close()

      var (c, status) = handshake(port, token, 1)
      check status.startsWith("HTTP/1.1 101")

      # JS -> Nim with a return value.
      c.sendMsg(callMsg("add", @[%2, %3], id = 1))
      check c.readMsg() == retMsg(1, %5)
      c.sendMsg(callMsg("whichWindow", @[], id = 2))
      check c.readMsg() == retMsg(2, %1)

      # Nim -> JS from inside an exposed proc: answer the call, get the result.
      c.sendMsg(callMsg("askJs", @[%21], id = 3))
      let fromNim = c.readMsg()
      check fromNim.kind == msgCall
      check fromNim.name == "jsDouble"
      check fromNim.args == @[%21]
      check fromNim.id > 0
      c.sendMsg(retMsg(fromNim.id, %42))
      check c.readMsg() == retMsg(3, %42)
      # ... and a JS error comes back with its kind.
      c.sendMsg(callMsg("askJs", @[%1], id = 4))
      let again = c.readMsg()
      check again.name == "jsDouble"
      c.sendMsg(errMsg(again.id, "TypeError", "not a number"))
      check c.readMsg() == errMsg(4, "TypeError", "not a number")

      # Structured errors.
      c.sendMsg(callMsg("bogus", @[], id = 5))
      check c.readMsg() == errMsg(5, "NeelUnknownProcError", "no exposed proc named 'bogus'")
      c.sendMsg(callMsg("add", @[%1], id = 6))
      check c.readMsg() == errMsg(6, "NeelArgumentError", "add: expected 2 arguments, got 1")
      # Malformed text is dropped; the connection survives.
      c.sock.send(encodeText("{\"t\":\"bogus\"}", Key))
      c.sendMsg(callMsg("add", @[%40, %2], id = 7))
      check c.readMsg() == retMsg(7, %42)

      # A second window, then the stale-tab scenario from the roundtrip
      # example in a default-browser tab (docs/GUIDE.md "Multiple windows"):
      # after closeWindow the tab survives; refreshing it must not hand it
      # window 1's shim, or it would bind as window 1 and displace this
      # connection.
      c.sendMsg(callMsg("openSecond", @[], id = 8))
      check c.readMsg() == retMsg(8, %2)
      acquire shared.lock
      check shared.launches.len == 2
      check shared.launches[1] == base & "/sub/page.html?window=2"
      release shared.lock
      let second = http(port, NeelJsPath,
                        headers = @[("Referer", base & "/sub/page.html?window=2")])
      check second.status == 200
      check ("const WINDOW_ID = 2;") in second.body
      # With two windows open a page that names none cannot be placed.
      check http(port, NeelJsPath).status == 404
      c.sendMsg(callMsg("closeSecond", @[%2], id = 9))
      check c.readMsg() == retMsg(9, newJNull())
      # The stale tab refreshes: no shim, no upgrade.
      let gone = http(port, NeelJsPath,
                      headers = @[("Referer", base & "/sub/page.html?window=2")])
      check gone.status == 404
      check "window 2 is not open" in gone.body
      let staleWs = handshake(port, token, 2)
      check staleWs.status.startsWith("HTTP/1.1 403")
      staleWs.client.sock.close()
      # ... and window 1 is untouched: still mapped, `js` still has a target.
      c.sendMsg(callMsg("whichWindow", @[], id = 10))
      check c.readMsg() == retMsg(10, %1)
      c.sendMsg(callMsg("askJs", @[%5], id = 11))
      let probe = c.readMsg()
      check probe.name == "jsDouble"
      c.sendMsg(retMsg(probe.id, %10))
      check c.readMsg() == retMsg(11, %10)

      # A worker that will report its own exit (checked after the run).
      c.sendMsg(callMsg("markWorker", @[], id = 12))
      check c.readMsg() == retMsg(12, newJNull())

      # quitApp from an exposed proc ends the app; shutdown says goodbye.
      c.sendMsg(callMsg("stop", @[], id = 13))
      var sawClose = false
      for _ in 0 .. 2:
        let f = c.readFrame()
        if f.opcode == opClose:
          check decodeClose(f).code == CloseGoingAway
          sawClose = true
          break
      check sawClose
      c.sock.close()
      check waitUntil(IoTimeout, isDone)
    check shared.reason == erQuit
    acquire shared.lock
    let dirs = shared.userDataDirs
    let seen = shared.workersSeen
    let exited = shared.workersExited
    let exitedAtClose = shared.exitedAtWindowClose
    let sweeps = shared.sweeps
    let sweepOpen = shared.sweepOpenWindows
    let sweepDirs = shared.sweepDirsLeft
    let sweepExited = shared.sweepExited
    let sweepLate = shared.sweepAfterReturn
    release shared.lock
    # The exit sweep ran once, after teardown and the joins, before returning.
    check sweeps == 1
    check sweepOpen == 0
    check sweepDirs == 0
    check sweepExited == seen
    check not sweepLate
    check dirs.len == 2
    check not dirExists(dirs[0])   # removed by teardown
    check not dirExists(dirs[1])   # removed by closeWindow
    # Window teardown ran while every worker was still alive (they free
    # their blocks), and the workers were joined afterwards.
    check seen == 1
    check exitedAtClose == 0
    check exited == seen

  test "embedded assets: a second run, fresh token, grace period after the last close":
    appRun(2):
      let base = "http://127.0.0.1:" & $port
      let shim = http(port, NeelJsPath, headers = @[("Referer", base & "/?window=1")])
      check shim.status == 200
      let token = tokenIn(shim.body)
      check token.len == 32
      check token != firstToken
      let index = http(port, "/")
      check index.status == 200
      check index.body == readFile(FixtureDir / "index.html")
      check http(port, "/style.css").header("Content-Type") == "text/css"
      check http(port, "/missing").status == 404
      var (c, status) = handshake(port, token, 1)
      check status.startsWith("HTTP/1.1 101")
      c.sendMsg(callMsg("add", @[%20, %22], id = 1))
      check c.readMsg() == retMsg(1, %42)
      # The browser window goes away: the grace period ends the app.
      let t0 = getMonoTime()
      c.sock.close()
      check waitUntil(IoTimeout, isDone)
      let took = int((getMonoTime() - t0).inMilliseconds)
      check took >= Grace - 50
      check took < IoTimeout
    check shared.reason == erLastWindowClosed
    acquire shared.lock
    let dirs = shared.userDataDirs
    let sweeps = shared.sweeps
    let sweepDirs = shared.sweepDirsLeft
    release shared.lock
    check sweeps == 1
    check sweepDirs == 0
    check dirs.len == 1
    check not dirExists(dirs[0])

  test "local mode: a non-root startPath leaves / alone; windows open, close, and quit as before":
    appRun(3):
      let base = "http://127.0.0.1:" & $port
      acquire shared.lock
      check shared.launches == @[base & "/sub/page.html?window=1"]
      release shared.lock
      # `/` serves index.html as always; only serve mode redirects it.
      let index = http(port, "/")
      check index.status == 200
      check index.header("Location") == ""
      check index.body == readFile(FixtureDir / "index.html")
      check http(port, NoBrowserPath).status == 200
      let shim = http(port, NeelJsPath,
                      headers = @[("Referer", base & "/sub/page.html?window=1")])
      check shim.status == 200
      let token = tokenIn(shim.body)
      var (c, status) = handshake(port, token, 1)
      check status.startsWith("HTTP/1.1 101")
      check waitUntil(IoTimeout, proc(): bool = opens() == 1)
      c.sendMsg(callMsg("openSecond", @[], id = 1))
      check c.readMsg() == retMsg(1, %2)
      c.sendMsg(callMsg("closeSecond", @[%2], id = 2))
      check c.readMsg() == retMsg(2, newJNull())
      check closes() == 1
      c.sendMsg(callMsg("stop", @[], id = 3))
      check c.readUntilClose() == CloseGoingAway
      c.sock.close()
      check waitUntil(IoTimeout, isDone)
    check shared.reason == erQuit
    acquire shared.lock
    let sweeps = shared.sweeps
    let dirs = shared.userDataDirs
    release shared.lock
    check sweeps == 1
    check closes() == 2
    check dirs.len == 2
    check not dirExists(dirs[0])
    check not dirExists(dirs[1])

  test "a missing web directory fails before anything starts":
    resetShared()
    setTestLauncher(fakeLaunch)
    setTestProfileSweep(recordSweep)
    var msg = ""
    try:
      startApp(webDir = "fixtures/no-such-web", embedAssets = false,
               browsers = @[])
    except OSError as e:
      msg = e.msg
    finally:
      setTestLauncher(nil)
      setTestProfileSweep(nil)
    check "web directory not found" in msg
    check "no-such-web" in msg
    acquire shared.lock
    check shared.launches.len == 0
    check shared.sweeps == 0
    release shared.lock

  test "the public surface re-exports what applications need":
    check NeelVersion == "2.0.0"
    check DefaultGracePeriodMs >= MinGracePeriodMs
    check DefaultMaxMessageSize == 16 * 1024 * 1024
    check currentWindowId() == NoWindow
    check compiles(openWindow("/x"))
    check compiles(closeWindow(Window(id: 1, js: js)))
    check compiles(windows())
    check compiles(window(1))
    check compiles(requireWindow(1))
    check compiles(currentWindow())
    check compiles(quitApp())
    check compiles(js.wait(100).foo(1))
    check compiles(jsSend(js, "echo", @[%1]))
    check compiles(some((800, 600)) is Option[WindowSize])
    check compiles(@[Chrome, Chromium, Default])
    # std/json and std/options come with `import neel` (see the import list).
    check (%*{"a": 1, "b": [1, 2]})["b"][1].getInt == 2
    check parseJson("[1,2,3]").to(seq[int]) == @[1, 2, 3]
    check (%"x").getStr == "x"
    check some(3).get == 3
    check none(Window).isNone
    let size: Option[WindowSize] = some((800, 600))
    check size.get.width == 800
    check NeelArgumentError is CatchableError
    check NeelUnknownProcError is CatchableError
    check NeelNoWindowError is CatchableError
    check NeelTimeoutError is CatchableError
    check NeelDisconnectedError is CatchableError
    check NeelRemoteError is CatchableError
    check NeelBrowserError is CatchableError
    check NeelServeModeError is CatchableError
    # Internal wiring stays internal. (`NeelProtocolError`, `NeelFrameError`,
    # `LaunchOptions`, `NeelJsPath`, and the test hooks are reachable here
    # only through this file's `neel/*` imports.)
    check not declared(runApp)
    check not declared(Launcher)
    check not declared(AssetSource)
    check not declared(initJsProxy)
    check not declared(CurrentWindow)
    check not declared(UseDefaultTimeout)
    check not compiles(initWindows())
    check not compiles(bindConnection(1, 1))
    check not compiles(connectionOpened(1))
    check not compiles(resetJsBridge())
    check not compiles(waitForAppExit())
    check not declared(noLaunch)
    check not compiles(openVirtualWindow("/"))

  test "js.<name> reaches the page unless a Nim proc accepts the proxy":
    # What docs/GUIDE.md "Calling the page from Nim" promises, checked with the
    # names `import neel` brings into scope (`std/json`, `std/options`, ...).
    let win = Window(id: 1, js: js)
    check typeof(js.wait.len()) is JsonNode
    check typeof(js.wait.add(1)) is JsonNode
    check typeof(js.wait.close()) is JsonNode
    check typeof(js.wait.open("/x")) is JsonNode
    check typeof(js.wait.alert("hi")) is JsonNode
    check typeof(win.js.wait.close()) is JsonNode
    # The documented collisions: Nim's own procs win.
    check typeof(js.wait.echo()) is void
    check typeof(js.wait.repr()) is string

suite "neel: serve mode":
  test "serve mode refuses port = 0 before anything starts":
    let err = attemptStart(serve = true, port = 0, origins = @[])
    check err.startsWith("ValueError: ")
    check "port" in err
    check nothingStarted()

  test "allowedOrigins without serve is refused before anything starts":
    for port in [0, freePort()]:
      let err = attemptStart(serve = false, port = port,
                             origins = @["https://myapp.example.com"])
      check err == "ValueError: neel: allowedOrigins requires serve = true"
      check nothingStarted()

  test "a malformed allowedOrigins entry is refused before the port is bound":
    let port = freePort()
    let err = attemptStart(serve = true, port = port,
                           origins = @["https://myapp.example.com",
                                       "https://myapp.example.com/"])
    check err.startsWith("ValueError: neel: allowedOrigins entry ")
    check "path" in err
    check nothingStarted()
    check not canConnect(port)

  test "no browser, / redirects, public origins, one window for every device, only quitApp ends it":
    let port = freePort()
    serveRun(port, "/sub/page.html"):
      # Nothing was launched or probed (the browserPath does not exist).
      acquire shared.lock
      check shared.launches.len == 0
      check shared.userDataDirs.len == 0
      release shared.lock
      check windows().len == 1
      check windows()[0].id == 1

      # Routing.
      let root = http(port, "/")
      check root.status == 302
      check root.header("Location") == "/sub/page.html"
      check root.body == ""
      check http(port, "/", "HEAD").status == 302
      check http(port, "/?window=1").header("Location") == "/sub/page.html"
      let page = http(port, "/sub/page.html")
      check page.status == 200
      check page.body == readFile(FixtureDir / "sub" / "page.html")
      check http(port, "/index.html").body == readFile(FixtureDir / "index.html")
      check http(port, "/", "POST").status == 405
      let noBrowser = http(port, NoBrowserPath)
      check noBrowser.status == 404
      check "fallback" notin noBrowser.body

      # The shim: a page loaded through a proxy names no window.
      let shim = http(port, NeelJsPath, host = "myapp.example.com",
                      headers = @[("Referer", "https://myapp.example.com/sub/page.html")])
      check shim.status == 200
      check "const WINDOW_ID = 1;" in shim.body
      let token = tokenIn(shim.body)

      # Request filtering with the configured (normalized) origins.
      let login = http(port, "/sub/page.html", host = "myapp.example.com",
                       headers = @[("Sec-Fetch-Site", "cross-site"),
                                   ("Sec-Fetch-Mode", "navigate"),
                                   ("Sec-Fetch-Dest", "document")])
      check login.status == 200
      check http(port, "/", host = "tunnel.example:8080").status == 302
      let foreign = http(port, "/", host = "attacker.example")
      check foreign.status == 403
      check foreign.body == "neel: refused: the Host header must be 127.0.0.1:" &
        $port & " or the host of an allowed origin"
      let framed = http(port, "/sub/page.html", headers = @[
        ("Sec-Fetch-Site", "cross-site"), ("Sec-Fetch-Mode", "navigate"),
        ("Sec-Fetch-Dest", "iframe")])
      check framed.status == 403

      # Well past startupTimeoutMs without a connection: still running.
      sleep(ServeStartupTimeout + 400)
      check not isDone()
      check windows().len == 1
      check opens() == 0

      # Device A, through the proxy.
      var (a, stA) = handshake(port, token, 1, host = "myapp.example.com",
                               origin = "https://myapp.example.com")
      check stA.startsWith("HTTP/1.1 101")
      a.sendMsg(callMsg("add", @[%2, %3], id = 1))
      check a.readMsg() == retMsg(1, %5)
      a.sendMsg(callMsg("whichWindow", @[], id = 2))
      check a.readMsg() == retMsg(2, %1)
      check opens() == 1
      # The window API that serve mode does not support answers structurally.
      a.sendMsg(callMsg("openSecond", @[], id = 3))
      let opened = a.readMsg()
      check opened.kind == msgErr
      check opened.id == 3
      check opened.error.kind == "NeelServeModeError"
      a.sendMsg(callMsg("closeSecond", @[%1], id = 4))
      let closed = a.readMsg()
      check closed.kind == msgErr
      check closed.error.kind == "NeelServeModeError"
      check windows().len == 1

      # Device B, on the machine itself, displaces A.
      var (b, stB) = handshake(port, token, 1)
      check stB.startsWith("HTTP/1.1 101")
      check a.readUntilClose() == CloseNormal
      a.sock.close()
      b.sendMsg(callMsg("whichWindow", @[], id = 1))
      check b.readMsg() == retMsg(1, %1)
      check opens() == 1

      # B goes away; well past gracePeriodMs the app is still up.
      b.sock.close()
      check waitUntil(IoTimeout, proc(): bool = connectionCount() == 0)
      sleep(Grace + 400)
      check not isDone()
      check windows().len == 1
      check closes() == 0

      # Device C, behind a proxy that rewrites Host, reconnects to window 1.
      var (c, stC) = handshake(port, token, 1, origin = "http://tunnel.example:8080")
      check stC.startsWith("HTTP/1.1 101")
      c.sendMsg(callMsg("whichWindow", @[], id = 1))
      check c.readMsg() == retMsg(1, %1)
      check opens() == 1

      # quitApp ends the run.
      c.sendMsg(callMsg("stop", @[], id = 2))
      check c.readUntilClose() == CloseGoingAway
      c.sock.close()
      check waitUntil(IoTimeout, isDone)
    check shared.reason == erQuit
    check opens() == 1
    check closes() == 1
    acquire shared.lock
    check shared.sweeps == 0
    check shared.launches.len == 0
    release shared.lock

  test "a startPath whose path is / (query or fragment only) is not redirected to":
    # Redirecting `/` to `/?tab=2` or `/#x` would land on `/` again forever.
    for startPath in ["/?tab=2", "/#settings", "", "/"]:
      let port = freePort()
      serveRun(port, startPath):
        let root = http(port, "/")
        check root.status == 200
        check root.header("Location") == ""
        check root.body == readFile(FixtureDir / "index.html")
        quitApp()
        check waitUntil(IoTimeout, isDone)
      check shared.reason == erQuit
    # A startPath without a leading slash is redirected to its absolute form.
    let port = freePort()
    serveRun(port, "sub/page.html"):
      check http(port, "/").header("Location") == "/sub/page.html"
      quitApp()
      check waitUntil(IoTimeout, isDone)
