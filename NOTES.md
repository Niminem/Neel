# Neel 2.0 hardening notes

Tasks 1-15 in `PLAN.md` are implemented. This file is the working log of the
phase after that: running `nimble test` and every example on macOS, Windows,
and Linux, trying to break things, and fixing what breaks. `neel2-devel`
merges into `master` once macOS and Windows pass everything below; the
Linux column is filled in 2.1 (`PLAN.md` "Post-implementation changes",
release scope).

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
| `nimble test` | passes (Nim 2.2.12, 2026-10-12, with the profile sweep, the public-surface change, and the request guard) | passes (Nim 2.2.12, 2026-10-12, with the profile sweep, the public-surface change, and the request guard) | not run |
| profile sweep manual check (see "Open items") | passes (Nim 2.2.12, 2026-10-12; release roundtrip, normal exit and `kill -9` + Cmd+Q; no `neel-*` dir left in `$TMPDIR`) | passes (Nim 2.2.12, 2026-10-12; release roundtrip with Chrome and with `@[Edge]`, normal exit and Task Manager kill; no `neel-*` dir left in `%TEMP%`) | not run |
| `examples/filepicker` | passes (Nim 2.2.12, 2026-10-12; debug and release, app and `@[Default]`; rerun with the request guard, app and `@[Default]` with Safari as the default browser) | passes (Nim 2.2.12, 2026-10-12; debug and release, app and `@[Default]`; rerun with the request guard) | not run |
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

### Every request must look like it came from a Neel page

`requestRefusal` (`src/neel/frontend.nim`) runs before routing: `Host`
`127.0.0.1:<port>`, no `Sec-Fetch-Site: cross-site`, and `Origin`
`http://127.0.0.1:<port>` on `/ws`. Never add a route in front of it, never
serve pages at another host (`localhost`, `[::1]`) without widening it on
purpose, and keep the launch URL built from `LoopbackHost`. A raw client in a
test must send the real `Host` (with the port) and, for `/ws`, the
`Origin`.

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

### Profile dirs: only `<tmp>/neel-<pid>-<id>`, deleted only when owner and browser are dead

Window profiles live only at `userDataDirFor(id)` =
`<tmp>/neel-<pid>-<windowId>`; the exit sweep deletes nothing else. It
deletes such a dir only when its name parses strictly, the pid is not ours,
the owning app is not running, and no browser holds the profile. Keep it
that way: never widen the name match, never delete on a failed or
uncertain check (unknown counts as alive), never pass a parsed pid to
`kill` without the positive-decimal check, and never follow a symlink out
of the temp dir. Anything that changes where profiles live must change
`userDataDirFor`, `parseUserDataDirName`, and the sweep together.

### Docs live in two files; the guide is the master

`docs/GUIDE.md` holds every detail; `README.md` is the introduction and
links into the guide by section anchor. A behaviour or API change updates
the guide first, then the README wherever it summarises the same thing
(features, the walk-through, the `startApp` table, "Before You Start", the
renames). Renaming a guide heading breaks the README's anchor links, so
check them after any heading change. Code shown in the README must compile
against the current API.

## Findings

### 2026-10-12 - All platforms: docs split into README and guide (docs only)

The 880-line README moved, content unchanged, to `docs/GUIDE.md`, which is
now the master reference: retitled "Neel 2.0 guide", a link back to the
README added, and the `examples/` and `LICENSE` links made relative to
`docs/` (section anchors and the Contents list are unchanged). The new
README follows the v1.1.0 structure and tone: pitch, features, requirements
and platforms (macOS and Windows verified, Linux in 2.1, Edge on Windows
only), installation, a numbered walk-through of `examples/filepicker`, the
`neel.js` basics, multiple windows, compilation (the `--app:gui` paragraph
copied verbatim), "Before You Start", examples, the main 1.x renames, and
future work (Linux verification, Brave / Opera / Vivaldi, Webview, `wss:`).
Each README section links to the guide section that has the details. Left
to the guide only: the full type list, error messages, reconnect timings,
the wire format, browser search paths and Edge flags, profile-dir sweeping,
threading internals and worker sizing, the `quitApp()` reply caveat, the
stale-tab and fixed-port refresh details, and the serving rules. Every
README claim was checked against `src/`; no disagreement was found. The
README's Nim snippets (the walk-through in debug and release, the `js`,
escape-hatch, multi-window, and `startApp` snippets) compile with Nim
2.2.12 in a throwaway project outside the repo. References to README
sections whose content moved now point at the guide (comments in
`tests/t_jsproxy.nim` and `tests/t_neel.nim`, and the entries below). No
code change, no test.

