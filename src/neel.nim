## neel.nim - public surface of Neel 2.1.
##
## This is the only module an application imports. It provides `startApp`
## and re-exports the user-facing pieces of the internal modules under
## `neel/`: the `expose` pragma, the `js` proxy, the window API (`openWindow`,
## `closeWindow`, `windows`, `window`, `requireWindow`, `currentWindow`), the
## `Browser` enum and window size / position types, `quitApp`, the
## `CloseDisplaced` close code (what `neel.onclose` reports when another tab
## or device takes a window over), custom routes (`get`, `post`, `put`,
## `patch`, `delete`, `route`, with `HttpRequest` / `HttpResponse` and their
## helpers), and the `Neel*Error` exception types an
## application can see. It also re-exports `std/json` and `std/options`, because
## the API hands out `JsonNode` (`js.wait.foo(...)`) and `Option` (`window(id)`,
## `size = some((800, 600))`) values that an application needs to unpack.
##
## `startApp` is a macro: it generates the dispatch `case` over every proc
## bound with `{.expose.}` (so it must be called after them and after the
## imports of modules that contain them; it may sit inside `main()`), picks
## the asset mode at compile time (`embedAssets`), and forwards every other
## keyword argument verbatim to `runApp`, the private proc that wires the
## server, protocol, window, and browser modules together and blocks the
## calling thread until the last window closes (plus the grace period),
## `quitApp()` is called, or no window ever connects (in serve mode, until
## `quitApp()` or a stop signal: `SIGINT` / `SIGTERM`, or Ctrl-C, Ctrl-Break,
## and closing the console on Windows; no browser is launched). All IO and
## all exposed procs run on Neel's own threads: the IO thread owns the
## sockets, a pool of workers runs the hooks and the exposed procs, and
## `js.wait.*` may be used from any thread that knows a window.
##
## Routes served by `runApp`'s request handler (all on `127.0.0.1`). Every
## request first passes `frontend.requestRefusal` (`Host` must be
## `127.0.0.1:<port>`, no `Sec-Fetch-Site: cross-site`, and for `/ws` an
## `Origin` of `http://127.0.0.1:<port>`; in serve mode the hosts and
## origins of `allowedOrigins` are accepted too, and cross-site top-level
## navigations pass; a request with a method other than `GET` / `HEAD` must
## also not come from another origin), otherwise 403. In this order:
## - `/ws`: the WebSocket upgrade; requires the launch token and a known
##   window id in the query, otherwise 403.
## - `/neel.js`: the browser shim rendered for one window (token, window id,
##   exposed names, serve flag), `Cache-Control: no-store`. The window is the
##   `window=` of the page URL in `Referer`; 404 when it names a window that
##   is not open, or when it names none and more than one window is open.
## - `/neel/no-browser`: the page shown when no browser was found and
##   `fallback = false`; 404 in serve mode.
## - the application's custom routes (`routes`, see `neel/routes`): the
##   first whose pattern and method match runs its handler on the worker,
##   with the request's window as the current window (`routeWindowId`); a
##   path that only matches for other methods is 405 with their `Allow`.
## - anything left that is not `GET` / `HEAD`: 405.
## - `/` in serve mode, when `startPath` names another page: a 302 to it.
## - everything else: the web directory through `neel/assets` (nothing but
##   404s when `webDir = ""`).
##
## Tests replace the browser launch and the exit-time profile sweep, and
## observe the server's ping interval, through `neel/testhooks`, which is
## not re-exported.
##
## Everything else lives in `neel/*.nim`; each module's header comment states
## its single responsibility.

when (NimMajor, NimMinor, NimPatch) < (2, 2, 12):
  # Allocators before 2.2.12 crash (intermittently, mostly on Windows) when
  # memory is freed after the thread that allocated it has exited: the block
  # is pushed onto its owner's shared free list through thread-local state
  # that died with that thread. 2.2.12 parks that state instead of freeing it.
  {.error: "Neel requires Nim >= 2.2.12; this is Nim " & NimVersion.}

import std/[json, options, strutils, sysrand, uri, macros, os]
import neel/[http, server, pool, protocol, expose, jsproxy, frontend, browser,
             window, assets, testhooks, signals, routes]
