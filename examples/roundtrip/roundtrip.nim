## roundtrip.nim - return values in both directions and a second window.
##
## What it shows:
## - JS -> Nim with a return value: `await neel.sum([...])`.
## - Nim -> JS -> Nim: `askPage` calls `js.wait.answer(...)`, an async
##   function the page registered with `neel.expose`, and returns its result.
## - Two windows: `openSecond` opens `web/second.html` in a second browser
##   window; `askSecond(id)` targets that window explicitly with
##   `requireWindow(id).js.wait(5000).ask(...)` and returns the answer to the
##   first page; `closeSecond` closes it; `listWindows` reports `windows()`.
## - The structured errors the first page sees when the second window is
##   closed (`NeelNoWindowError`), slow (`NeelTimeoutError`), closed in the
##   middle of a wait (`NeelDisconnectedError`), or throws (`PromptCancelled`,
##   the JS error name forwarded through `NeelRemoteError`).
## - `onWindowOpen` / `onWindowClose` hooks, which print to the terminal.
##
## How to run (from any directory; the paths below are relative to the repo):
##
##   nim c -r examples/roundtrip/roundtrip.nim
##       debug build: `web/` is served from disk; exit 3 s after the last
##       window closes.
##
##   nim c -d:release examples/roundtrip/roundtrip.nim
##   ./examples/roundtrip/roundtrip
##       release build: `web/` is embedded; the grace period is 10 s.
##
## Each window is its own Chrome process with a private profile, so opening
## the second window takes a moment. Expect Chromium's stderr noise.

import neel # also brings std/json (`getStr`) and std/options (`isSome`, `get`)

type
  WindowInfo = object
    ## One row of the `windows()` readout on the first page.
    id: int
    connected: bool

proc sum(numbers: seq[int]): int {.expose.} =
  ## JS -> Nim with a return value.
  for n in numbers:
    result += n

proc askPage(question: string): string {.expose.} =
  ## Nim -> JS -> Nim, back into the page that made this call: `js` targets
  ## the current window inside an exposed proc. `answer` is an async JS
  ## function registered with `neel.expose`; the shim awaits it before
  ## replying, so `js.wait` receives the resolved value.
  let reply = js.wait.answer(question)
  "the page answered: " & reply.getStr

proc openSecond(): int {.expose.} =
  ## Opens `web/second.html` in a new window and returns its id. The page's
  ## URL carries `?window=2`, which is how its `/neel.js` learns the id.
  openWindow("/second.html").id

proc askSecond(id: int): string {.expose.} =
  ## Asks window `id` a question and returns its answer (a `prompt` there).
  ## `requireWindow` raises `NeelNoWindowError` once the window has been
  ## closed, which the first page sees as a structured error.
  requireWindow(id).js.wait(5000)
    .ask("Window 1 asks: what is your favourite number?").getStr

proc closeSecond(id: int) {.expose.} =
  ## Closes window `id` with a clean 1000 close, so its shim does not try to
  ## reconnect; the browser process is terminated. A no-op when already gone.
  let w = window(id)
  if w.isSome:
    closeWindow(w.get)

proc listWindows(): seq[WindowInfo] {.expose.} =
  ## `windows()` as data: every open window and whether it is connected.
  for w in windows():
    result.add WindowInfo(id: w.id, connected: w.isConnected)

proc windowOpened(w: Window) {.gcsafe.} =
  echo "window ", w.id, " opened"

proc windowClosed(w: Window) {.gcsafe.} =
  echo "window ", w.id, " closed"

startApp(onWindowOpen = windowOpened, onWindowClose = windowClosed)