### 2026-10-12 - All platforms: second README audit (docs only)

README rechecked section by section against `src/`. Corrected: procs
exposed after `startApp` are registered but left out of the dispatcher and
`/neel.js`; `onWindowClose` also fires when a window never connects within
`startupTimeoutMs`; hooks use `w.js` (the global `js` has no current window
there); `stresstest` keeps a 3 s grace period in release; the `quitApp()`
caveat no longer promises the reply beats the 1001 close (see "Open
items"); the launch-token caveat now separates ephemeral and fixed ports
(with a fixed port a refreshed old page displaces the new run's window).
Added: a Defect in an exposed proc terminates the app (`pool.nim` catches
only `CatchableError`); `js.wait` replies are handled on the pool, so
`workers` simultaneous `js.wait`s starve their own replies and time out;
in-window navigation drops `?window=`; `onWindowOpen` can fire before the
page has registered its `neel.expose` functions; `openWindow` /
`closeWindow` / `quitApp` assert outside a running `startApp`; a License
section. The `--app:gui` paragraph was left as is (confirmed by hand on
macOS). No code change, no test.

### 2026-10-12 - All platforms: a missing web directory failed silently in debug builds

Symptom (README audit): with `embedAssets = false` and a `webDir` that does
not exist, `startApp` opened a window that showed only 404s. Embedding
already failed at compile time. Fix: `runApp` (`src/neel.nim`) raises
`OSError` (`neel: web directory not found: <root>`) before `findBrowser`, so
nothing is bound, launched, or swept. A runtime check rather than a
compile-time one, because a disk-mode `webDir` may be a non-constant string
and the directory can move after the build. `diskAssets` still accepts a
missing directory (`t_assets` relies on that). Test: `tests/t_neel.nim` "a
missing web directory fails before anything starts" (the message names the
directory; no launch, no sweep).

### 2026-10-12 - All platforms: other websites could drive a Neel app

Symptom (README audit, by reading the code; not reproduced): nothing
checked `Host`, `Origin`, or `Sec-Fetch-Site`. Browsers trim a cross-origin
`Referer` to the origin, so with one window open a `/neel.js` request from
another site named no window and got that window's shim, token included. A
page in the user's browser that found the port could replace
`window.WebSocket`, load the shim with a `<script>` tag, read the token from
the URL the shim opened, and connect to `/ws` itself (WebSockets ignore
CORS); `bindConnection` then displaced the real page and the site could
call every exposed proc. DNS rebinding was a second route.

Fix: `requestRefusal(req, port)` in `src/neel/frontend.nim`, called first
in `handleRequest` (`src/neel.nim`); a refusal is a 403 with a plain-text
reason. `Host` must be `127.0.0.1:<port>` (bare `127.0.0.1` on port 80,
where browsers omit the default port; `localhost` is refused),
`Sec-Fetch-Site: cross-site` is refused (a missing header passes, for
older browsers), and a `/ws` request needs `Origin`
`http://127.0.0.1:<port>` (none is refused: browsers always send it on a
WebSocket handshake). The launch URL is built from the new
`frontend.LoopbackHost`. README "Security" section added (now in
`docs/GUIDE.md`; the README keeps a two-sentence summary).

Tests: `tests/t_frontend.nim` suite "frontend: requestRefusal" (own
requests pass, header names case-insensitive; wrong, missing, `localhost`,
port-less, IPv6, and suffix-spoofed `Host`; port 80; cross-site on every
route; missing, `null`, foreign, wrong-port, `https`, `localhost`, and
trailing-slash `Origin` on `/ws`). `tests/t_neel.nim` sends the real
`Host` and `Origin` from its client and checks, against the running app,
403 for a foreign `Host` and for `Sec-Fetch-Site: cross-site` on `/`,
`/neel.js`, and the no-browser page (no token in the body), 403 for `/ws`
upgrades with a foreign `Host`, a foreign or wrong-port `Origin`, none,
or a cross-site fetch, and that `same-origin` / `none` still pass. Both
pass on Windows (Nim 2.2.12). Real browsers pass the checks: the examples
on Windows, and `filepicker` in app mode and in a Safari tab (`@[Default]`)
on macOS. `nimble test` passes on both (same day). Linux not run yet.

### 2026-10-12 - All platforms: test seams and internals removed from the public surface

Symptom (README audit): `startApp` took `launcher` and `profileSweep`, two
parameters that exist only so `tests/t_neel.nim` can run without a
browser, and `neel` exported symbols no application uses (`runApp`,
`Launcher`, `ProfileSweep`, `LaunchOptions`, `AssetSource`,
`NeelProtocolError`, `NeelFrameError`, `initJsProxy`, `CurrentWindow`,
`UseDefaultTimeout`, `NeelJsPath`).

Fix: the hooks moved to `src/neel/testhooks.nim` (`setTestLauncher`,
`setTestProfileSweep`; not re-exported), which `runApp` reads once at
start. `runApp` is private; `startApp` reaches it through `bindSym`.
`NeelJsPath` moved to `src/neel/frontend.nim`. The other symbols are no
longer exported from `src/neel.nim` (still public in their own modules).
Runtime behaviour is unchanged, so the manual example runs do not need
repeating; `nimble test` covers it.

Tests: `tests/t_neel.nim` installs its fakes through `testhooks` and
clears them afterwards; the public-surface test now checks that `runApp`,
`Launcher`, `AssetSource`, `initJsProxy`, `CurrentWindow`, and
`UseDefaultTimeout` are not declared through `import neel`. `nimble test`
passes on Windows (Nim 2.2.12); all three examples compile, and one was run
by hand.

### 2026-10-12 - All platforms: `js.<name>` collisions pinned by tests

The README's list (now in `docs/GUIDE.md`) of names that reach the page
(`js.len()`, `js.add(...)`, `js.close()`, `js.open()`, `js.alert(...)`)
came from spike (b) on 2.2.10, before `neel` re-exported `std/json` and
`std/options`, and no test pinned it. A collision is silent: when a Nim proc
in scope accepts the proxy, Nim calls it and nothing reaches the page. No
library change. The "Name collisions" paragraph (README then,
`docs/GUIDE.md` now) says the misroute is silent and that an app's own
generic procs (`proc log[T](x: T)`) capture names the same way.

Tests: `tests/t_jsproxy.nim` "names of Nim procs that do not take the proxy
reach the page" (the sent `call` messages); `tests/t_neel.nim` "js.<name>
reaches the page unless a Nim proc accepts the proxy" (types through
`import neel`: `JsonNode` for those names and `win.js`, `void` / `string`
for `echo` / `repr`). `nimble test` passes on Windows. If a future Nim
changes one of these, drop the name from `docs/GUIDE.md`.