from neel/websocket import DefaultMaxMessageSize

# --- re-exports ------------------------------------------------------------------

# Deliberate stdlib re-exports: every `js.wait.*` result is a `JsonNode` and
# `window(id)` / `currentWindow()` / `size` / `position` are `Option`s, so an
# app would otherwise need these two imports next to every `import neel`.
export json, options
export expose.expose, NeelArgumentError, NeelUnknownProcError
# `std/jsonutils` hooks that exposed-proc wrappers instantiate in the user's
# module (deliberate stdlib re-export, see `expose.nim`).
export fromJsonHook, toJsonHook
export jsproxy except initJsBridge, resetJsBridge, SendProc, WindowResolver,
                      WindowRoute, setCurrentWindow, clearCurrentWindow,
                      withCurrentWindow, initJsProxy, CurrentWindow,
                      UseDefaultTimeout
export window.Window, ExitReason, WindowHook, openWindow, closeWindow,
       windows, window.window, requireWindow, currentWindow, isOpen,
       isConnected, quitApp, connectionCount, DefaultGracePeriodMs,
       MinGracePeriodMs, DefaultStartupTimeoutMs, NeelServeModeError
export Browser, NeelBrowserError, WindowSize, WindowPosition
export CloseDisplaced
export NeelTimeoutError, NeelDisconnectedError, NeelRemoteError
export DefaultWorkers, DefaultQueueCapacity, DefaultMaxMessageSize
# Custom routes: what a handler receives, returns, and is registered with.
export HttpRequest, HttpResponse, HttpHeader, HttpMethod, HttpVersion,
       initResponse, addHeader, setHeader, getHeader, hasHeader
export Route, RouteHandler, route, routes.get, post, put, patch, routes.delete,
       param, queryParam, htmlResponse, textResponse, jsonResponse,
       redirectResponse

const
  NeelVersion* = "2.1.0"
    ## Library version string, kept in sync with `neel.nimble`.
  DefaultMaxBodySize* = MaxRequestBody
    ## Default `maxBodySize`: the largest HTTP request body, in bytes (1 MiB).
  TokenBytes = 16
    ## Random bytes in the launch token (rendered as 32 lowercase hex chars,
    ## so the `/ws` query needs no percent-decoding).
  PingIntervalMs = 30_000
    ## Serve mode's keep-alive ping interval: below nginx's 60 s
    ## `proxy_read_timeout` and the ~100 s after which Cloudflare closes an
    ## idle WebSocket. Local mode sends no pings.

type
  AppState = object
    ## Everything the hooks need, written once by `runApp` before `listen`
    ## and cleared during `shutdown`, once no hook can be running. Hooks
    ## are plain procs that reach it through `appPtr` (never closures
    ## capturing the `Server`, which the server would then store).
    running: bool
    srv: Server
    tbl: PendingTable
    token: string
    search: BrowserSearch
    fallback: bool
    assets: AssetSource
    dispatch: DispatchProc
    exposed: seq[string]
    filter: RequestFilter
    serve: bool
    rootRedirect: string   # `Location` for `GET /`; "" serves `/` as usual
    routes: seq[Route]     # custom routes, in registration order

var app: AppState
  ## Module global behind `startApp`; see `AppState`.

proc appPtr(): ptr AppState {.inline.} =
  # Write-once before `listen` on the thread running `runApp`, cleared only
  # once `shutdown` has drained every hook; readers only call through the
  # `ref` and proc fields without copying them. The cast silences the
  # GC-safety check on the global; it does not change the access pattern.
  {.cast(gcsafe).}:
    result = addr app

# --- helpers ---------------------------------------------------------------------

proc debugLog(msg: string) =
  ## Writes `msg` to stderr in debug builds; a no-op in release builds.
  when not defined(release):
    try:
      stderr.writeLine(msg)
    except IOError:
      discard

proc printLine(msg: string) =
  ## Writes `msg` to stdout in every build. An app built without a console
  ## (`--app:gui`) has no usable stdout, so a failed write is ignored.
  try:
    stdout.writeLine(msg)
    stdout.flushFile()
  except IOError:
    discard

