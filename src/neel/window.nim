## window.nim - `Window` type, connection <-> window mapping, and app lifecycle.
##
## A `Window` is a small copyable handle (`id` plus the `js*: JsProxy` field
## Task 9 requires, so `win.js.foo(...)` works from any thread). The state
## behind it is a shared-allocated record kept in a module-level table: the
## browser handle from `browser.nim`, the current `ConnId` (if any), one
## `IdAllocator` for Nim -> JS call ids, and the launch parameters. Records are
## `ptr`s (never moved by the table) so the `ptr IdAllocator` handed to the
## `js` bridge stays valid; a record is freed only after the `onClose` of its
## connection has run (or at once when it never connected).
##
## Mapping: the request handler calls `bindConnection(windowId, conn)` after
## `isWebSocketUpgrade` and the token check and *before* returning
## `upgrade()`, so the mapping exists before the first message can arrive.
## `connectionOpened` / `connectionClosed` are the `onOpen` / `onClose` hooks
## (they drive the connection count); `windowIdOf(conn)` is what `onMessage`
## wraps `handleCall` with (`withCurrentWindow`). A page refresh or a shim
## reconnect presents the same window id on a new `ConnId`: `bindConnection`
## re-associates, and `connectionClosed` clears a window's connection only if
## it still points at the closing `ConnId`.
##
## API: `openWindow(path, size, position, extraFlags)` allocates an id (1, 2,
## 3, ...), builds `<base><path>?window=<id>` (`frontend.WindowQueryParam`),
## launches through the injected `Launcher` (`launchWithFallback` in
## production; tests inject a fake and never start a browser), and returns the
## `Window`. `closeWindow` sends a 1000 close (so `neel.js` does not
## reconnect), terminates the browser process, removes its profile directory,
## and refuses later binds with that id. `windows()`, `window(id)`,
## `requireWindow(id)` (raises `NeelNoWindowError` instead of returning
## `none`), and `currentWindow()` query the table. `onWindowOpen` /
## `onWindowClose` hooks fire once per window, on the thread that observes
## the event, never under the lock.
##
## Lifecycle (connection-count based): when the WebSocket count drops to 0 a
## grace period starts (`DefaultGracePeriodMs`: 3 s debug, 10 s release); a
## connection opening before it expires cancels it. `waitForAppExit()` blocks
## the main thread until the grace period expires (`erLastWindowClosed`),
## `quitApp()` is called from any thread (`erQuit`), or no window ever
## connected within the startup timeout (`erStartupTimeout`). It never calls
## server `shutdown` itself: Task 13's `startApp` does `waitForAppExit` ->
## `shutdown` -> `resetJsBridge` -> `teardownWindows` on the main thread.
## While waiting, the main thread also retires windows whose connection has
## been gone for a grace period (the browser window was closed by the user),
## so `windows()` stays truthful in multi-window apps. Every wait is bounded.
##
## Threading: everything callable from hooks or exposed procs is
## `{.gcsafe.}`. One `Lock` guards the table, every record's mutable fields,
## and the lifecycle state; `initWindows` / `teardownWindows` run on the main
## thread while no worker can touch the module. The manager is reached through
## a module-level `ptr` written only by those two procs.

import std/[locks, tables, options, strutils, monotimes, times, algorithm]
import ./pool
import ./protocol
import ./jsproxy
import ./browser
from ./server import ConnId, `==`, hash, `$`
from ./websocket import CloseNormal
from ./frontend import WindowQueryParam