### 2026-10-12 - All platforms: README audit against the code

README checked section by section against `src/`. Corrected: `neel.onclose`
fires after every close, including each failed reconnect attempt (a lost
connection that never returns gives `(1006, true)` five times, then
`(1006, false)`), not once per connection, and the `null` code case cannot
happen (also fixed in the `neel.js` header comment); `maxMessageSize` limits
only messages from the page (`Server.send` has no size check); the example
commands must run from the repo root; a `browserPath` override gets the
`launchFlags` of the first app-mode entry in `browsers`, so an Edge
executable needs `browsers = @[Edge]`. Added: platform status, exposed
names keep their exact spelling in JS, `js.wait` collides with a JS function
named `wait`. Removed the `runApp` mention (not for applications). "Windows"
section renamed "Multiple windows". Docs only; no test. Follow-ups under
"Open items".

### 2026-10-12 - All platforms: abandoned profile dirs are swept at exit

Symptom (Windows): six stale `neel-<pid>-<id>` dirs, about 390 MB, in
`%TEMP%`. Every window's profile (16-120 MB) is deleted only by Neel when the
window closes; a killed or crashed app (Ctrl+C, Task Manager) or browser
leaves it behind, and Windows never cleans `%TEMP%` (macOS ages out
`$TMPDIR`; Linux varies).

