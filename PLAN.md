# Neel 2.0 Plan

Neel 2.0 is a ground-up rewrite of Neel. It replaces Mummy with an in-house
multi-threaded HTTP/WebSocket server, replaces the `exposeProcs` block macro with
an `{.expose.}` pragma, adds return values in both directions (promises on the
JS side, blocking waits with timeouts on the Nim side), adds a multi-window API,
and generalizes browser discovery behind an enum-driven spec table.

Each task below is intended to be completed in its own session. Tasks are
ordered by dependency. Verification across platforms and the release itself are
handled outside this plan.

## Working on this plan

- Project conventions live in `.cursor/rules/` (`neel-project.mdc` is always
  applied; the others are scoped to Nim, tests, and frontend files).
- One task per session. When a task is finished, add `**Status:** done` (or
  `partial` plus what is missing) under its heading and note any deviation in a
  line or two.
- Facts that later tasks depend on (spike results, final API shapes, gotchas)
  are recorded here, not only in chat.
- Placeholders in `src/neel/neel.js` substituted by `frontend.nim`:
  `__NEEL_TOKEN__`, `__NEEL_WINDOW_ID__`, `__NEEL_EXPOSED__`.

---

## Decisions (settled)

| Area | Decision |
|---|---|
| Compatibility | Clean break. No `exposeProcs`, `callJs`, or `callNim`. README rewritten. |
| Repository | Rewrite in place on `master`. 1.x is preserved by tag `v1.1.0`. |
| Nim / dependencies | Nim >= 2.2.0. Zero external dependencies (hand-rolled SHA-1). |
| Server | Own HTTP/1.1 + WebSocket server. Single IO thread on `std/selectors`, configurable worker pool. Binds `127.0.0.1` only. |
| Exposure | `{.expose.}` pragma on top-level procs. Emits an exported `<name>NeelSym` wrapper plus a `neelRegister` call. Compile-time registry of bound symbols; `startApp` generates the dispatch. |
| Protocol | Symmetric JSON messages `call` / `ret` / `err` with ids. No id = fire-and-forget. Structured errors. |
| JS API | `neel.<procName>(...)` generated at compile time, returns a Promise. `neel.<procName>.send(...)` for fire-and-forget. `neel.expose(fn)` / `neel.expose({name: fn})` registers Nim->JS targets (falls back to `window[name]`). |
| Nim API | `js.<fnName>(...)` via experimental dot operators. Fire-and-forget by default; `.wait(timeoutMs)` blocks and returns `JsonNode`; `win.js.<fnName>(...)` targets a specific window. |
| Windows | Full multi-window API: `openWindow`, `closeWindow`, `windows()`, `currentWindow()`, per-window `js`. |
| Browsers | `Browser` enum + per-browser spec table. Ordered preference list (`seq[Browser]`). `Default` = default-browser tab. `fallback: bool` (true -> open app in default-browser tab; false -> open default-browser tab showing a Neel error page listing the browsers searched). 2.0 ships `Chrome`, `Chromium`, `Default`. Dedicated `--user-data-dir`; size/position via launch flags. No shell string construction. |
| Lifecycle | Exit after the last connection closes plus a configurable grace period (connection-count based). Explicit `quit()`. Browser launched only after `listen` succeeds. |
| Security | Per-launch random token baked into `neel.js`, required on WebSocket upgrade. |
| Assets | `embedAssets: static bool = defined(release)`. `std/mimetypes` for MIME, `Range` support (media), real 404s. |
| Tests | Unit tests under `tests/`. No CI for now. |
| Examples / docs | Port FilePicker. Add a round-trip example (return values both ways, two windows). README rewrite. |

## Assumptions (veto in review)

- Default `port = 0` (ephemeral). The bound port is read after `listen` and used
  for the launch URL. A fixed port is still allowed.
- Default worker pool size: 64. Default call timeout: 10 s. Default grace
  period: 3 s in debug builds, 10 s in release builds.
- Exposed procs must be top-level. They may return any `toJson`-able type or
  nothing. Default parameter values are supported. Generic procs are not.