proc checkServeParams(serve: bool; port: int; allowedOrigins: seq[string]) =
  ## The parameter combinations serve mode forbids, checked before anything
  ## is bound. The entries themselves are checked by `initRequestFilter`,
  ## which accepts origins without `serve` and would ignore them silently.
  if serve and port == 0:
    raise newException(ValueError, "neel: serve mode needs a fixed port " &
      "(port = 0 picks a random one, which a tunnel or proxy cannot reach)")
  if not serve and allowedOrigins.len > 0:
    raise newException(ValueError, "neel: allowedOrigins requires serve = true")

proc checkPages(assets: AssetSource; routes: seq[Route]) =
  ## What the app would serve, checked before anything is bound: the route
  ## list must be usable (`checkRoutes`, with Neel's own paths reserved),
  ## an app without a web directory needs at least one route, and a
  ## disk-mode web directory must exist.
  checkRoutes(routes, [WsPath, NeelJsPath, NoBrowserPath])
  if assets.mode == amNone and routes.len == 0:
    raise newException(ValueError, "neel: webDir is \"\" and there are no " &
      "routes, so the app has nothing to serve")
  if assets.mode == amDisk and not dirExists(assets.root):
    raise newException(OSError, "neel: web directory not found: " & assets.root)

proc rootRedirectFor(startPath: string): string =
  ## Where serve mode sends `GET /`: `startPath` with a leading `/`, or `""`
  ## when its path (before any `?` or `#`) is `/` itself, which a redirect
  ## would send back to `/` forever.
  var p = startPath
  if p.len == 0 or p[0] != '/':
    p = "/" & p
  let pathEnd = p.find({'?', '#'})
  if (if pathEnd < 0: p else: p[0 ..< pathEnd]) == "/": "" else: p

proc serveStartupLine(port: int; origins: seq[string]): string =
  "neel: serving http://" & LoopbackHost & ":" & $port & " (allowed origins: " &
    (if origins.len == 0: "none" else: origins.join(", ")) & ")"

proc newToken(): string =
  ## `TokenBytes` bytes from the OS random source as lowercase hex.
  var bytes: array[TokenBytes, byte]
  if not urandom(bytes):
    raise newException(OSError, "neel: could not read random bytes for the launch token")
  result = newStringOfCap(TokenBytes * 2)
  for b in bytes:
    result.add toLowerAscii(toHex(b))

proc sameToken(a, b: string): bool =
  ## Constant-time comparison (the token is a secret, even on loopback).
  if a.len != b.len:
    return false
  var diff = 0
  for i in 0 ..< a.len:
    diff = diff or (ord(a[i]) xor ord(b[i]))
  diff == 0

proc queryParams(query: string): seq[(string, string)] =
  ## Decoded `key=value` pairs of a query string; empty when malformed.
  try:
    for (k, v) in decodeQuery(query):
      result.add((k, v))
  except UriParseError:
    discard

proc parseWindowId(v: string): int =
  ## `v` as a positive window id, or `NoWindow`.
  try:
    let id = parseInt(v)
    if id > 0: id else: NoWindow
  except ValueError:
    NoWindow

proc windowIdIn(query: string): int =
  ## The `window=` parameter of a query string, or `NoWindow`.
  for (k, v) in queryParams(query):
    if k == WindowQueryParam:
      return parseWindowId(v)
  NoWindow