Fix (`src/neel/browser.nim`, `src/neel.nim`, `src/neel/window.nim`):
- `sweepProfiles` runs last in `runApp`'s `finally`, after `shutdown`
  (windows torn down, browsers terminated, every thread joined), on the
  main thread. It lists the temp dir and deletes a dir only when its name
  parses strictly as `neel-<pid>-<windowId>` (plain positive decimals; no
  sign, `_`, or leading zero, so `kill` never sees 0 or -1), the pid is not
  ours, the owning app is not running, and no browser still holds the
  profile. Owner check: POSIX `kill(pid, 0)` (`EPERM` = alive), Windows
  `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` (`ERROR_ACCESS_DENIED` =
  alive) + `GetExitCodeProcess` (`STILL_ACTIVE` = alive). Browser check:
  POSIX `SingletonLock` -> `<host>-<pid>`, skip if that pid is alive or does
  not parse; Windows delete the profile's `lockfile` (Chromium holds it
  without delete sharing), skip if that fails. Only real dirs are listed
  (no symlinks or junctions). Budget `SweepBudgetMs` (2 s), checked before
  each dir; a deletion already running finishes, the rest waits for the
  next exit. Never raises.
- `clearStaleUserDataDir` in `openWindow` before each launch: a dir with our
  pid and this window id that we have not launched yet is left over from an
  earlier process with the same pid (or an earlier `startApp` in this
  process); it is deleted so the window gets a fresh profile. One
  `dirExists` when there is nothing to do; a failed delete (a browser still
  holds it) is ignored and the launch goes ahead.
- Probes are injectable (`ProfileProbes`: listing, `dirExists`, pid check,
  lock check, `removeDir`, clock; `systemProfileProbes()` is the real one),
  and `runApp` / `startApp` take `profileSweep` (`nil` = `sweepProfiles()`)
  as a test seam like `launcher`.

Why at exit and not on a background thread at startup: nothing runs before
or during a launch, there is no thread to join and no cross-thread memory
to think about, and the `finally` also runs when `NeelBrowserError`
propagates. Cost: a killed run is cleaned up by the next clean exit of any
Neel app, not the next start. Normally there is nothing to delete and the
sweep takes milliseconds; it comes after the grace period, which
`quitApp()` skips.

Why the layout did not change (`<tmp>/neel/<pid>-<id>` was considered):
on Linux `/tmp` is shared between users, so a shared `neel` subfolder
would belong to whoever created it first (other users could not create
profiles in it) and could be pre-created as a symlink. The flat
`<tmp>/neel-<pid>-<id>` dirs are created by the browser, as before; other
users' dirs look alive (`EPERM`) or cannot be deleted (sticky `/tmp`), and
both are ignored. The browser's `--user-data-dir` is unchanged, so no
launch behaviour changed. A per-user cache dir (`std/appdirs`) was also
considered and rejected: nothing ever ages it out, and it would change the
path on every OS.

Accepted residual risks: a reused pid makes a dead owner look alive (the
dir waits for a later sweep); on POSIX the hostname in `SingletonLock` is
not compared; a new app that gets a dead owner's pid between the check and
the delete could lose its just-created profile (milliseconds, needs pid
reuse onto the same window id).

