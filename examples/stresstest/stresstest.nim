## stresstest.nim - a harness for exercising (and trying to break) the Neel
## 2.0 API from a real browser. Not a product: the page is a list of sections,
## each with buttons and a log, and the Nim side is a bag of small exposed
## procs covering types, errors, concurrency, payloads, pushes from a plain
## thread, windows, assets, and lifecycle. The page text holds the manual
## checks that cannot be automated.
##
## How to run (from any directory; the paths below are relative to the repo):
##
##   nim c -r examples/stresstest/stresstest.nim
##       debug build: `web/` served from disk; fire-and-forget failures and
##       malformed messages are logged to stderr.
##
##   nim c -d:release examples/stresstest/stresstest.nim
##   ./examples/stresstest/stresstest
##       release build: `web/` embedded; nothing is logged.
##
## Both builds use `gracePeriodMs = 3000` (the app exits 3 s after the last
## window closes) and print the `ExitReason` on exit.
##
## Limits: one WebSocket message (one call or one reply as JSON text) may be
## at most 16 MiB (`DefaultMaxMessageSize`); the payload section stays under
## that (a 2 MB string, 100k ints, nesting depth 50). `js.wait` blocks the
## calling worker up to its timeout (default 10 s); the default pool has 64
## workers.

import std/[json, options, tables, os, atomics, locks, typedthreads]
import neel

# --- types -----------------------------------------------------------------------

type
  Color = enum
    red, green, blue

  Payload = object
    ## Every field type crosses the bridge unchanged (enums as names,
    ## `Option` none as `null`, `Table` as an object).
    name: string
    tags: seq[string]
    matrix: seq[seq[int]]
    maybe: Option[int]
    color: Color
    counts: Table[string, int]
    ratio: float
    flag: bool

  WindowInfo = object
    id: int
    connected: bool

proc roundTrip(p: Payload): Payload {.expose.} =
  p

proc withDefaults(a: int; b = 10; c = "default"): string {.expose.} =
  "a=" & $a & " b=" & $b & " c=" & c

proc asJson(): JsonNode {.expose.} =
  %*{"pid": getCurrentProcessId(), "list": [1, 2.5, "three", nil, true]}

proc nothing() {.expose.} =
  discard # void: the page receives null

# --- errors ----------------------------------------------------------------------

proc failing(): int {.expose.} =
  raise newException(ValueError, "deliberate failure from Nim")

proc add(a, b: int): int {.expose.} =
  a + b # also the target for the wrong-arity / wrong-type checks

proc callJsThatThrows(): JsonNode {.expose.} =
  js.wait.jsThrows() # NeelRemoteError with the JS error name, forwarded as-is

proc callJsThatHangs(): JsonNode {.expose.} =
  js.wait(300).jsNeverResolves() # NeelTimeoutError after 300 ms

proc callMissingJs(): JsonNode {.expose.} =
  js.wait.noSuchFunction() # NeelUnknownFunctionError from the shim

# --- concurrency -----------------------------------------------------------------

var pings: Atomic[int]

proc slowAdd(a, b: int): int {.expose.} =
  sleep(50) # 500 of these must run in parallel on the pool, not one by one
  a + b

proc ping() {.expose.} =
  pings.atomicInc()

proc pingCount(): int {.expose.} =
  pings.load

proc resetPings() {.expose.} =
  pings.store(0)

proc reenter(): int {.expose.} =
  ## Re-entrancy: the JS `callBackIntoNim` awaits `neel.add(1, 2)` before it
  ## returns, so a second message on this connection must be served while
  ## this worker is blocked in `js.wait`. Messages on one connection are
  ## handled concurrently, so this does not deadlock.
  js.wait.callBackIntoNim().getInt

# --- payloads --------------------------------------------------------------------

proc echoString(s: string): string {.expose.} =
  s

proc echoInts(xs: seq[int]): seq[int] {.expose.} =
  xs

proc echoJson(n: JsonNode): JsonNode {.expose.} =
  n

# --- push from Nim (a plain thread) -----------------------------------------------

var
  pushLock: Lock
  pushThread: Thread[Window] # guarded by pushLock, with pushStarted
  pushStarted: bool
  stopPush: Atomic[bool]

initLock pushLock

proc pusher(w: Window) {.thread.} =
  ## Runs outside any exposed proc, so `js` has no current window here; the
  ## explicit `w.js` works from any thread. Fire-and-forget to a window that
  ## has gone away raises `NeelNoWindowError`, which ends the loop.
  try:
    for i in 1 .. 50:
      if stopPush.load:
        break
      w.js.progress(i)
      sleep(100)
    w.js.progressDone(stopPush.load)
  except NeelNoWindowError:
    discard

proc startProgress() {.expose.} =
  let w = currentWindow()
  if w.isNone:
    raise newException(NeelNoWindowError, "no current window")
  withLock pushLock:
    if pushStarted:
      if pushThread.running:
        raise newException(ValueError, "the progress thread is still running; press Stop")
      joinThread(pushThread)
    stopPush.store(false)
    createThread(pushThread, pusher, w.get)
    pushStarted = true

proc stopProgress() {.expose.} =
  stopPush.store(true)

# --- windows ---------------------------------------------------------------------

proc notifyOthers(kind: string; id: int) {.gcsafe.} =
  ## Pushes a window event to every other connected window. A window may be
  ## listed but not connected (loading, or closed by the user and not yet
  ## retired), in which case `js` raises `NeelNoWindowError`.
  for w in windows():
    if w.id != id:
      try:
        w.js.windowEvent(kind, id)
      except NeelNoWindowError:
        discard

proc onOpen(w: Window) {.gcsafe.} =
  echo "[hook] window ", w.id, " opened"
  notifyOthers("open", w.id)

proc onClose(w: Window) {.gcsafe.} =
  echo "[hook] window ", w.id, " closed"
  notifyOthers("close", w.id)

proc openTab(n: int): int {.expose.} =
  openWindow("/?tab=" & $n).id

proc whoAmI(): int {.expose.} =
  currentWindow().get.id # inside an exposed proc the current window is set

proc listWindows(): seq[WindowInfo] {.expose.} =
  for w in windows():
    result.add WindowInfo(id: w.id, connected: w.isConnected)

proc broadcast(msg: string): int {.expose.} =
  ## `windows()` + `win.js`: delivers `onBroadcast` to every connected
  ## window, this one included; returns how many were reached.
  for w in windows():
    try:
      w.js.onBroadcast(msg, currentWindowId())
      inc result
    except NeelNoWindowError:
      discard

proc closeById(id: int) {.expose.} =
  let w = window(id)
  if w.isNone:
    raise newException(NeelNoWindowError, "window " & $id & " is not open")
  closeWindow(w.get) # blocks ~100 ms for the browser process to exit

proc askWindow(id: int; timeoutMs: int): JsonNode {.expose.} =
  ## Blocks on `slowAnswer()` in window `id` (which takes 10 s there). Close
  ## that window while this waits and the page gets `NeelDisconnectedError`.
  let w = window(id)
  if w.isNone:
    raise newException(NeelNoWindowError, "window " & $id & " is not open")
  w.get.js.wait(timeoutMs).slowAnswer()

# --- lifecycle -------------------------------------------------------------------

proc exitApp() {.expose.} =
  quitApp() # only signals; startApp returns erQuit on the main thread

let reason = startApp(size = some((1100, 800)), gracePeriodMs = 3000,
                      onWindowOpen = onOpen, onWindowClose = onClose)
echo "stresstest exited: ", reason
