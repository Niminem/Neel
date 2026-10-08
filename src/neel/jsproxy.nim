## jsproxy.nim - the `js` proxy: calling browser-side functions from Nim.
##
## `js.foo(a, b)` sends a fire-and-forget `call` to the current window and
## returns nothing. `js.wait.foo(a, b)` and `js.wait(timeoutMs).foo(a, b)`
## send a `call` with an id, block on the pending table from `protocol.nim`,
## and return the `JsonNode` the browser answered with (`.to(T)` from
## `std/json` for a typed value). `win.js.foo(...)` targets an explicit window
## through the `js*: JsProxy` field Task 12 puts on `Window`.
##
## Surface:
## - `JsProxy` / `JsWaitProxy`: plain objects of `int` fields (no `ref`s) so
##   the global `js` is usable from `{.gcsafe.}` worker code. `JsProxy.windowId`
##   is either `CurrentWindow` (0, "the window whose exposed proc is running
##   on this thread") or a window id; `JsWaitProxy` adds `timeoutMs`
##   (`UseDefaultTimeout` = 0 means the configured call timeout).
## - `js`: the global proxy targeting the current window. `initJsProxy(id)`
##   builds a proxy for an explicit window (what `Window.js` holds).
## - `wait(p, timeoutMs = UseDefaultTimeout): JsWaitProxy`.
## - The two `.()` dot-operator macros expand `js.foo(args...)` to
##   `jsSend(js, "foo", @[...])` (void) and `js.wait.foo(args...)` to
##   `jsCallWait(js.wait, "foo", @[...])` (`JsonNode`). Each argument is
##   converted with `expose.convertResult` (`std/jsonutils.toJson`, enums as
##   names), so what JS receives as a call argument looks exactly like what it
##   receives as an exposed-proc result: `bool`, integers, floats, `string`,
##   enums, `seq` / `array` / `set`, tuples, objects, `ref`, `distinct`,
##   `Option`, `Table[string, V]`, `HashSet`, and `JsonNode` (passed through;
##   use `newJNull()` for an explicit null, `nil` has no type). Any
##   expression is accepted, not only literals.
## - `jsSend` / `jsCallWait` are also the public escape hatch for dynamic
##   names and for JS function names that are also Nim procs: method-call
##   syntax is resolved before dot operators, so `js.echo("x")` calls Nim's
##   `echo` and `js.repr()` calls `repr`; write `jsSend(js, "echo", @[%"x"])`
##   instead. Bare `js.foo` without parentheses is the compiler's ordinary
##   "undeclared field" error (only `.()` is defined, not `.`).
## - Current window: a thread-local id set by the dispatcher around each
##   exposed-proc call (`withCurrentWindow(id): body`, or `setCurrentWindow` /
##   `clearCurrentWindow`); `currentWindowId()` reads it (`NoWindow` = 0 when
##   none). Exposed procs run on pool workers, so it is set per call, never
##   cached.
## - `NeelNoWindowError` when a proxy targets the current window and this
##   thread has none, when it targets a window id that is not connected, or
##   when the bridge has not been initialised (Neel is not running).
##
## Wiring (the bridge): this module imports neither `window.nim` nor
## `neel.nim`. `initJsBridge(sendText, resolveWindow, pending,
## defaultTimeoutMs)` installs, write-once before `listen`, the send proc
## (`Server.send` in production), a resolver from window id to
## `WindowRoute(conn, ids)` (Task 12 implements it over its window table;
## `ids` is the per-connection `IdAllocator`, `nil` = not connected), the
## `PendingTable`, and the default call timeout. Tests inject a recording
## send proc and a fake resolver. `resetJsBridge()` clears it after
## `shutdown`; `initJsBridge` may then be called again.
##
## Naming: the module is `jsproxy`, not `js`, on purpose. A module name wins
## over a symbol of the same name, so a module called `js` would make
## `js.foo(1)` module-qualified access ("undeclared identifier: 'foo'") in
## every file that imports it. `neel.nim` re-exports with `import
## neel/jsproxy; export jsproxy`.
##
## Threading: `jsSend`, `jsCallWait`, and the current-window procs are
## `{.gcsafe.}` and may run on any thread. The bridge record is a module
## global written only by `initJsBridge` / `resetJsBridge` on the main thread
## while no worker is running and read everywhere else through one
## `{.cast(gcsafe).}` accessor; readers never copy its `ref` fields (they call
## through them), so no refcount is touched concurrently. `{.experimental:
## "dotOperators".}` is enabled only here; the user's module needs nothing
## (Task 2 spike (b)).

{.experimental: "dotOperators".}

import std/[json, macros]
import ./protocol
from ./expose import convertResult
from ./server import ConnId, `$`

const
  CurrentWindow* = 0
    ## `JsProxy.windowId` value meaning "the current window of this thread"
    ## (what the global `js` carries). Real window ids are positive.
  NoWindow* = 0
    ## `currentWindowId()` result when no current window is set on this
    ## thread. Numerically the same as `CurrentWindow`; a window id is never 0.
  UseDefaultTimeout* = 0
    ## `JsWaitProxy.timeoutMs` value meaning "the bridge's default call
    ## timeout" (what `js.wait` without an argument carries).
  DefaultCallTimeoutMs* = 10_000
    ## Default for `initJsBridge`'s `defaultTimeoutMs`: how long
    ## `js.wait.foo(...)` blocks before `NeelTimeoutError`.