const
  DefaultGracePeriodMs* = when defined(release): 10_000 else: 3_000
    ## How long the app stays up after the last WebSocket connection closes
    ## before `waitForAppExit` returns `erLastWindowClosed`. A disconnected
    ## window that does not reconnect within this period is retired too.
  MinGracePeriodMs* = 250
    ## Lower bound `initWindows` enforces: `neel.js` waits 250 ms before its
    ## first reconnect attempt after an abnormal close, so a shorter grace
    ## period would exit the app on a transient hiccup.
  DefaultStartupTimeoutMs* = 30_000
    ## How long a freshly opened window may take to make its first WebSocket
    ## connection. A window that never connects within this time is retired
    ## (its browser process terminated), and if *no* window has ever
    ## connected by then `waitForAppExit` returns `erStartupTimeout`, so a
    ## browser that never connects does not hang the app.
  IdleTickMs = 1000
    ## Upper bound on one wait inside `waitForAppExit` when nothing is due.

type
  Window* = object
    ## Handle to one browser window: plain ints only, so it is copyable,
    ## usable from `{.gcsafe.}` worker code, and `Task`-isolatable. Query the
    ## live state with `isOpen` / `isConnected`.
    id*: int
      ## Positive, unique for the app's lifetime (1, 2, 3, ...).
    js*: JsProxy
      ## `win.js.foo(...)` / `win.js.wait.foo(...)` target this window.

  ExitReason* = enum
    ## Why `waitForAppExit` returned.
    erLastWindowClosed
      ## The connection count stayed at 0 for the grace period.
    erQuit
      ## `quitApp()` was called.
    erStartupTimeout
      ## No window ever connected within `startupTimeoutMs`.

  CloseProc* = proc(conn: ConnId; code: int): bool {.gcsafe.}
    ## Starts closing a WebSocket connection with a close code
    ## (`Server.close` in production).

  Launcher* = proc(url, userDataDir: string; opts: LaunchOptions): BrowserHandle
    {.gcsafe.}
    ## Opens a browser window at `url`. The default (`nil` to `initWindows`)
    ## is `launchWithFallback` over the resolved `BrowserSearch`; tests inject
    ## a fake that returns a process-less handle.

  WindowHook* = proc(w: Window) {.gcsafe.}
    ## `onWindowOpen` / `onWindowClose` callback. Called once per window, on
    ## the thread that observes the event (a pool worker, the caller of
    ## `closeWindow`, or the main thread inside `waitForAppExit` /
    ## `teardownWindows`), never while the window lock is held.

  WindowRecord = object
    ## Shared-allocated state behind a `Window`. Mutable fields are guarded by
    ## the manager lock; `ids` is atomic and may be used through the `ptr`
    ## the resolver hands out.
    id: int
    path: string
    url: string
    userDataDir: string
    createdAt: MonoTime
    closed: bool          # closeWindow ran (or the window was retired)
    hasConn: bool
    conn: ConnId
    everConnected: bool   # a connection bound to this window has opened
    disconnectedAt: MonoTime
    ids: IdAllocator
    handle: BrowserHandle # nil until launched and after it is moved out

  WindowManager = object
    lock: Lock
    cond: Cond                 # signalled on every lifecycle-relevant change
    # Immutable after `initWindows`:
    closeConn: CloseProc
    pending: PendingTable
    baseUrl: string
    search: BrowserSearch
    fallback: bool
    defaultOpts: LaunchOptions
    gracePeriodMs: int
    startupTimeoutMs: int
    launcher: Launcher
    onOpen: WindowHook
    onClose: WindowHook
    startedAt: MonoTime
    # Guarded by `lock`:
    nextWindowId: int
    windows: Table[int, ptr WindowRecord]
    connToWindow: Table[ConnId, int]
    connCount: int
    everConnected: bool        # any connection has ever opened
    graceActive: bool
    graceDeadline: MonoTime
    quitRequested: bool

var mgr: ptr WindowManager
  ## Written only by `initWindows` / `teardownWindows` on the main thread
  ## while no other thread uses this module; read from any thread. A `ptr`
  ## global holds no GC'd memory, so `{.gcsafe.}` procs may read it.

# --- helpers ---------------------------------------------------------------------

proc requireManager(): ptr WindowManager =
  doAssert mgr != nil, "Neel windows are not initialised (initWindows has not run)"
  mgr

