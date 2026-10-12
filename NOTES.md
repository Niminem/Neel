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
| `nimble test` | passes (Nim 2.2.12, 2026-10-12, with the stale-tab fix) | passed 2026-10-09 (Nim 2.2.12); re-run after the stale-tab fix | not run |
| `examples/filepicker` | passes (Nim 2.2.12, 2026-10-12; debug and release, app and `@[Default]`) | passes (Nim 2.2.12; debug and release, app and `@[Default]`) | not run |
| `examples/roundtrip` | passes (Nim 2.2.12, 2026-10-12; debug and release, app and `@[Default]`, stale-tab recipe from the 2026-10-12 finding) | passes (Nim 2.2.12; debug and release, app and `@[Default]`); re-run `@[Default]` after the stale-tab fix | not run |
| `examples/stresstest` | passes (Nim 2.2.12, 2026-10-12; debug and release, app and `@[Default]`, kill/reconnect check; refresh-after-restart check not yet done, see Open items) | passes (Nim 2.2.12; debug and release, app and `@[Default]`, kill/reconnect check) | not run |

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

## Findings

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
  old page's URL is dead. stresstest now takes an optional port argument
  (`./stresstest 8765`) and the page text gives the recipe. Not yet checked
  on any platform.
- Windows: re-run `nimble test`, roundtrip `@[Default]` (stale-tab recipe
  from the 2026-10-12 finding), roundtrip app mode, and the stresstest
  kill/reconnect check after the stale-tab fix (`bindConnection` now closes
  displaced connections; both reconnect paths go through it).
- Linux: not run yet.
- A page that navigates away from its launch URL (dropping `?window=<id>`)
  still relies on the single-window fallback for `/neel.js`; with more than
  one window open it gets a 404. Settled behaviour (README "Windows"), noted
  here because the fallback is now narrower than before.
