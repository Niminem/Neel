## neel.nim - public surface of Neel 2.0.
##
## This is the only module an application imports. It provides `startApp`
## and re-exports the user-facing pieces of the internal modules under
## `neel/`: the `expose` pragma, the `js` proxy, the window API (`openWindow`,
## `closeWindow`, `windows`, `window`, `requireWindow`, `currentWindow`), the
## `Browser` enum and launch option types, `quitApp`, and the `Neel*Error`
## exception types. It also re-exports `std/json` and `std/options`, because
## the API hands out `JsonNode` (`js.wait.foo(...)`) and `Option` (`window(id)`,
## `size = some((800, 600))`) values that an application needs to unpack.
##
## `startApp` is a macro: it generates the dispatch `case` over every proc
## bound with `{.expose.}` (so it must be called after them and after the
## imports of modules that contain them; it may sit inside `main()`), picks
## the asset mode at compile time (`embedAssets`), and forwards every other
## keyword argument verbatim to `runApp`, the ordinary proc that wires the
## server, protocol, window, and browser modules together and blocks the
## calling thread until the last window closes (plus the grace period),
## `quitApp()` is called, or no window ever connects. All IO and all exposed
## procs run on Neel's own threads: the IO thread owns the sockets, a pool of
## workers runs the hooks and the exposed procs, and `js.wait.*` may be used
## from any thread that knows a window.
##
## Routes served by `runApp`'s request handler (all on `127.0.0.1`):
## - `/ws`: the WebSocket upgrade; requires the launch token and a known
##   window id in the query, otherwise 403.
## - `/neel.js`: the browser shim rendered for one window (token, window id,
##   exposed names), `Cache-Control: no-store`.
## - `/neel/no-browser`: the page shown when no browser was found and
##   `fallback = false`.
## - everything else: the web directory through `neel/assets`.
##
## Everything else lives in `neel/*.nim`; see `PLAN.md` "Module layout" for
## the responsibility of each.

when (NimMajor, NimMinor, NimPatch) < (2, 2, 12):
  # Older allocators crash (intermittently, mostly on Windows) when memory is
  # freed after the thread that allocated it has exited; see NOTES.md.
  {.error: "Neel requires Nim >= 2.2.12; this is Nim " & NimVersion.}

import std/[json, options, strutils, sysrand, uri, macros, os]
import neel/[http, server, pool, protocol, expose, jsproxy, frontend, browser,
             window, assets]
from neel/websocket import NeelFrameError, DefaultMaxMessageSize

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
                      withCurrentWindow
export window.Window, ExitReason, WindowHook, Launcher, openWindow, closeWindow,
       windows, window.window, requireWindow, currentWindow, isOpen,
       isConnected, quitApp, connectionCount, DefaultGracePeriodMs,
       MinGracePeriodMs, DefaultStartupTimeoutMs
export Browser, NeelBrowserError, LaunchOptions, WindowSize, WindowPosition
export NeelProtocolError, NeelTimeoutError, NeelDisconnectedError, NeelRemoteError
export NeelFrameError
export DefaultWorkers, DefaultQueueCapacity, DefaultMaxMessageSize
export AssetSource

const
  NeelVersion* = "2.0.0"
    ## Library version string, kept in sync with `neel.nimble`.
  NeelJsPath* = "/neel.js"
    ## Route of the rendered browser shim. `index.html` must load it with
    ## `<script src="/neel.js"></script>` before the app's own scripts.
  TokenBytes = 16
    ## Random bytes in the launch token (rendered as 32 lowercase hex chars,
    ## so the `/ws` query needs no percent-decoding).

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
  "<ul>\n<li>install Google Chrome or Chromium;</li>\n" &
  "<li>pass <code>browserPath = \"/path/to/the/browser\"</code> to " &
  "<code>startApp</code>;</li>\n" &
  "<li>pass <code>fallback = true</code> to run the application in this " &
  "browser instead.</li>\n</ul>\n" &
  "<p><small>Neel " & NeelVersion & "</small></p>\n</body></html>\n"

# --- server hooks ----------------------------------------------------------------

proc appSend(conn: ConnId; text: string): bool {.gcsafe.} =
  ## `SendProc` for the js bridge.
  appPtr().srv.send(conn, text)

proc appClose(conn: ConnId; code: int): bool {.gcsafe.} =
  ## `CloseProc` for the window manager.
  appPtr().srv.close(conn, code)

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

proc neelJsWindowId(req: HttpRequest): int =
  ## The window `/neel.js` is being loaded for: the `window=` query of the
  ## page URL in `Referer` when it names an open window, else the single
  ## open window when there is exactly one, else `NoWindow`.
  let referer = req.getHeader("Referer")
  if referer.len > 0:
    try:
      let id = windowIdIn(parseUri(referer).query)
      if id != NoWindow and window(id).isSome:
        return id
    except UriParseError:
      discard
  let open = windows()
  if open.len == 1:
    return open[0].id
  NoWindow