proc toWindow(rec: ptr WindowRecord): Window {.inline.} =
  Window(id: rec.id, js: initJsProxy(rec.id))

proc freeRecord(rec: ptr WindowRecord) =
  `=destroy`(rec[])
  deallocShared(rec)

proc finishHandle(h: BrowserHandle) =
  ## Tears a window's browser down: terminate, release the process handle,
  ## delete the profile directory. Must not run under the lock (`terminate`
  ## polls for up to `TerminateGraceMs`).
  if h != nil:
    discard h.terminate()
    h.close()
    h.removeUserDataDir()

proc launchUrl*(baseUrl, path: string; windowId: int): string =
  ## `<baseUrl><path>?window=<windowId>`: the URL a window is launched at. A
  ## `path` that already has a query gets `&window=` instead; a fragment stays
  ## at the end; a missing leading `/` is added. `baseUrl` is the server
  ## origin (`http://127.0.0.1:<port>`; a trailing slash is tolerated). Pure.
  doAssert windowId > 0, "launchUrl: window id must be positive"
  var p = path
  if p.len == 0 or p[0] != '/':
    p = "/" & p
  var fragment = ""
  let hashPos = p.find('#')
  if hashPos >= 0:
    fragment = p[hashPos .. ^1]
    p = p[0 ..< hashPos]
  let sep = if '?' in p: "&" else: "?"
  baseUrl.strip(leading = false, chars = {'/'}) & p & sep & WindowQueryParam &
    "=" & $windowId & fragment

# --- init / teardown -------------------------------------------------------------

proc realLauncher(url, userDataDir: string; opts: LaunchOptions): BrowserHandle
    {.gcsafe.} =
  ## The production launcher: `launchWithFallback` over the init-time search.
  ## The fields it reads are immutable after `initWindows`.
  let m = requireManager()
  launchWithFallback(m.search, url, noBrowserPageUrl(m.baseUrl, m.search),
                     m.fallback, userDataDir, opts)

proc initWindows*(closeConn: CloseProc; pending: PendingTable; baseUrl: string;
                  search: BrowserSearch; fallback = true;
                  defaultOpts = LaunchOptions();
                  gracePeriodMs = DefaultGracePeriodMs;
                  startupTimeoutMs = DefaultStartupTimeoutMs;
                  launcher: Launcher = nil;
                  onWindowOpen: WindowHook = nil;
                  onWindowClose: WindowHook = nil) =
  ## Creates the window table and lifecycle state. Call on the main thread
  ## after `listen` (the port is part of `baseUrl`) and before the first
  ## `openWindow`; `teardownWindows` undoes it. `closeConn` is `Server.close`
  ## (used by `closeWindow`), `pending` the `PendingTable` whose waiters are
  ## failed in `connectionClosed`, `search` the resolved `findBrowser` result,
  ## `fallback` / `defaultOpts` the `startApp` browser parameters, `launcher`
  ## an override for tests (`nil` = `launchWithFallback`). `gracePeriodMs`
  ## must be at least `MinGracePeriodMs`.
  doAssert mgr == nil, "initWindows called twice; call teardownWindows first"
  doAssert not closeConn.isNil, "initWindows: closeConn is nil"
  doAssert not pending.isNil, "initWindows: pending is nil"
  doAssert baseUrl.len > 0, "initWindows: baseUrl is empty"
  doAssert gracePeriodMs >= MinGracePeriodMs,
    "initWindows: gracePeriodMs must be at least " & $MinGracePeriodMs &
    " ms (neel.js retries 250 ms after an abnormal close)"
  doAssert startupTimeoutMs > 0, "initWindows: startupTimeoutMs must be positive"
  let m = cast[ptr WindowManager](allocShared0(sizeof(WindowManager)))
  initLock m.lock
  initCond m.cond
  m.closeConn = closeConn
  m.pending = pending
  m.baseUrl = baseUrl
  m.search = search
  m.fallback = fallback
  m.defaultOpts = defaultOpts
  m.gracePeriodMs = gracePeriodMs
  m.startupTimeoutMs = startupTimeoutMs
  m.launcher = if launcher.isNil: Launcher(realLauncher) else: launcher
  m.onOpen = onWindowOpen
  m.onClose = onWindowClose
  m.startedAt = getMonoTime()
  m.nextWindowId = 1
  m.windows = initTable[int, ptr WindowRecord]()
  m.connToWindow = initTable[ConnId, int]()
  mgr = m