type
  NeelNoWindowError* = object of CatchableError
    ## Raised when a `js` call has no window to go to: the proxy targets the
    ## current window and none is set on this thread (the call is not inside
    ## an exposed proc), the proxy targets a window id that is not connected,
    ## or the bridge is not initialised (Neel is not running).

  JsProxy* = object
    ## Fire-and-forget proxy. `js.foo(args...)` sends a `call` without id.
    windowId*: int
      ## `CurrentWindow` or the id of an explicit window (`Window.js`).

  JsWaitProxy* = object
    ## Blocking proxy produced by `wait`. `js.wait.foo(args...)` sends a
    ## `call` with an id and returns the reply's value.
    windowId*: int  ## As in `JsProxy`.
    timeoutMs*: int ## Positive, or `UseDefaultTimeout` for the configured one.

  WindowRoute* = object
    ## What the window resolver returns for a window id.
    conn*: ConnId
      ## The window's WebSocket connection.
    ids*: ptr IdAllocator
      ## The per-connection id counter, owned by the window record and alive
      ## while the connection is; `nil` means the window is not connected.

  SendProc* = proc(conn: ConnId; text: string): bool {.gcsafe.}
    ## Sends one text message; `false` if the connection is gone
    ## (`Server.send` in production).

  WindowResolver* = proc(windowId: int): WindowRoute {.gcsafe.}
    ## Maps a window id (never `CurrentWindow`; that is resolved here first)
    ## to its route, or to a route with `ids == nil` when unknown or not
    ## connected. Called on any thread.

  JsBridge = object
    ready: bool
    sendText: SendProc
    resolveWindow: WindowResolver
    pending: PendingTable
    defaultTimeoutMs: int

const
  js* = JsProxy(windowId: CurrentWindow)
    ## The proxy for the current window: `js.foo(...)`, `js.wait.foo(...)`.

var
  bridge: JsBridge
    ## Written only by `initJsBridge` / `resetJsBridge` (main thread, no
    ## worker running); read through `bridgePtr` from any thread.
  currentWindowVar {.threadvar.}: int
    ## Per-thread current window id, `NoWindow` when none.

# --- current window --------------------------------------------------------------

proc currentWindowId*(): int {.gcsafe.} =
  ## The id of this thread's current window, or `NoWindow` if none is set.
  ## Task 12's `currentWindow()` reads this.
  currentWindowVar

proc setCurrentWindow*(id: int) {.gcsafe.} =
  ## Makes `id` this thread's current window (what `js` targets). Prefer
  ## `withCurrentWindow`, which restores the previous value.
  currentWindowVar = id

proc clearCurrentWindow*() {.gcsafe.} =
  ## Unsets this thread's current window.
  currentWindowVar = NoWindow

template withCurrentWindow*(id: int; body: untyped) =
  ## Runs `body` with `id` as this thread's current window and restores the
  ## previous value afterwards, also on exceptions. Task 13 wraps its
  ## `handleCall` in this: `withCurrentWindow(windowIdOf(conn)): reply =
  ## handleCall(m, neelDispatch)`.
  let savedWindow = currentWindowId()
  setCurrentWindow(id)
  try:
    body
  finally:
    setCurrentWindow(savedWindow)

# --- bridge ----------------------------------------------------------------------

proc initJsBridge*(sendText: SendProc; resolveWindow: WindowResolver;
                   pending: PendingTable;
                   defaultTimeoutMs = DefaultCallTimeoutMs) =
  ## Installs the pieces `jsSend` / `jsCallWait` need. Call on the main thread
  ## before the first `js.*` and before any thread that may use `js` is
  ## started (in `startApp`: after `newPendingTable`, before `listen`). May
  ## be called again only after `shutdown` (no worker running), e.g. by
  ## tests; `resetJsBridge` clears it.
  doAssert not sendText.isNil, "initJsBridge: sendText is nil"
  doAssert not resolveWindow.isNil, "initJsBridge: resolveWindow is nil"
  doAssert not pending.isNil, "initJsBridge: pending is nil"
  doAssert defaultTimeoutMs > 0, "initJsBridge: defaultTimeoutMs must be positive"
  bridge = JsBridge(ready: true, sendText: sendText,
                    resolveWindow: resolveWindow, pending: pending,
                    defaultTimeoutMs: defaultTimeoutMs)

proc resetJsBridge*() =
  ## Drops the installed bridge (after `shutdown`, when no `js` call can be in
  ## progress). `js.*` raises `NeelNoWindowError` until the next
  ## `initJsBridge`.
  bridge = JsBridge()

proc bridgePtr(): ptr JsBridge {.inline.} =
  # The bridge is write-once at init on the main thread while no other thread
  # exists that could read it, and readers only call through its proc and
  # table fields without copying them, so the access is race-free; the cast
  # only silences the GC-safety check on the global.
  {.cast(gcsafe).}:
    result = addr bridge

