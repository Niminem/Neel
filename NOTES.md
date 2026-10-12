# Neel 2.0 hardening notes

Tasks 1-15 in `PLAN.md` are implemented. This file is the working log of the
phase after that: running `nimble test` and every example on macOS, Windows,
and Linux, trying to break things, and fixing what breaks. `neel2-devel`
merges into `master` only when every platform passes everything below.

How to use this file:

- Read it (with `PLAN.md`) at the start of every session in this phase.
- Every bug, flaky test, or platform surprise gets an entry under "Findings":
  date, platform, symptom, cause, fix, and how it is tested. Keep entries
  short; link code by path.
- Rules that every later change must respect go under "Gotchas" (and, when
  they change a settled decision, in `PLAN.md` too).
- Update the verification matrix whenever a platform run finishes.

## Verification matrix

| Check | macOS | Windows | Linux |
|---|---|---|---|
| `nimble test` | passes (Nim 2.2.12, 2026-10-12, with the stale-tab fix) | passes (Nim 2.2.12, 2026-10-12, with the stale-tab fix) | not run |
| `examples/filepicker` | passes (Nim 2.2.12, 2026-10-12; debug and release, app and `@[Default]`) | passes (Nim 2.2.12, 2026-10-12; debug and release, app and `@[Default]`) | not run |
| `examples/roundtrip` | passes (Nim 2.2.12, 2026-10-12; debug and release, app and `@[Default]`, stale-tab recipe from the 2026-10-12 finding) | passes (Nim 2.2.12, 2026-10-12; debug and release, app and `@[Default]`, stale-tab recipe from the 2026-10-12 finding) | not run |
| `examples/stresstest` | passes (Nim 2.2.12, 2026-10-12; debug and release, app and `@[Default]`, kill/reconnect and refresh-after-restart checks) | passes (Nim 2.2.12, 2026-10-12; debug and release, app and `@[Default]`, kill/reconnect and refresh-after-restart checks) | not run |
| examples with `browsers = @[Edge]` | will not be run (paths and flags checked against public sources only, 2026-10-12 finding) | passes (Nim 2.2.12, 2026-10-12; all three examples and their manual checks, no leftover `msedge` processes or profile dirs) | will not be run (as macOS) |

## Gotchas

### Memory must not be freed after the thread that allocated it has exited

Nim's allocator gives every thread its own heap. A block freed by another
thread is pushed onto its owner's "shared free list", which is reached
through the owner's thread-local allocator state. Up to Nim 2.2.10 that state
dies with the thread, so freeing a block after its owning thread has been
joined writes through a dangling pointer: on Windows usually
`SIGSEGV ... addToSharedFreeList` (often only sometimes), on macOS usually
nothing visible. Nim 2.2.12 moves chunk ownership to a permanent handle and
parks a retiring thread's allocator state, which fixes this in the runtime.
Neel therefore requires Nim >= 2.2.12 (`neel.nimble`, and a compile-time
`{.error.}` in `src/neel.nim` because plain `nim c` ignores Nimble's
requirement). Nothing else can make user-created threads that call `js.*`
and then exit safe on older compilers.

Rule for Neel code (kept after the version bump, for deterministic teardown):
any shared state that a worker or the IO thread may have grown (tables, seqs,
strings, `JsonNode`s, task argument blocks) is freed while that thread is
still alive.

- `Pool.stop(drain, beforeJoin)` and `Server.shutdown(beforeJoin)` run the
  hook on the calling thread once all work is finished but before any thread
  exits. Free shared state there, not after `shutdown` returns.
- The IO thread frees the tables it grew itself, then parks until
  `shutdown` has drained the pool (the queued `onClose` tasks carry argument
  blocks it allocated), and only then exits.
- `runApp` passes `releaseSharedState` (bridge reset, `teardownWindows`, the
  pending table dropped) as the `beforeJoin`.

Tests: on 2.2.12 test state filled in by hooks or helper threads may be
freed after the join. `t_server` and `t_pool` still copy it onto the test
thread in `beforeJoin` / reserve capacity up front (see `rehome` and
`releaseState` in `tests/t_server.nim`); that is the pattern to use if a test
ever has to run on an older compiler.