proc htmlEscape(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"))

proc noBrowserPage(search: BrowserSearch; fallback: bool): string =
  ## The HTML served at `NoBrowserPath`: what was searched and how to fix it.
  ## Carries no token.
  var items = ""
  for line in search.describeSearch:
    items.add "<li><code>" & htmlEscape(line) & "</code></li>\n"
  if items.len == 0:
    items = "<li>No browser was in the preference list.</li>\n"
  "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n" &
  "<title>Neel: no supported browser found</title>\n" &
  "<style>body{font:16px/1.5 system-ui,sans-serif;max-width:46em;margin:3em auto;" &
  "padding:0 1em;color:#222}code{background:#f3f3f3;padding:.1em .3em}</style>\n" &
  "</head><body>\n<h1>Neel could not find a supported browser</h1>\n" &
  "<p>This application was started with <code>fallback = " & $fallback &
  "</code>, so Neel did not open it in your default browser. It looked for:</p>\n" &
  "<ul>\n" & items & "</ul>\n" &
  "<p>To fix this, do one of the following and start the application again:</p>\n" &
  "<ul>\n<li>install Google Chrome, Chromium, or Microsoft Edge;</li>\n" &
  "<li>pass <code>browserPath = \"/path/to/the/browser\"</code> to " &
  "<code>startApp</code>;</li>\n" &
  "<li>pass <code>fallback = true</code> to run the application in this " &
  "browser instead.</li>\n</ul>\n" &
  "<p><small>Neel " & NeelVersion & "</small></p>\n</body></html>\n"

# --- server hooks ----------------------------------------------------------------

proc appSend(conn: ConnId; text: string): bool {.gcsafe.} =
  ## `SendProc` for the js bridge.
  appPtr().srv.send(conn, text)

proc appClose(conn: ConnId; code: int; reason: string): bool {.gcsafe.} =
  ## `CloseProc` for the window manager.
  appPtr().srv.close(conn, code, reason)

proc handleWs(a: ptr AppState; conn: ConnId; req: HttpRequest): RequestAction =
  ## `/ws`: a valid upgrade with the launch token and a known window id is
  ## bound (`bindConnection`) and upgraded; anything else is 403.
  if isWebSocketUpgrade(req):
    var token = ""
    var windowId = NoWindow
    for (k, v) in queryParams(req.query):
      if k == TokenQueryParam:
        token = v
      elif k == WindowQueryParam:
        windowId = parseWindowId(v)
    if sameToken(token, a.token) and windowId != NoWindow and
        bindConnection(windowId, conn):
      return upgrade()
  respond(initResponse(403, "403 Forbidden", "text/plain"))

proc refererWindowId(req: HttpRequest): int =
  ## The `window=` query of the page URL in `Referer`, or `NoWindow` when
  ## there is no `Referer`, it does not parse, or it carries no valid id.
  let referer = req.getHeader("Referer")
  if referer.len > 0:
    try:
      result = windowIdIn(parseUri(referer).query)
    except UriParseError:
      discard

proc openWindowFor(named: int): int =
  ## The window a request belongs to, given the one it names: `named` when
  ## that window is open; the single open window when it names none
  ## (`NoWindow`) and exactly one is open; otherwise `NoWindow`. A request
  ## that names a window which is *not* open never gets the fallback.
  if named != NoWindow:
    return if window(named).isSome: named else: NoWindow
  let open = windows()
  if open.len == 1: open[0].id else: NoWindow

proc neelJsWindowId(req: HttpRequest): tuple[id, named: int] =
  ## The window `/neel.js` is being loaded for. `named` is the `window=`
  ## query of the page URL in `Referer` (`NoWindow` when there is no
  ## `Referer`, it does not parse, or it carries no valid id). `id` is
  ## `named` when that window is open; the single open window when the page
  ## named none and exactly one is open; otherwise `NoWindow`. A page that
  ## names a window which is *not* open gets `NoWindow`, never the fallback:
  ## it belongs to a window Neel has closed or retired (typically a stale
  ## default-browser tab being refreshed), and handing it the shim of a
  ## window that is still open would let it bind as that window and displace
  ## the real page (see `docs/GUIDE.md` "Multiple windows").
  result.named = refererWindowId(req)
  result.id = openWindowFor(result.named)

proc routeWindowId(req: HttpRequest): int =
  ## The current window of a custom route's handler: the window the request
  ## names (the `window=` of its own URL, as on the page load of a window
  ## Neel opened; otherwise of the page URL in `Referer`, as on a `fetch`
  ## or a form submission from such a page) when it is open, or the single
  ## open window when the request names none (always the case in serve
  ## mode, also for a webhook). `NoWindow` when it names a window that is
  ## not open, or names none while several are open.
  var named = windowIdIn(req.query)
  if named == NoWindow:
    named = refererWindowId(req)
  openWindowFor(named)

proc serveNeelJs(a: ptr AppState; req: HttpRequest): HttpResponse =
  ## `/neel.js` for the window `neelJsWindowId` finds, or a 404 saying why
  ## there is none.
  let (id, named) = neelJsWindowId(req)
  if id == NoWindow:
    let reason =
      if named != NoWindow:
        "neel.js: window " & $named & " is not open; this page belongs " &
        "to a window Neel has closed"
      else:
        "neel.js: cannot tell which window this page belongs to; open the " &
        "page through Neel (its URL carries ?window=<id>)"
    return initResponse(404, reason, "text/plain")
  result = okResponse(renderNeelJs(a.token, id, a.exposed, a.serve),
                      "application/javascript")
  result.addHeader("Cache-Control", "no-store")

proc serveNoBrowser(a: ptr AppState): HttpResponse =
  ## `/neel/no-browser`: the error page in local mode, 404 in serve mode.
  if a.serve:
    return notFound()
  result = okResponse(noBrowserPage(a.search, a.fallback), "text/html; charset=utf-8")
  result.addHeader("Cache-Control", "no-store")

proc runRoute(a: ptr AppState; m: RouteMatch; req: HttpRequest): HttpResponse =
  ## Runs the handler of the matched custom route with the captured
  ## parameters, under the request's window (`routeWindowId`). A
  ## `CatchableError` it raises, or a result that cannot go on the wire
  ## (`finishRouteResponse`), becomes a bare 500; debug builds say why on
  ## stderr.
  const failed = "500 Internal Server Error"
  let what = "neel: route " & req.rawMethod & " " & req.path
  # A plain proc pointer (`nimcall`): copying it shares nothing.
  let handle = handler(a.routes[m.index])
  var r = req
  r.params = m.params
  try:
    withCurrentWindow(routeWindowId(req)):
      result = handle(r)
  except CatchableError as e:
    debugLog(what & " raised " & $e.name & ": " & e.msg)
    return initResponse(500, failed, "text/plain")
  let problem = finishRouteResponse(result)
  if problem.len > 0:
    debugLog(what & " returned a response that cannot be sent: " & problem)
    return initResponse(500, failed, "text/plain")

proc handleRequest(conn: ConnId; req: HttpRequest): RequestAction {.gcsafe.} =
  ## The route table (see the module header), behind `requestRefusal`.
  let a = appPtr()
  let refusal = requestRefusal(req, a.srv.port, a.filter)
  if refusal.len > 0:
    return respond(initResponse(403, refusal, "text/plain"))
  if req.path == WsPath:
    return handleWs(a, conn, req)
  let readOnly = req.httpMethod in {hmGet, hmHead}
  if req.path == NeelJsPath or req.path == NoBrowserPath:
    if not readOnly:
      return respond(methodNotAllowed())
    if req.path == NeelJsPath:
      return respond(serveNeelJs(a, req))
    return respond(serveNoBrowser(a))
  let m = findRoute(a.routes, req.httpMethod, req.path)
  case m.kind
  of rmFound:
    return respond(runRoute(a, m, req))
  of rmMethodNotAllowed:
    return respond(methodNotAllowed(m.allow))
  of rmNone:
    discard
  if not readOnly:
    return respond(methodNotAllowed())
  if req.path == "/" and a.rootRedirect.len > 0:
    var r = initResponse(302)
    r.addHeader("Location", a.rootRedirect)
    return respond(r)
  respond(serveAsset(a.assets, req))

proc handleMessage(conn: ConnId; text: string) {.gcsafe.} =
  ## `call` -> dispatch under the connection's window and reply; `ret` /
  ## `err` -> complete the pending wait. A malformed message is a peer bug:
  ## it is logged in debug builds and dropped (there is no trustworthy id to
  ## answer).
  let a = appPtr()
  var m: Msg
  try:
    m = decode(text)
  except NeelProtocolError as e:
    debugLog("neel: dropped malformed message on connection " & $conn & ": " & e.msg)
    return
  case m.kind
  of msgCall:
    var reply: Option[Msg]
    withCurrentWindow(windowIdOf(conn)):
      reply = handleCall(m, a.dispatch)
    if reply.isSome:
      discard a.srv.send(conn, encode(reply.get))
  of msgRet, msgErr:
    discard a.tbl.complete(conn, m.id, m)

# --- running ---------------------------------------------------------------------

proc releaseSharedState() {.gcsafe.} =
  ## `shutdown`'s `beforeJoin`: every hook has finished but the IO thread and
  ## the workers are still alive, so the window table, the connection map,
  ## and the pending table (all grown on workers) are freed while their
  ## owning threads can still take the blocks back.
  {.cast(gcsafe).}: # main thread; no task is running (see `shutdown`)
    resetJsBridge()
    teardownWindows()
    app.tbl = nil

proc sweepAbandonedProfiles(sweep: ProfileSweep) =
  ## The last step of `runApp`: every window, browser, and thread of this run
  ## is gone. Never raises, so it cannot mask the run's own exception.
  try:
    if sweep.isNil:
      discard sweepProfiles()
    else:
      sweep()
  except CatchableError:
    discard

proc runApp(assets: AssetSource; dispatch: DispatchProc; exposed: seq[string];
             startPath = "/"; port = 0; serve = false;
             allowedOrigins: seq[string] = @[]; workers = DefaultWorkers;
             queueCapacity = DefaultQueueCapacity;
             callTimeoutMs = DefaultCallTimeoutMs;
             maxMessageSize = DefaultMaxMessageSize;
             gracePeriodMs = DefaultGracePeriodMs;
             startupTimeoutMs = DefaultStartupTimeoutMs;
             browsers = @[Chrome, Chromium, Edge]; fallback = true; browserPath = "";
             size = none(WindowSize); position = none(WindowPosition);
             extraFlags: seq[string] = @[];
             onWindowOpen: WindowHook = nil;
             onWindowClose: WindowHook = nil;
             routes: seq[Route] = @[];
             maxBodySize = DefaultMaxBodySize): ExitReason {.discardable.} =
  ## The proc behind `startApp`, which reaches it through `bindSym`. Blocks
  ## the calling thread and returns why the app ended. Sequence:
  ## `findBrowser` (fails fast on a bad `browserPath`), token,
  ## `newPendingTable`, `newServer`, `initJsBridge`, `listen`, `initWindows`,
  ## `openWindow(startPath)`, `waitForAppExit`; then always `shutdown` with
  ## `releaseSharedState` as its `beforeJoin` (`resetJsBridge`,
  ## `teardownWindows`, the table is dropped), and last the profile sweep
  ## (`sweepProfiles()`: delete profile dirs abandoned by killed or crashed
  ## apps, within `SweepBudgetMs`). `testhooks` may replace the browser
  ## launch and the sweep (tests inject fakes) and observe the server's ping
  ## interval; all three are read once here.
  ## When no browser is found and `fallback` is `false`, the error page has
  ## been opened in the default browser: it is served for `gracePeriodMs`,
  ## then the `NeelBrowserError` propagates after teardown. A disk-mode web
  ## directory that does not exist raises `OSError` before anything starts
  ## (embedding already fails at compile time), and so does, with
  ## `ValueError`, a route list that cannot work (`checkPages`). `routes`
  ## is stored for `handleRequest`; `maxBodySize` is the server's limit on
  ## a request body.
  ##
  ## Serve mode (`serve = true`) first rejects `port = 0` and a malformed
  ## `allowedOrigins` entry (`ValueError`; `allowedOrigins` without `serve`
  ## is rejected too), skips `findBrowser` and the test launcher, creates
  ## window 1 with `openVirtualWindow` (nothing is launched), installs the
  ## stop-signal handlers (`neel/signals`), pings WebSocket connections idle
  ## for 30 s, so proxies keep them open (local mode sends no pings), prints
  ## `neel: serving http://127.0.0.1:<port> (allowed origins: ...)` to stdout,
  ## waits for `quitApp()` or a stop signal (both `erQuit`), and skips the
  ## profile sweep. After `shutdown` it reports shutdown finished (a Windows
  ## console-close handler waits for that) and restores the previous signal
  ## handlers, also when the run raised. The browser parameters,
  ## `gracePeriodMs`, and `startupTimeoutMs` are ignored.
  doAssert not dispatch.isNil, "runApp: dispatch is nil"
  doAssert not app.running, "startApp is already running in this process"
  checkServeParams(serve, port, allowedOrigins)
  let filter = initRequestFilter(serve, allowedOrigins)
  checkPages(assets, routes)
  let launcher = if serve: Launcher(noLaunch) else: testLauncher()
  let profileSweep = testProfileSweep()
  let pingObserver = testPingObserver()
  let search = if serve: BrowserSearch() else: findBrowser(browsers, browserPath)
  app = AppState(running: true, token: newToken(), search: search,
                 fallback: fallback, assets: assets, dispatch: dispatch,
                 exposed: exposed, filter: filter, serve: serve,
                 rootRedirect: if serve: rootRedirectFor(startPath) else: "",
                 routes: routes)
  app.tbl = newPendingTable()
  app.srv = newServer(onRequest = handleRequest, onMessage = handleMessage,
                      onOpen = connectionOpened, onClose = connectionClosed,
                      workers = workers, queueCapacity = queueCapacity,
                      maxMessageSize = maxMessageSize,
                      pingIntervalMs = if serve: PingIntervalMs else: 0,
                      maxBodySize = maxBodySize)
  try:
    if not pingObserver.isNil:
      pingObserver(app.srv.pingIntervalMs)
    initJsBridge(appSend, resolveWindow, app.tbl, callTimeoutMs)
    app.srv.listen(port)
    let base = "http://" & LoopbackHost & ":" & $app.srv.port
    initWindows(appClose, app.tbl, base, search, fallback,
                LaunchOptions(size: size, position: position, extraFlags: extraFlags),
                gracePeriodMs, startupTimeoutMs, launcher, onWindowOpen,
                onWindowClose, serve)
    if serve:
      discard openVirtualWindow(startPath)
      installStopHandlers()
      printLine(serveStartupLine(app.srv.port, filter.origins))
    else:
      try:
        discard openWindow(startPath)
      except NeelBrowserError as e:
        try:
          stderr.writeLine("neel: " & e.msg)
        except IOError:
          discard
        sleep(gracePeriodMs) # let the default browser fetch the error page
        raise
    result = waitForAppExit()
  finally:
    try:
      app.srv.shutdown(beforeJoin = releaseSharedState)
      app = AppState()
    finally:
      if serve:
        reportShutdownFinished()
        removeStopHandlers()
    if not serve:
      sweepAbandonedProfiles(profileSweep)

proc stampCallSite(n, site: NimNode) =
  ## Gives every node the macro created (recognisable by carrying this
  ## module's position; `quote do` also re-stamps substituted user nodes that
  ## way) the position of `site`, the user's `startApp(...)` call, so
  ## diagnostics point at user code. Nodes that already point elsewhere (the
  ## user's own argument expressions) are left alone. A plain proc on
  ## purpose: a nested closure capturing a macro parameter reads it as `nil`
  ## in the VM.
  const thisFile = currentSourcePath()
  if n.lineInfoObj.filename == thisFile:
    n.copyLineInfo(site)
  for child in n:
    stampCallSite(child, site)

macro startApp*(args: varargs[untyped]): untyped =
  ## Starts the application and blocks until it ends. Returns the
  ## `ExitReason` (discardable). Keyword arguments, all optional:
  ##
  ## - `webDir = "web"`: the web directory, resolved against the directory
  ##   of the source file that calls `startApp` unless absolute (may also be
  ##   given as the single positional argument). Must be a constant when
  ##   `embedAssets` is true. `""` means no web directory: every page comes
  ##   from `routes`.
  ## - `embedAssets = defined(release)`: compile-time switch. `true` walks
  ##   `webDir` at compile time and embeds every file; `false` reads files
  ##   from disk on every request.
  ## - `startPath = "/"`: the page the first window opens.
  ## - `port = 0` (ephemeral), `workers = DefaultWorkers`,
  ##   `queueCapacity = DefaultQueueCapacity`,
  ##   `callTimeoutMs = DefaultCallTimeoutMs` (`js.wait` default),
  ##   `maxMessageSize = DefaultMaxMessageSize` (16 MiB; the largest single
  ##   WebSocket message the server will accept),
  ##   `gracePeriodMs = DefaultGracePeriodMs` (exit this long after the last
  ##   window closes; at least `MinGracePeriodMs`),
  ##   `startupTimeoutMs = DefaultStartupTimeoutMs`.
  ## - `serve = false`: serve mode. No browser is launched and the app runs
  ##   until `quitApp()`, with one window shared by whichever device
  ##   connected last. Needs a fixed `port`; ignores the browser parameters,
  ##   `gracePeriodMs`, and `startupTimeoutMs`.
  ## - `allowedOrigins: seq[string] = @[]`: serve mode only. Extra origins
  ##   (`https://host[:port]` or `http://host[:port]`) the app may be loaded
  ##   from, e.g. through a tunnel or reverse proxy. Raises `ValueError` for
  ##   a malformed entry.
  ## - `browsers = @[Chrome, Chromium, Edge]`, `fallback = true`, `browserPath = ""`,
  ##   `size = none(WindowSize)`, `position = none(WindowPosition)`,
  ##   `extraFlags: seq[string] = @[]`.
  ## - `onWindowOpen`, `onWindowClose: WindowHook = nil`.
  ## - `routes: seq[Route] = @[]`: custom routes, built with `get`, `post`,
  ##   `put`, `patch`, `delete`, or `route`. They are answered before the
  ##   web directory, by list order, on a worker thread. Raises `ValueError`
  ##   for a route on a reserved path (`/ws`, `/neel.js`,
  ##   `/neel/no-browser`) or one that an earlier route shadows.
  ## - `maxBodySize = DefaultMaxBodySize` (1 MiB): the largest request body
  ##   the server accepts; a larger one is answered 400.
  ##
  ## Everything except `webDir` and `embedAssets` is forwarded verbatim to
  ## the private `runApp`. Must come after every `{.expose.}` proc and after
  ## the imports of modules that contain them (a proc exposed later is not
  ## dispatched).
  let callerDir = parentDir(args.lineInfoObj.filename)
  var webDir = newLit("web")
  var embed = newCall(ident"defined", ident"release")
  var forwarded: seq[NimNode]
  var positional = 0
  for a in args:
    if a.kind == nnkExprEqExpr:
      let name = a[0]
      if name.kind != nnkIdent:
        error("startApp: expected `name = value`", a)
      if name.eqIdent("webDir"):
        webDir = a[1]
      elif name.eqIdent("embedAssets"):
        embed = a[1]
      elif name.eqIdent("assets") or name.eqIdent("dispatch") or
          name.eqIdent("exposed"):
        error("startApp: '" & name.strVal & "' is set by startApp itself", a)
      else:
        forwarded.add a
    else:
      if positional > 0:
        error("startApp: only the web directory may be positional; use " &
              "keyword arguments for everything else, e.g. " &
              "startApp(\"web\", port = 8000)", a)
      webDir = a
      inc positional
  let dispatchName = ident"neelDispatch"
  dispatchName.copyLineInfo(args)
  let assetsName = genSym(nskLet, "neelAssets")
  let generate = newCall(bindSym"generateDispatch", dispatchName)
  var call = newCall(bindSym"runApp", assetsName, dispatchName,
                     newCall(bindSym"exposedNames"))
  for f in forwarded:
    call.add f
  let embedded = newCall(bindSym"embeddedWebDirAssets", webDir,
                         newCall(bindSym"embedWebDir", webDir, newLit(callerDir)))
  let disk = newCall(bindSym"webDirAssets", newLit(callerDir), webDir)
  result = quote do:
    block:
      `generate`
      when `embed`:
        let `assetsName` = `embedded`
      else:
        let `assetsName` = `disk`
      `call`
  # Diagnostics for the generated code (a non-constant `embedAssets`, a
  # missing web directory, a wrong argument type) should point at the user's
  # `startApp(...)` line, not into this module.
  stampCallSite(result, args)