- `js` is a global proxy value exported by `neel`. If the dot-operator spike
  shows that `{.experimental: "dotOperators".}` must be enabled in the user's
  module, we document the one-line pragma.
- Wrapper naming: `<procName>NeelSym`. Predictable rather than `genSym`'d so
  `startApp` can reference it and tests can target it.
- Message framing is JSON text frames only. Binary frames are reserved.
- Module layout:
  - `src/neel.nim` - public surface (`startApp`, re-exports)
  - `src/neel/sha1.nim` - SHA-1 for the WebSocket handshake
  - `src/neel/http.nim` - HTTP/1.1 parsing and response writing
  - `src/neel/websocket.nim` - RFC 6455 framing
  - `src/neel/pool.nim` - bounded task queue + worker threads
  - `src/neel/server.nim` - selectors IO loop, connection state machine
  - `src/neel/protocol.nim` - call/ret/err messages, pending-call table
  - `src/neel/expose.nim` - `expose` pragma, registry, dispatch generation
  - `src/neel/js.nim` - `js` proxy, dot operators, `.wait`
  - `src/neel/frontend.nim` + `src/neel/neel.js` - browser-side shim
  - `src/neel/browser.nim` - `Browser` enum, spec table, discovery, launch
  - `src/neel/window.nim` - `Window` type, connection mapping, lifecycle
  - `src/neel/assets.nim` - disk and embedded asset serving
- The frontend shim is kept as a real `.js` file and `staticRead` at compile
  time with placeholders substituted (token, exposed names, window id).

---

## Protocol reference

All messages are JSON text frames and are identical in both directions.

```json
{"t":"call", "id":17, "name":"add", "args":[1, 2]}
{"t":"ret",  "id":17, "value":3}
{"t":"err",  "id":17, "error":{"kind":"ValueError", "msg":"..."}}
{"t":"call", "name":"logThis", "args":["hi"]}
```

- `call` with an `id` expects exactly one `ret` or `err` with the same `id`.
- `call` without an `id` is fire-and-forget. Errors are logged (debug) and
  dropped (release).
- `err.error.kind` is the Nim exception type name or the JS error name.
- Ids are allocated per side and per connection; they never collide because
  the sides are distinguishable by direction.

---

## Tasks

### Phase 0 - Foundations

#### Task 1: Reset and scaffold
- Delete 1.x `src/` contents.
- Write new `neel.nimble`: version `2.0.0`, `requires "nim >= 2.2.0"`, no
  other dependencies.
- Create module skeletons listed above, each with a doc header describing its
  responsibility.
- Create `tests/` with a runner so `nimble test` works (initially empty).
- Update `.gitignore` for build artifacts and `nimcache`.
- Deliverable: package compiles; `nimble test` runs.

#### Task 2: Compiler spikes
Confirm on the installed Nim (2.2.10) and record results in this file:
- (a) A `typed` macro receives an `nnkSym` for a proc defined in module A and
  that symbol, stored in a `{.compileTime.}` registry, can be spliced into a
  `case` statement generated by a macro in module B which does not directly
  import A.
- (b) Where `{.experimental: "dotOperators".}` must be enabled for
  `js.foo(...)` to work: only in the defining module or also in the user's.
- (c) `std/selectors` backend and file-descriptor limits on macOS, Windows, and
  Linux; whether `-d:FD_SETSIZE` or an alternative is required to support
  several browser windows.
- (d) Fallback for (a): a macro emitting `from "/abs/path/mod.nim" import sym`.
- Deliverable: a short "Spike results" section appended to this plan and any
  design adjustments reflected in the tasks below.

### Phase 1 - Server core

#### Task 3: SHA-1 and handshake key
- `neel/sha1.nim`: SHA-1 digest over a string/openArray.
- `Sec-WebSocket-Accept` computation (SHA-1 + `std/base64`).
- Tests against RFC 3174 vectors and the RFC 6455 example key.

#### Task 4: HTTP/1.1
- `neel/http.nim`: incremental request parser (request line, headers, skip
  body via `Content-Length` if present), response writer, keep-alive.