proc handleRequest(conn: ConnId; req: HttpRequest): RequestAction {.gcsafe.} =
  ## The route table (see the module header).
  let a = appPtr()
  if req.path == WsPath:
    return handleWs(a, conn, req)
  if req.httpMethod notin {hmGet, hmHead}:
    return respond(methodNotAllowed())
  case req.path
  of NeelJsPath:
    let id = neelJsWindowId(req)
    if id == NoWindow:
      return respond(initResponse(404,
        "neel.js: cannot tell which window this page belongs to; open the " &
        "page through Neel (its URL carries ?window=<id>)", "text/plain"))
    var r = okResponse(renderNeelJs(a.token, id, a.exposed), "application/javascript")
    r.addHeader("Cache-Control", "no-store")
    respond(r)
  of NoBrowserPath:
    var r = okResponse(noBrowserPage(a.search, a.fallback), "text/html; charset=utf-8")
    r.addHeader("Cache-Control", "no-store")
    respond(r)
  else:
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

proc runApp*(assets: AssetSource; dispatch: DispatchProc; exposed: seq[string];
             startPath = "/"; port = 0; workers = DefaultWorkers;
             queueCapacity = DefaultQueueCapacity;
             callTimeoutMs = DefaultCallTimeoutMs;
             maxMessageSize = DefaultMaxMessageSize;
             gracePeriodMs = DefaultGracePeriodMs;
             startupTimeoutMs = DefaultStartupTimeoutMs;
             browsers = @[Chrome, Chromium]; fallback = true; browserPath = "";
             size = none(WindowSize); position = none(WindowPosition);
             extraFlags: seq[string] = @[];
             onWindowOpen: WindowHook = nil; onWindowClose: WindowHook = nil;
             launcher: Launcher = nil): ExitReason {.discardable.} =
  ## The proc behind `startApp`; call `startApp` instead unless you build
  ## the dispatcher and asset source yourself (tests do). Blocks the calling
  ## thread and returns why the app ended. Sequence: `findBrowser` (fails
  ## fast on a bad `browserPath`), token, `newPendingTable`, `newServer`,
  ## `initJsBridge`, `listen`, `initWindows`, `openWindow(startPath)`,
  ## `waitForAppExit`; then always `shutdown` with `releaseSharedState` as
  ## its `beforeJoin` (`resetJsBridge`, `teardownWindows`, the table is
  ## dropped). `launcher` replaces the
  ## browser launch (tests inject a fake); `nil` launches for real. When no
  ## browser is found and `fallback` is `false`, the error page has been
  ## opened in the default browser: it is served for `gracePeriodMs`, then
  ## the `NeelBrowserError` propagates after teardown.
  doAssert not dispatch.isNil, "runApp: dispatch is nil"
  doAssert not app.running, "startApp is already running in this process"
  let search = findBrowser(browsers, browserPath)
  app = AppState(running: true, token: newToken(), search: search,
                 fallback: fallback, assets: assets, dispatch: dispatch,
                 exposed: exposed)
  app.tbl = newPendingTable()
  app.srv = newServer(onRequest = handleRequest, onMessage = handleMessage,
                      onOpen = connectionOpened, onClose = connectionClosed,
                      workers = workers, queueCapacity = queueCapacity,
                      maxMessageSize = maxMessageSize)
  try:
    initJsBridge(appSend, resolveWindow, app.tbl, callTimeoutMs)
    app.srv.listen(port)
    let base = "http://127.0.0.1:" & $app.srv.port
    initWindows(appClose, app.tbl, base, search, fallback,
                LaunchOptions(size: size, position: position, extraFlags: extraFlags),
                gracePeriodMs, startupTimeoutMs, launcher, onWindowOpen,
                onWindowClose)
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
    app.srv.shutdown(beforeJoin = releaseSharedState)
    app = AppState()

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
  ##   `embedAssets` is true.
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
  ## - `browsers = @[Chrome, Chromium]`, `fallback = true`, `browserPath = ""`,
  ##   `size = none(WindowSize)`, `position = none(WindowPosition)`,
  ##   `extraFlags: seq[string] = @[]`.
  ## - `onWindowOpen`, `onWindowClose: WindowHook = nil`.
  ## - `launcher: Launcher = nil`: test seam replacing the browser launch.
  ##
  ## Everything except `webDir` and `embedAssets` is forwarded verbatim to
  ## `runApp`. Must come after every `{.expose.}` proc and after the imports
  ## of modules that contain them (a proc exposed later is not dispatched).
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
        error("startApp: '" & name.strVal & "' is set by startApp itself; " &
              "call runApp directly to override it", a)
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
  let embedded = newCall(bindSym"embeddedAssets",
                         newCall(bindSym"embedWebDir", webDir, newLit(callerDir)))
  let disk = newCall(bindSym"diskAssets",
                     newCall(bindSym"resolveWebDir", newLit(callerDir), webDir))
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