proc teardownWindows*() =
  ## Terminates every remaining browser process, removes their profile
  ## directories, fires `onWindowClose` for windows still open, frees every
  ## record, and drops the manager. Main thread only, from the server
  ## `shutdown`'s `beforeJoin` (every `onClose` has run, no worker can call
  ## into this module, and the workers that grew the tables are still alive
  ## to take their blocks back). A no-op when not initialised.
  let m = mgr
  if m == nil:
    return
  mgr = nil
  var retired: seq[tuple[rec: ptr WindowRecord; handle: BrowserHandle; fire: bool]]
  acquire m.lock
  for _, rec in m.windows:
    retired.add((rec, move rec.handle, not rec.closed))
    rec.closed = true
  m.windows.clear()
  m.connToWindow.clear()
  release m.lock
  for r in retired:
    finishHandle(r.handle)
    if r.fire and m.onClose != nil:
      m.onClose(toWindow(r.rec))
    freeRecord(r.rec)
  deinitCond m.cond
  deinitLock m.lock
  `=destroy`(m[])
  deallocShared(m)

# --- connection mapping (server hooks) -----------------------------------------------

proc bindConnection*(windowId: int; conn: ConnId): bool {.gcsafe.} =
  ## Associates `conn` with window `windowId`. The request handler calls this
  ## for `/ws` after `isWebSocketUpgrade` and the token check and *before*
  ## returning `upgrade()`. Returns `false` for an unknown or closed window id
  ## (the handler should then refuse the upgrade). A known id already bound
  ## to another connection is re-associated (page refresh or shim reconnect):
  ## the new `ConnId` replaces the old one, and the old connection's
  ## `connectionClosed` will not disturb the new binding.
  let m = mgr
  if m == nil:
    return false
  acquire m.lock
  let rec = m.windows.getOrDefault(windowId)
  if rec == nil or rec.closed:
    release m.lock
    return false
  if rec.hasConn:
    m.connToWindow.del(rec.conn)
  rec.conn = conn
  rec.hasConn = true
  m.connToWindow[conn] = windowId
  release m.lock
  true

proc connectionOpened*(conn: ConnId) {.gcsafe.} =
  ## The server's `onOpen` hook: counts the connection, cancels a running
  ## grace period, and fires `onWindowOpen` the first time a connection bound
  ## to a window opens.
  let m = mgr
  if m == nil:
    return
  var fire = false
  var w: Window
  acquire m.lock
  inc m.connCount
  m.everConnected = true
  m.graceActive = false
  let id = m.connToWindow.getOrDefault(conn, NoWindow)
  if id != NoWindow:
    let rec = m.windows.getOrDefault(id)
    if rec != nil and not rec.everConnected:
      rec.everConnected = true
      fire = not rec.closed
      w = toWindow(rec)
  signal m.cond
  release m.lock
  if fire and m.onOpen != nil:
    m.onOpen(w)