- Methods: `GET`, `HEAD`. Others return 405.
- `Range` support: single byte range, 206 and 416 responses, `Accept-Ranges`.
- MIME via `std/mimetypes` with `application/javascript` for `.js`/`.mjs`.
- Status handling: 400 malformed, 404 missing, 405 method.
- Tests: parsing (split reads, pipelining, malformed), response formatting,
  range arithmetic.

#### Task 5: WebSocket framing
- `neel/websocket.nim`: frame encode/decode, client-to-server masking
  enforcement, fragmentation reassembly, ping/pong, close handshake with
  status codes, configurable max message size.
- Tests: text/binary round-trips, fragmented messages, control frames
  interleaved with fragments, malformed frames, oversize rejection.

#### Task 6: Server and worker pool
- `neel/pool.nim`: bounded task queue, N worker threads
  (`std/typedthreads` + `std/locks`), graceful stop.
- `neel/server.nim`: single IO thread on `std/selectors`; per-connection state
  machine (HTTP -> upgrade -> WebSocket); per-connection locked outbound queue
  with writable-event draining; connection open/close callbacks; request
  handler and message handler hooks; clean shutdown that closes all sockets
  and joins threads; binds `127.0.0.1`, supports `port = 0` and reports the
  bound port.
- Integration test using a `std/net` client: HTTP request/response, upgrade,
  echo over WebSocket, shutdown.

### Phase 2 - Bridge

#### Task 7: Protocol
- `neel/protocol.nim`: message types, encode/decode with validation, id
  allocation, error shape.
- Pending-call table for Nim->JS waits: per-call `Lock`/`Cond` and result
  slot, deadlines, `NeelTimeoutError`, cleanup on connection close (all
  pending waiters on that connection fail with `NeelDisconnectedError`).
- Tests: encode/decode round-trips, malformed input, pending-table wake-up,
  timeout, disconnect behavior.

#### Task 8: `expose` pragma and dispatch
- `neel/expose.nim`: `expose` pragma macro.
  - Validates top-level placement and supported signatures; clear compile
    errors for nested procs, generics, and unsupported parameter forms.
  - Generates `<name>NeelSym*(args: seq[JsonNode]): JsonNode {.gcsafe.}`:
    arity check (honoring defaults), per-parameter `fromJson`, `toJson` on the
    return value (or `null` for void). Handles multi-name `IdentDefs`
    (`proc p(a, b: int)`).
  - Emits `neelRegister("name", <name>NeelSym)` (a `typed` macro) which stores
    the bound symbol in the compile-time registry.
- Dispatch generator consumed by `startApp`: builds the `case name` over
  registered symbols, routes exceptions into `err` messages, unknown names
  into a structured error.
- Tests: expansion snapshots, arity and type-mismatch errors, defaults, return
  values, cross-module registration (per spike results).

#### Task 9: `js` proxy
- `neel/js.nim`: `JsProxy` and dot operators.
  - `js.foo(args...)` sends a fire-and-forget `call` and returns a discardable
    handle.
  - `.wait(timeoutMs = default)` on the handle sends with an id, blocks via the
    pending table, and returns `JsonNode`. Generic `.wait[T]` convenience
    returning `fromJson(T)`.
  - Thread-local current window set by the dispatcher while an exposed proc
    runs; `js.foo` targets it. `win.js.foo` targets an explicit window.
  - Defined behavior when no window is connected (`NeelNoWindowError`).
- Tests: expansion, routing to the current vs explicit window, timeout.

#### Task 10: Frontend `neel.js`
- `src/neel/neel.js` + `neel/frontend.nim` (placeholder substitution at
  compile time).
  - Connects to `/ws` with the launch token and window id.
  - Promise map keyed by id; `ret` resolves, `err` rejects with an `Error`
    carrying the Nim exception kind and message.
  - Generated `neel.<name>` functions for every exposed proc, each with a
    `.send` variant.
  - `neel.expose(fn)` / `neel.expose({name: fn})` registry for Nim->JS
    targets; falls back to `window[name]`.
  - Handles incoming `call` from Nim: invokes the target, awaits if it returns
    a promise, replies `ret`/`err` when an id is present.
  - Reconnect policy for page refresh; queueing of calls made before the socket
    is open.