proc requireBridge(): ptr JsBridge =
  result = bridgePtr()
  if not result.ready:
    raise newException(NeelNoWindowError,
      "no window: Neel is not running (the js bridge is not initialised)")

proc routeFor(b: ptr JsBridge; windowId: int): WindowRoute =
  ## Resolves `CurrentWindow` through the thread-local, then asks the
  ## resolver; raises `NeelNoWindowError` when there is nothing to send to.
  var target = windowId
  if target == CurrentWindow:
    target = currentWindowVar
    if target == NoWindow:
      raise newException(NeelNoWindowError,
        "no current window on this thread: `js.<fn>` works inside an " &
        "exposed proc; use `win.js.<fn>` elsewhere")
  result = b.resolveWindow(target)
  if result.ids.isNil:
    raise newException(NeelNoWindowError,
      "window " & $target & " is not connected")

# --- proxies ---------------------------------------------------------------------

proc initJsProxy*(windowId: int): JsProxy =
  ## A proxy for an explicit window (Task 12 stores `initJsProxy(w.id)` in
  ## `Window.js`). `initJsProxy(CurrentWindow)` is `js`.
  JsProxy(windowId: windowId)

proc wait*(p: JsProxy; timeoutMs = UseDefaultTimeout): JsWaitProxy =
  ## The blocking form of `p`: `js.wait.foo(...)` waits up to the bridge's
  ## default timeout, `js.wait(500).foo(...)` up to 500 ms. A `timeoutMs`
  ## that is not positive means the default.
  JsWaitProxy(windowId: p.windowId, timeoutMs: timeoutMs)

proc jsSend*(p: JsProxy; name: string; args: seq[JsonNode]) {.gcsafe.} =
  ## Sends `{"t":"call","name":name,"args":args}` (no id) to `p`'s window
  ## and returns at once; the pending table is not involved and no reply is
  ## ever expected, so a connection that is closing swallows the call
  ## silently. Raises `NeelNoWindowError` if there is no window to send to.
  ## This is what `js.<name>(args...)` expands to and the escape hatch for
  ## dynamic names and names that collide with Nim procs.
  let b = requireBridge()
  let route = b.routeFor(p.windowId)
  discard b.sendText(route.conn, encode(callMsg(name, args)))

proc jsCallWait*(p: JsWaitProxy; name: string; args: seq[JsonNode]): JsonNode
    {.gcsafe.} =
  ## Sends `{"t":"call","id":N,"name":name,"args":args}` to `p`'s window and
  ## blocks until the browser's `ret` (returned as `JsonNode`) or `err`
  ## (`NeelRemoteError` with the JS error name as `kind`), the connection
  ## closes (`NeelDisconnectedError`, also when the send itself fails), or
  ## `p.timeoutMs` elapses (`NeelTimeoutError`). Raises `NeelNoWindowError`
  ## if there is no window to send to. The id comes from the window's
  ## `IdAllocator`; the wait is registered before the send so a fast reply
  ## cannot miss it. This is what `js.wait.<name>(args...)` expands to.
  let b = requireBridge()
  let route = b.routeFor(p.windowId)
  let timeoutMs = if p.timeoutMs > 0: p.timeoutMs else: b.defaultTimeoutMs
  let id = route.ids[].nextId()
  b.pending.register(route.conn, id)
  if not b.sendText(route.conn, encode(callMsg(name, args, id))):
    discard b.pending.cancel(route.conn, id)
    raise newException(NeelDisconnectedError,
      "connection " & $route.conn & " is closed; could not send call '" &
      name & "'")
  b.pending.wait(route.conn, id, timeoutMs)

# --- dot operators ---------------------------------------------------------------

proc jsName(name: NimNode): NimNode =
  ## The JS function name as a string literal.
  case name.kind
  of nnkIdent, nnkSym:
    newLit(name.strVal)
  of nnkAccQuoted:
    var s = ""
    for part in name:
      s.add part.strVal
    newLit(s)
  else:
    error("expected a JS function name", name)
    nil

proc jsArgs(args: NimNode): NimNode =
  ## `@[convertResult(a), convertResult(b), ...]`, or an empty
  ## `seq[JsonNode]` for no arguments.
  if args.len == 0:
    return newCall(nnkBracketExpr.newTree(ident"newSeq", bindSym"JsonNode"))
  var items = nnkBracket.newTree()
  for a in args:
    items.add newCall(bindSym"convertResult", a)
  prefix(items, "@")

macro `.()`*(p: JsProxy; name: untyped; args: varargs[untyped]): untyped =
  ## `p.name(args...)` -> `jsSend(p, "name", @[convertResult(arg), ...])`.
  ## Returns `void`.
  newCall(bindSym"jsSend", p, jsName(name), jsArgs(args))

macro `.()`*(p: JsWaitProxy; name: untyped; args: varargs[untyped]): untyped =
  ## `p.name(args...)` -> `jsCallWait(p, "name", @[convertResult(arg), ...])`.
  ## Returns `JsonNode`.
  newCall(bindSym"jsCallWait", p, jsName(name), jsArgs(args))