proc connectionClosed*(conn: ConnId) {.gcsafe.} =
  ## The server's `onClose` hook: uncounts the connection (starting the grace
  ## period when the count reaches 0), clears the window's connection if it
  ## still points at `conn`, fails every pending Nim -> JS wait on `conn`
  ## (`pending.disconnect`), and frees the record of a window that
  ## `closeWindow` already closed. May overlap a still-running message
  ## handler for `conn`; that handler's `js` calls then fail cleanly.
  let m = mgr
  if m == nil:
    return
  var toFree: ptr WindowRecord
  acquire m.lock
  if m.connCount > 0:
    dec m.connCount
  let now = getMonoTime()
  if m.connCount == 0 and m.everConnected:
    m.graceActive = true
    m.graceDeadline = now + initDuration(milliseconds = m.gracePeriodMs)
  let id = m.connToWindow.getOrDefault(conn, NoWindow)
  if id != NoWindow:
    m.connToWindow.del(conn)
    let rec = m.windows.getOrDefault(id)
    if rec != nil and rec.hasConn and rec.conn == conn:
      rec.hasConn = false
      rec.disconnectedAt = now
      if rec.closed:
        m.windows.del(id)
        toFree = rec
  signal m.cond
  release m.lock
  discard m.pending.disconnect(conn)
  if toFree != nil:
    freeRecord(toFree)

proc windowIdOf*(conn: ConnId): int {.gcsafe.} =
  ## The id of the window `conn` is bound to, or `NoWindow`. `onMessage`
  ## uses it: `withCurrentWindow(windowIdOf(conn)): reply = handleCall(...)`.
  let m = mgr
  if m == nil:
    return NoWindow
  acquire m.lock
  result = m.connToWindow.getOrDefault(conn, NoWindow)
  release m.lock

proc resolveWindow*(windowId: int): WindowRoute {.gcsafe.} =
  ## The `WindowResolver` for `initJsBridge`: the window's connection and the
  ## address of its `IdAllocator` while it is bound and not closed, otherwise
  ## an empty route (`ids == nil`, which makes `js.*` raise
  ## `NeelNoWindowError`).
  let m = mgr
  if m == nil:
    return WindowRoute()
  acquire m.lock
  let rec = m.windows.getOrDefault(windowId)
  if rec != nil and rec.hasConn and not rec.closed:
    result = WindowRoute(conn: rec.conn, ids: addr rec.ids)
  release m.lock

proc connectionCount*(): int {.gcsafe.} =
  ## Number of open WebSocket connections (live browser windows); 0 when not
  ## initialised. For tests and diagnostics.
  let m = mgr
  if m == nil:
    return 0
  acquire m.lock
  result = m.connCount
  release m.lock

# --- window API ------------------------------------------------------------------

proc openWindow*(path = "/"; size = none(WindowSize);
                 position = none(WindowPosition);
                 extraFlags: seq[string] = @[]): Window {.gcsafe.} =
  ## Opens a new browser window at `path` (relative to the server root) and
  ## returns its handle. `size` / `position` override the `startApp`
  ## defaults when given; `extraFlags` are appended to the default extra
  ## flags. The window id is allocated first (monotonic from 1), the record
  ## is registered before the launch so a fast page load can already bind,
  ## then the launcher runs (`launchWithFallback`: a `NeelBrowserError` or a
  ## `ValueError` for a bad size propagates and the record is dropped).
  ## Callable from an exposed proc on a pool worker; blocks only for the
  ## launch itself.
  let m = requireManager()
  acquire m.lock
  let id = m.nextWindowId
  inc m.nextWindowId
  var opts = m.defaultOpts
  release m.lock
  if size.isSome:
    opts.size = size
  if position.isSome:
    opts.position = position
  for f in extraFlags:
    opts.extraFlags.add f
  let url = launchUrl(m.baseUrl, path, id)
  let dir = userDataDirFor(id)
  let rec = cast[ptr WindowRecord](allocShared0(sizeof(WindowRecord)))
  rec.id = id
  rec.path = path
  rec.url = url
  rec.userDataDir = dir
  rec.createdAt = getMonoTime()
  acquire m.lock
  m.windows[id] = rec
  release m.lock
  var handle: BrowserHandle
  try:
    handle = m.launcher(url, dir, opts)
  except CatchableError:
    acquire m.lock
    var dropped: ptr WindowRecord
    let present = m.windows.pop(id, dropped)
    if present and dropped.hasConn:
      m.connToWindow.del(dropped.conn)
    release m.lock
    if present:
      freeRecord(dropped)
    raise
  var stray: BrowserHandle
  acquire m.lock
  if m.windows.hasKey(id) and not rec.closed:
    rec.handle = handle
  else:
    stray = handle # closed (through windows()) while the launch was running
  release m.lock
  finishHandle(stray)
  Window(id: id, js: initJsProxy(id))