- Tests: exercised against the Task 6 server with a scripted WebSocket client
  where feasible; remaining behavior verified manually in a browser.

### Phase 3 - Windows and browsers

#### Task 11: Browser discovery and launch
- `neel/browser.nim`:
  - `Browser` enum (`Chrome`, `Chromium`, `Edge`, `Brave`, `Opera`, `Vivaldi`,
    `Default`) and `BrowserSpec` table (macOS bundle paths + `mdfind`
    fallback, Windows Program Files candidates + registry App Paths, Linux
    executable names via `findExe`, `supportsAppMode`). Only `Chrome`,
    `Chromium`, and `Default` are populated for 2.0; others are present in the
    enum and table with empty specs.
  - Discovery over an ordered preference list; optional explicit
    `browserPath` override.
  - Launch via `startProcess` with an args array (no shell): `--app=<url>`,
    `--user-data-dir=<dir>`, `--window-size`, `--window-position`,
    `--disable-http-cache`, user-provided extra flags.
  - Fallback modes: `fallback = true` opens the app in a default-browser tab;
    `fallback = false` opens a default-browser tab at a Neel-served error page
    listing the browsers searched.
  - Process handle retained for lifecycle use.
- Tests: spec-table consistency, preference-list resolution with injected
  discovery results, argument construction.

#### Task 12: Window management and lifecycle
- `neel/window.nim`:
  - `Window` type with id, browser process handle, and connection reference.
  - Connection <-> window mapping established on WebSocket upgrade from the
    window id sent by `neel.js`.
  - `openWindow(path = "/", size, position, browsers, ...)`, `closeWindow`,
    `windows()`, `currentWindow()`.
  - Window open/close event hooks.
  - Connection-count-based shutdown with configurable grace period; `quit()`
    for explicit exit; pending waiters fail cleanly on shutdown.
- Tests: mapping, grace-period timer with reconnect, `quit` behavior.

#### Task 13: `startApp` assembly
- `src/neel.nim`:
  - Public `startApp` signature (web directory, `embedAssets`, port, worker
    pool size, call timeout, grace period, browsers, fallback, size, position,
    extra browser flags).
  - `neel/assets.nim`: disk serving (debug default) and compile-time embedded
    serving (release default), path containment, 404s.
  - Routes: `/`, `/neel.js`, `/ws`, assets, Neel error page.
  - Token generation, dispatch wiring from Task 8, `js` wiring from Task 9,
    window/lifecycle wiring from Task 12.
  - Launch the first window only after `listen` succeeds.
  - Main thread blocks on app completion; all IO and work happens on Neel
    threads so `js.foo().wait` is safe from any user thread.
- End-to-end smoke test: start the server headlessly, connect a scripted
  client, call an exposed proc, receive a Nim->JS call, shut down.

### Phase 4 - Examples and documentation

#### Task 14: Examples
- Port FilePicker to 2.0: `{.expose.}`, awaited `neel.filePicker(...)`,
  `textContent` instead of `innerHTML`, handle empty directories and
  non-existent paths with structured errors.
- New round-trip example: a Nim proc that returns a value to JS, a JS function
  that returns a value to Nim via `.wait`, and a second window opened from the
  first.

#### Task 15: Documentation
- README rewrite: concepts, quick start, `expose`, `js`, `neel.js` API,
  windows, browsers and fallback, lifecycle, assets and build modes,
  threading model and worker pool guidance, migration notes from 1.x.
- Doc comments on all public symbols; `nim doc` builds cleanly.

---

## Dependency order

```
1 -> 2 -> {3, 4, 5} -> 6 -> 7 -> {8, 9, 10} -> 11 -> 12 -> 13 -> {14, 15}
```

## Spike results

_To be filled in by Task 2._