Tests: `tests/t_browser.nim` suite "browser: abandoned profile sweep" (strict
name parsing including signs, `_`, leading zeros, overflow, extra dashes;
`SingletonLock` target parsing; garbage names never probed; live owner
skipped before the lock is looked at; own pid never touched whatever the
probes say; dead owner with a held lock skipped; dead owner, free lock
deleted; the budget stops part-way and the next sweep continues; listing,
pid, lock, and removal failures never raise; incomplete probes are a usage
error; stale own-pid dir deleted, absent dir untouched, failed delete
ignored; real filesystem in a private temp dir with the pid of an exited
`nim --version`: only the free dead-owner dir goes, while the held one
(open `lockfile` on Windows, `SingletonLock` to our pid on POSIX), our own,
garbage names, an unrelated name, a plain file, and on POSIX a symlinked
dir and its target stay). `tests/t_window.nim` (a leftover dir for window 1
is gone when the launcher runs). `tests/t_neel.nim` (the sweep has not run
once window 1 is launched; it runs exactly once per `startApp`, with no
window open, every profile dir already removed, every worker exited, and
before `startApp` returns). `nimble test` passes on Windows (Nim 2.2.12);
`src/neel.nim` and `tests/t_browser.nim` compile with `--os:linux` and
`--os:macosx --compileOnly`. macOS (same day): `nimble test` passes,
which runs the POSIX branches (`kill`, `SingletonLock`) for real, and the
manual check passes. Linux not run yet.

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
(`docs/GUIDE.md` says to include `msImplicitSignin`). Paths checked against public
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
`gracePeriodMs` to minutes. README "Caveats" (now in `docs/GUIDE.md`)
updated (`b74d3d8`). No code change, no test.

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
log to the console unless `--enable-logging` is passed. README updated
(now `docs/GUIDE.md` "Running the examples").

### 2026-10-09 - Windows: roundtrip in `@[Default]` mode (not a bug)

`askSecond` returns `PromptCancelled` without any click: the second page is a
background tab, where Chromium suppresses `prompt()` and returns `null`.
`closeSecond` leaves the tab open (dead): a default-browser tab has no process
handle, so Neel can only disconnect it. Both apply on every OS. README caveat
added (now `docs/GUIDE.md` "Caveats").

## Open items

- Linux: not run yet; scheduled for 2.1 (not a 2.0 merge blocker). Run the
  full matrix, including the stale-tab recipe and both stresstest manual
  checks.
- Edge: verified on Windows only (2026-10-12). macOS and Linux will not be
  run; their paths and flags are checked against public sources only (see
  the 2026-10-12 findings).
- Abandoned profile dirs: swept at exit since 2026-10-12 (see the finding).
  Passed by hand on Windows (Chrome and Edge) and macOS, 2026-10-12. Still
  to check on Linux: run roundtrip in release, open and
  close the second window, close window 1 with its X, wait out the grace
  period, and confirm no `neel-*` dir is left in the temp dir
  (`ls -d "$TMPDIR"neel-*`); then `kill -9` the app, quit its orphaned
  browser with Cmd+Q (on macOS closing the window leaves Chrome running,
  and the sweep rightly skips a profile a live browser holds), run and quit
  again, and confirm the killed run's dir is gone. The POSIX `kill` /
  `SingletonLock` path runs for the first time there.
- Request guard (2026-10-12 finding): verified on Windows and macOS. On
  Linux, `filepicker` in app mode and `@[Default]` covers it; a refusal
  shows as a `neel: refused: ...` page or a shim stuck reconnecting.
- `quitApp()` from an exposed proc can lose that call's reply: shutdown's
  `teardownAll` (`src/neel/server.nim`) writes the 1001 frame straight to
  the socket and drops output still queued, so a reply queued after the IO
  thread's last pass never arrives and the page sees
  `NeelDisconnectedError`. Found by reading the code, not reproduced;
  `t_neel` does not check for the reply. `docs/GUIDE.md` "Caveats"
  documents it; a fix would
  flush pending outbound data before the 1001 in `teardownAll`.
- A page that navigates away from its launch URL (dropping `?window=<id>`)
  still relies on the single-window fallback for `/neel.js`; with more than
  one window open it gets a 404. Settled behaviour (`docs/GUIDE.md`
  "Multiple windows"; the README keeps a one-line summary), noted
  here because the fallback is now narrower than before.