proc closeWindow*(w: Window) {.gcsafe.} =
  ## Closes `w`: sends a 1000 close to its connection (so `neel.js` does not
  ## reconnect), terminates the browser process, releases the handle, deletes
  ## the profile directory, and fires `onWindowClose`. The id is refused by
  ## `bindConnection` from now on. The record is freed right away when the
  ## window has no connection, otherwise when that connection's
  ## `connectionClosed` runs. Idempotent; a no-op for an unknown id.
  let m = requireManager()
  var toFree: ptr WindowRecord
  acquire m.lock
  let rec = m.windows.getOrDefault(w.id)
  if rec == nil or rec.closed:
    release m.lock
    return
  rec.closed = true
  let hasConn = rec.hasConn
  let conn = rec.conn
  let handle = move rec.handle
  if not hasConn:
    m.windows.del(w.id)
    toFree = rec
  release m.lock
  if hasConn:
    discard m.closeConn(conn, CloseNormal)
  finishHandle(handle)
  if toFree != nil:
    freeRecord(toFree)
  if m.onClose != nil:
    m.onClose(w)

proc windows*(): seq[Window] {.gcsafe.} =
  ## Every window that has not been closed, in id order. Includes windows
  ## that are still loading (never connected) and windows whose connection
  ## dropped less than a grace period ago (possibly refreshing); use
  ## `isConnected` to tell. Empty when not initialised.
  let m = mgr
  if m == nil:
    return
  acquire m.lock
  for _, rec in m.windows:
    if not rec.closed:
      result.add toWindow(rec)
  release m.lock
  result.sort(proc(a, b: Window): int = cmp(a.id, b.id))

proc window*(id: int): Option[Window] {.gcsafe.} =
  ## The open window with this id, or `none` (unknown, closed, or `NoWindow`).
  let m = mgr
  if m == nil:
    return
  acquire m.lock
  let rec = m.windows.getOrDefault(id)
  if rec != nil and not rec.closed:
    result = some toWindow(rec)
  release m.lock

proc requireWindow*(id: int): Window {.gcsafe.} =
  ## The open window with this id. Raises `NeelNoWindowError` (`"window <id>
  ## is not open"`) for an unknown, closed, or `NoWindow` id: the same lookup
  ## as `window(id)`, but a `CatchableError` instead of the `UnpackDefect`
  ## that `window(id).get` raises on `none`, so an exposed proc that targets
  ## a window the user has since closed answers with a structured error
  ## rather than taking the process down.
  let w = window(id)
  if w.isNone:
    raise newException(NeelNoWindowError, "window " & $id & " is not open")
  w.get

proc currentWindow*(): Option[Window] {.gcsafe.} =
  ## The window whose exposed proc is running on this thread
  ## (`currentWindowId()` mapped through the table), or `none` outside an
  ## exposed proc or when that window has been closed.
  window(currentWindowId())

proc isOpen*(w: Window): bool {.gcsafe.} =
  ## `true` while `w` is in the table and not closed.
  window(w.id).isSome

proc isConnected*(w: Window): bool {.gcsafe.} =
  ## `true` while `w` is open and bound to a WebSocket connection.
  let m = mgr
  if m == nil:
    return false
  acquire m.lock
  let rec = m.windows.getOrDefault(w.id)
  result = rec != nil and not rec.closed and rec.hasConn
  release m.lock