### Never guess a window for a page that names one

`/neel.js` is the only place a page learns its window id (and the token).
Serving it for a window other than the one the page's URL names lets that
page bind as the other window and displace its real connection. So the
"single open window" fallback applies only when the page names *no*
window; a `window=` that is not open is a 404, however many windows are
open. Keep this in mind for anything that resolves a page to a window
(`neelJsWindowId`, `bindConnection`, future routes).

### `nimble test` and `nim c` may use different compilers

On the Windows machine `nimble test` compiles with the Nim that Nimble
installed for the package (2.2.12, under `~/.nimble/pkgs2/nim-2.2.12-*`),
while a plain `nim c -r examples/...` uses the choosenim toolchain on `PATH`
(2.2.10 until 2026-10-09, now 2.2.12). Check the "Info: using ... for compilation" line and `nim -v`
before comparing results across commands or machines.

### A fresh Edge profile signs in on its own

Every Neel window is a brand-new profile, and Edge signs a new profile in
with the Windows Microsoft account and starts sync. Edge must keep
`--disable-sync --disable-extensions --disable-features=msImplicitSignin
--no-service-autorun --edge-skip-compat-layer-relaunch` in its
`launchFlags`; test any Edge
launch change on a Windows machine signed in with a Microsoft account.
Anything a browser needs on every launch goes in its spec's `launchFlags`,
not in the common flags of `buildLaunchArgs`.

## Findings

### 2026-10-12 - Windows, Edge: `closeSecond` does not close the window

Symptom (`examples/roundtrip`, release, `browsers = @[Edge]`): the second
window opens, but "close second window" leaves it on screen. Profile dirs
`neel-<pid>-2` and `neel-<pid>-3` stayed behind in `%TEMP%`.

Cause (inferred from public reports, not traced on the machine): on
Windows Edge can relaunch itself through the compatibility layer
(`msRelaunchNoCompatLayer`) as a new process and exit the one Neel
started. The `BrowserHandle` then tracks a dead PID: `terminate` returns at
once, the real window stays, and `removeUserDataDir` fails silently
because the relaunched Edge still holds the profile. Whether Edge relaunches
depends on Windows' compatibility records for the launching executable, so
it can differ between a debug and a fresh release binary. Affects
`closeWindow`, `quitApp` teardown, and profile cleanup; closing with the
window's own X still works (WebSocket). Playwright passes the same flag
with the comment "Edge can potentially restart on Windows
(msRelaunchNoCompatLayer) ... Disable until fixed upstream"; also
MicrosoftEdge/EdgeWebDriver#189.

Fix: `--edge-skip-compat-layer-relaunch` added to Edge's `launchFlags`
(`src/neel/browser.nim`). Test: the exact Edge argv in `tests/t_browser.nim`.
The six stale `neel-*` dirs on this machine (about 390 MB) were deleted by
hand.

### 2026-10-12 - Windows, Edge: fresh profile signs in and syncs

Symptom (`examples/filepicker` with `browsers = @[Edge]`, Windows signed in
with a Microsoft account): the app window opened with a modal "we are now
syncing your browsing data ... has signed into this device" prompt (Got it /
Customize) that could not be dismissed by closing the window; a separate
normal Edge window opened with extension welcome tabs (Voice In, Loom) and a
"Keyword Surfer has been turned off" notice. The process had to be killed in
Task Manager.

Cause: Edge implicitly signs a new profile in with the Windows Microsoft
account and turns on sync, which pulls the account's extensions; their
first-run pages open in a normal window of the same (Neel) profile. Neel
gives every window a fresh profile, so this happens on every launch, and
clicking "Got it" would not stop it next time.

Fix: `launchFlags` in `BrowserSpec` (`src/neel/browser.nim`); Edge gets
`--disable-sync --disable-extensions` after Neel's common flags and before
`extraFlags`. Tried by hand first through `extraFlags`: with both flags no
prompt and no extra window; without them both came back. `--inprivate` also
works but puts "[InPrivate]" in the window title, so it was not used.