# --- lifecycle -------------------------------------------------------------------

proc quitApp*() {.gcsafe.} =
  ## Asks the app to exit: `waitForAppExit` returns `erQuit` as soon as it
  ## wakes. Callable from any thread, including a pool worker inside an
  ## exposed proc; it only signals (server `shutdown` must never run on a
  ## worker). Named `quitApp` because a zero-argument `quit()` is ambiguous
  ## with `system.quit(errorcode = QuitSuccess)`.
  let m = requireManager()
  acquire m.lock
  m.quitRequested = true
  signal m.cond
  release m.lock

proc minOpt(a: var Option[MonoTime]; b: MonoTime) {.inline.} =
  if a.isNone or b < a.get:
    a = some b

proc waitForAppExit*(): ExitReason =
  ## Blocks the calling (main) thread until the app should exit and returns
  ## why: `erQuit` after `quitApp()`; `erLastWindowClosed` when the connection
  ## count has been 0 for the grace period and no just-opened window is
  ## still within its startup timeout; `erStartupTimeout` when no connection
  ## ever opened within `startupTimeoutMs` of `initWindows` (and of every
  ## window opened since). While waiting it retires windows whose connection
  ## has been gone for a grace period or that never connected within the
  ## startup timeout: their browser is terminated, their profile directory
  ## removed, `onWindowClose` fired (on this thread), and their record freed.
  ## Does not call server `shutdown`; the caller does, then `resetJsBridge`
  ## and `teardownWindows`. Every internal wait is bounded by `IdleTickMs`.
  let m = requireManager()
  let grace = initDuration(milliseconds = m.gracePeriodMs)
  let startup = initDuration(milliseconds = m.startupTimeoutMs)
  acquire m.lock
  while true:
    let now = getMonoTime()
    var retired: seq[tuple[rec: ptr WindowRecord; handle: BrowserHandle; fire: bool]]
    var wakeAt: Option[MonoTime]
    var loading = false # a window opened recently and may still connect
    for _, rec in m.windows:
      if rec.closed:
        # Known gap (Task 6): bound but the socket died before the 101, so
        # no onClose will ever free it. Give up after the startup timeout.
        if rec.hasConn and not rec.everConnected and
            now >= rec.createdAt + startup:
          retired.add((rec, BrowserHandle(nil), false))
        continue
      if rec.everConnected:
        if not rec.hasConn:
          let deadline = rec.disconnectedAt + grace
          if now >= deadline:
            retired.add((rec, move rec.handle, true))
          else:
            wakeAt.minOpt(deadline)
      else:
        let deadline = rec.createdAt + startup
        if now >= deadline:
          retired.add((rec, move rec.handle, true))
        else:
          wakeAt.minOpt(deadline)
          loading = true
    if retired.len > 0:
      for r in retired:
        r.rec.closed = true
        if r.rec.hasConn:
          m.connToWindow.del(r.rec.conn)
        m.windows.del(r.rec.id)
      release m.lock
      for r in retired:
        finishHandle(r.handle)
        if r.fire and m.onClose != nil:
          m.onClose(toWindow(r.rec))
        freeRecord(r.rec)
      acquire m.lock
      continue
    if m.quitRequested:
      release m.lock
      return erQuit
    if m.connCount == 0 and not loading:
      if m.everConnected:
        if not m.graceActive or now >= m.graceDeadline:
          release m.lock
          return erLastWindowClosed
        wakeAt.minOpt(m.graceDeadline)
      else:
        let deadline = m.startedAt + startup
        if now >= deadline:
          release m.lock
          return erStartupTimeout
        wakeAt.minOpt(deadline)
    var timeoutMs = IdleTickMs
    if wakeAt.isSome:
      timeoutMs = int(min(max((wakeAt.get - now).inMilliseconds + 1, 1), IdleTickMs))
    discard waitTimeout(m.cond, m.lock, timeoutMs)