Follow-up (same day, from research, not yet tried on a machine): Selenium's
IEDriver launches Edge with a throwaway `--user-data-dir` the same way and
adds `--disable-features=msImplicitSignin` ("disable profile sync and
implicit MS account sign-in"; `--disable-sync` alone stops sync but likely
leaves the profile signed in) and `--no-service-autorun` ("disable Edge
prelaunch and other background processes on startup"). Both added to Edge's
`launchFlags`. Chromium keeps only the last `--disable-features`, so a user
`--disable-features=...` in `extraFlags` re-enables implicit sign-in
(README says to include `msImplicitSignin`). Paths checked against public
sources, since Edge is verified on Windows only: macOS
`/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge` (Edge
WebDriver docs, Playwright); bundle id `com.microsoft.edgemac` in most
sources, one reports `com.microsoft.Edge` in Info.plist, so `mdfind` tries
both; Windows `Microsoft\Edge\Application\msedge.exe` under `Program Files
(x86)` (usual), `Program Files`, or `LocalAppData`, plus `App Paths\msedge.exe`;
Linux `.deb`/`.rpm` install `/usr/bin/microsoft-edge` and
`microsoft-edge-stable`, a wrapper that `exec`s `/opt/microsoft/msedge/msedge`
(same PID, so the handle tracks the browser).

Tests: `tests/t_browser.nim` - only Edge has `launchFlags`; exact Edge argv
(flags after the common ones, before `extraFlags`); Chrome and Chromium argv
unchanged; `buildLaunchArgs(Default | Brave, ...)` is a usage error. The
static spec check rejects flags that override `--app` / `--user-data-dir`;
macOS `mdfind` falls back to `com.microsoft.Edge`.

### 2026-10-12 - All platforms: Edge supported, and in the default list

Symptom (Windows, by review): a machine without Chrome or Chromium got a
default-browser tab (usually Edge, no app mode) even though every Windows
install ships Edge, which takes the same app-mode flags.

Change: `Edge` is no longer reserved. `src/neel/browser.nim` gives it a full
spec on all three OSes (macOS `Microsoft Edge.app` in `/Applications` and
`~/Applications`, then `mdfind` by `com.microsoft.edgemac`; Windows
`Microsoft\Edge\Application\msedge.exe` under the usual roots, then registry
`App Paths\msedge.exe`; Linux `microsoft-edge`, `microsoft-edge-stable`).
`startApp`'s default is now `browsers = @[Chrome, Chromium, Edge]` on every
OS (`src/neel.nim`), so Chrome still wins when installed. Reserved members
are `Brave`, `Opera`, `Vivaldi`. The no-browser page now suggests installing
Edge as well. README, `PLAN.md` "Post-implementation changes", and the
example texts updated.

Tests: `tests/t_browser.nim` - Edge is supported with candidates on every
OS; Edge probe on macOS (fixed path, `mdfind` fallback), Windows
(`Program Files (x86)` hit, registry `msedge.exe` last and never
`chrome.exe`), Linux (`findExe` order); `@[Chrome, Chromium, Edge]` on
Windows resolves to Edge when the other two are missing. The reserved-member
tests now use Brave, Opera, and Vivaldi. `nimble test` passes on Windows
(Nim 2.2.12); `src/neel.nim` also compiled with `--os:linux` and
`--os:macosx --compileOnly`. Real launches with `browsers = @[Edge]` are not
verified yet (see the matrix).

### 2026-10-12 - All platforms: discarded background tabs (not a bug)

Chromium may discard a background tab or window (Memory Saver, memory
pressure) and reload it only when the user returns to it. The discard closes
the WebSocket, so Neel sees a closed window: a reload within `gracePeriodMs`
is a page refresh (same window id, no second `onWindowOpen`, page-side state
gone); a later reload finds the window retired, and the app gone if it was
the last one. Neel has no idle timeout on either side, so a keep-alive would
not help; an app meant to sit in a background tab should raise
`gracePeriodMs` to minutes. README "Caveats" updated (`b74d3d8`). No code
change, no test.

### 2026-10-12 - macOS, `@[Default]`: a refreshed stale tab stole window 1's identity

Symptom (`examples/roundtrip` in a default-browser tab): open window 2,
close it with the button (the tab stays, see the 2026-10-09 finding),
refresh that tab, then use "Nim -> JS -> Nim" on window 1: it fails with
`NeelNoWindowError: no current window on this thread`. Later the terminal
prints `window 1 closed` while window 1 is still on screen, and the app
does not exit until that tab is closed by hand. Not reproducible in app
mode (there `closeWindow` kills the process, so nothing is left to refresh).

Cause: `neelJsWindowId` in `src/neel.nim` fell back to "the single open
window" whenever the `Referer`'s `window=` did not name an *open* window.
The refreshed stale tab asked for `/neel.js` with `Referer ...?window=2`;
window 2 was closed, only window 1 was open, so it was served window 1's
shim. Its `/ws?window=1` upgrade then went through `bindConnection`'s
refresh path, which re-pointed window 1 at the new connection and dropped
the real page's connection from `connToWindow`. From then on the real
page's calls ran with `windowIdOf(conn) == NoWindow` (hence the error);
when the imposter tab closed, window 1 was marked disconnected and
retired by `waitForAppExit` (hence `window 1 closed`); and the real page's
socket stayed counted in `connCount` but mapped to nothing, so the app
could not exit until it was closed.

Fix: `neelJsWindowId` now returns `(id, named)`; a `Referer` that names a
window which is not open gets a 404 (`neel.js: window <n> is not open;
this page belongs to a window Neel has closed`) and never the fallback.
The fallback remains only for pages that name no window at all (no
`Referer`, unparsable, no `window=`). Sibling: `bindConnection` closes a
*displaced* connection with 1000 when it is still alive (a duplicated tab),
so a connection can no longer linger counted but unmapped; for a normal
refresh or shim reconnect the old connection is already gone and the close
is a no-op (`Server.close` returns `false`).

What a pass looks like: the refreshed stale tab shows only the page's static
HTML (no buttons, "window ?"), and its console shows the `/neel.js` 404 and
`ReferenceError: neel is not defined` from the page script. Window 1 keeps
working, and closing it exits the app with the dead tab still open.

Tests: `tests/t_neel.nim` (a `?window=9` `Referer` is 404 and leaks no
token; `openSecond` / `closeSecond` exposed procs replay the scenario
end-to-end: window 2's shim while open, 404 with two windows and no
`Referer`, 404 and 403 for the stale tab after `closeWindow`, window 1
still answers `whichWindow` and `askJs` afterwards), `tests/t_window.nim`
("a reconnect re-associates ..." checks the 1000 to the displaced
connection and that re-binding the same connection sends nothing; the
integration test opens a second live connection for window 1 and reads the
1000 on the first).

### 2026-10-09 - Windows: `t_browser` expected POSIX separators

`userDataDirFor` joins with `/` from `std/os`, which yields `\` on Windows;
the test compared against literal `"/tmp/neel-4242-1"`. Fixed in the test by
building the expected paths with `/` as well. No library change.

### 2026-10-09 - Windows: intermittent SIGSEGV when the app exits

Symptom: `nim c -r examples/filepicker/filepicker.nim` (Nim 2.2.10) sometimes
ends with `SIGSEGV` in `addToSharedFreeList`, from `server.nim` `=destroy`
called at the end of `runApp`.

Cause: the gotcha above. The main thread destroyed the server's connection
tables, which the IO thread had grown and which outlived it; the `onClose`
tasks queued at shutdown were freed by workers after the IO thread had
exited; the window manager and pending table (grown on workers) were freed
after the workers were joined. The last two only bite once those tables
outgrow their initial 32 slots, but they are the same bug.

Fix: `src/neel/server.nim` (IO thread frees its tables, parks until
released, `shutdown(beforeJoin)`, `ioThreadRunning`), `src/neel/pool.nim`
(`stop(drain, beforeJoin)`; workers exit only once released), and
`src/neel.nim` (`releaseSharedState` as the hook).

Tests: `tests/t_pool.nim` (hook runs after the drain with no worker exited;
workers joined even if the hook raises; no hook after a completed stop),
`tests/t_server.nim` suite "server: shutdown ordering" (hook runs after
every `onClose` with the IO thread and workers alive; hook before `listen`
and after a stop; 50 create/shutdown cycles with open connections and queued
work), `tests/t_neel.nim` (window teardown inside `runApp` happens before any
worker exits). The window and js integration tests now tear down through
`beforeJoin` like `runApp`. Exit-before-free is checked with
`onThreadDestruction`, so these tests are deterministic on every OS and
compiler; the crash itself is not reproducible on demand.

While adding them, the same bug showed up in test code (`t_pool`'s and
`t_server`'s shared state grown by workers and freed after the join; the new
ordering made `t_server` crash every run on 2.2.10). Fixed in those files.

### 2026-10-09 - Minimum Nim raised to 2.2.12

Evidence, all on Windows: `tests/t_protocol.nim` built with 2.2.10 crashed on
8 of 8 runs ("ids are unique under concurrent allocation from several
threads": helper threads grow `sh.ids`, freed after `joinThreads`); built
with 2.2.12, 0 of 8. `tests/t_server.nim` "send from a non-IO thread arrives"
built with 2.2.10 crashed about 1 run in 30 (access violation on the IO
thread: a short-lived thread's `send` grows the connection's outbound buffer
and the `dirty` list, then exits before the IO thread frees them). Neel
cannot prevent the second case for user threads on <= 2.2.10, so the
minimum is now 2.2.12 (`neel.nimble`, README, `PLAN.md`, project rule, and a
compile-time check in `src/neel.nim`). The same test-side pattern remains in
`t_protocol`, `t_jsproxy`, `t_window`, and `t_neel` helper threads; it is
harmless on 2.2.12 and left as is.

### 2026-10-09 - Flaky `t_neel`: "wrong" token was sometimes right

The wrong-token check replaced the first character with `0`; one launch token
in 16 already starts with `0`, so the upgrade was (correctly) accepted.
Fixed by picking a character that differs.

### 2026-10-09 - Windows: no Chrome output in the terminal (not a bug)

On macOS the terminal shows Chromium's stderr noise; on Windows it shows only
the app's output. Same launch on both (`poParentStreams, poDaemon` in
`src/neel/browser.nim`); `chrome.exe` is a GUI-subsystem binary that does not
log to the console unless `--enable-logging` is passed. README updated.

### 2026-10-09 - Windows: roundtrip in `@[Default]` mode (not a bug)

`askSecond` returns `PromptCancelled` without any click: the second page is a
background tab, where Chromium suppresses `prompt()` and returns `null`.
`closeSecond` leaves the tab open (dead): a default-browser tab has no process
handle, so Neel can only disconnect it. Both apply on every OS. README caveat
added.

## Open items

- stresstest's manual check "a page refresh after a restart works again"
  needs the restarted app on the same port; with the default `port = 0` the
  old page's URL is dead. stresstest takes an optional port argument
  (`./stresstest 8765`) and the page text gives the recipe. Passed on macOS
  2026-10-12 and on Windows 2026-10-12 (the refreshed old page displaces
  the window the restart opened, as documented).
- Linux: not run yet. Run the full matrix, including the stale-tab recipe
  and both stresstest manual checks.
- Edge: verified on Windows only (2026-10-12). macOS and Linux will not be
  run; their paths and flags are checked against public sources only (see
  the 2026-10-12 findings).
- Abandoned profile dirs: a killed or crashed app or browser leaves its
  `neel-<pid>-<id>` dir in the temp dir, and Windows never cleans `%TEMP%`
  (16-120 MB each). Planned: an automatic sweep that never slows startup
  (at shutdown, or on a background thread), in its own session.
- A page that navigates away from its launch URL (dropping `?window=<id>`)
  still relies on the single-window fallback for `/neel.js`; with more than
  one window open it gets a 404. Settled behaviour (README "Windows"), noted
  here because the fallback is now narrower than before.
