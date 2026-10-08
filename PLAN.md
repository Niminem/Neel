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
| Repository | Rewrite on the `neel2-devel` branch (forked from `master` after the `init neel 2.0` reset); merged into `master` only once every task is implemented and verified on macOS, Windows, and Linux. 1.x is preserved by tag `v1.1.0`. |
| Nim / dependencies | Nim >= 2.2.0. Zero external dependencies (hand-rolled SHA-1). |
| Server | Own HTTP/1.1 + WebSocket server. Single IO thread on `std/selectors`, configurable worker pool. Binds `127.0.0.1` only. |
| Exposure | `{.expose.}` pragma on top-level procs. Emits an exported `<name>NeelSym` wrapper plus a `neelRegister` call. Compile-time registry of bound symbols; `startApp` generates the dispatch. |
| Protocol | Symmetric JSON messages `call` / `ret` / `err` with ids. No id = fire-and-forget. Structured errors. |
| JS API | `neel.<procName>(...)` generated at compile time, returns a Promise. `neel.<procName>.send(...)` for fire-and-forget. `neel.expose(fn)` / `neel.expose({name: fn})` registers Nim->JS targets (falls back to `window[name]`). |
| Nim API | `js.<fnName>(...)` via experimental dot operators. Fire-and-forget by default; `js.wait.<fnName>(...)` / `js.wait(timeoutMs).<fnName>(...)` blocks and returns `JsonNode`; `win.js.<fnName>(...)` targets a specific window. _(Revised by Task 2 spike (b) from `js.<fnName>(...).wait()`, which is not implementable; veto in review.)_ |
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
- `js` is a global proxy value exported by `neel`. Settled by Task 2: the
  `{.experimental: "dotOperators".}` pragma is needed only in `jsproxy.nim`; the
  user's module needs nothing.
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
  - `src/neel/jsproxy.nim` - `js` proxy, dot operators, `.wait` (renamed from
    `js.nim` in Task 9: a module named `js` shadows the `js` global)
  - `src/neel/frontend.nim` + `src/neel/neel.js` - browser-side shim
  - `src/neel/browser.nim` - `Browser` enum, spec table, discovery, launch
  - `src/neel/window.nim` - `Window` type, connection mapping, lifecycle
  - `src/neel/assets.nim` - disk and embedded asset serving
- The frontend shim is kept as a real `.js` file and `staticRead` at compile
  time; the placeholders (token, exposed names, window id) are substituted
  when `/neel.js` is served, since the token is per launch and the window id
  per window (settled by Task 10).

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
**Status:** done

Notes for later tasks:
- Skeletons are doc headers only (no types or procs). `src/neel.nim` carries
  just `NeelVersion* = "2.0.0"`; `src/neel/neel.js` is a comment-only stub
  that already names the three placeholders.
- `nimble test` is nimble's built-in task (the custom task from Task 1 was
  removed after Task 3): it compiles and runs every `tests/t*.nim` in path
  order, deletes each binary afterwards, and stops at the first failing file
  (`nimble test --continue` runs them all). Test files are named
  `tests/t_<module>.nim`. `tests/config.nims` adds `src/` to the path and sets
  `--hints:off --verbosity:0`, so tests `import neel` / `import neel/<mod>`
  directly and also work via `nim c -r tests/t_x.nim`.
- Gotcha: Nim 2.2 puts `nimcache` under `~/.cache/nim/`, so sandboxed tool
  runs must either run unsandboxed or pass `--nimcache:/tmp/...`.

- Delete 1.x `src/` contents.
- Write new `neel.nimble`: version `2.0.0`, `requires "nim >= 2.2.0"`, no
  other dependencies.
- Create module skeletons listed above, each with a doc header describing its
  responsibility.
- Create `tests/` with a runner so `nimble test` works (initially empty).
- Update `.gitignore` for build artifacts and `nimcache`.
- Deliverable: package compiles; `nimble test` runs.

#### Task 2: Compiler spikes
**Status:** done

Deviations: spike (b) found that `.wait()` chained on the call result cannot
be implemented as written (details in "Spike results"); Task 9 and the "Nim
API" decision row were revised to `js.wait.foo(...)`. Spike (c) led to a
Windows `passC` requirement and an optional POSIX fd-limit raise in Task 6.
Spike (a) added duplicate-name detection, lineInfo handling, and an ordering
rule to Task 8. No `src/` files were changed. All throwaway programs lived in
`/tmp/neelspike/` and are not part of the repo.

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
**Status:** done

Deviation: `Sha1Digest` is `distinct array[20, byte]` (not a plain alias) so
the hex `$` does not leak onto every `array[20, byte]`; `==` is provided.
Convert with `array[20, byte](d)` for raw bytes.

Notes for later tasks:
- Surface: `sha1(string | openArray[byte]): Sha1Digest`, `$` (40 lowercase
  hex), `webSocketAccept(key): string`, `WebSocketGuid*`. Hashing is a small
  internal streaming state (`update`/`finalize`); it is not exported.
- `webSocketAccept` uses the key as received. Task 4's header parser must trim
  the header value before calling it.
- Tests: RFC 3174 TEST1-4 (including the one-million-`a` and 640-byte
  ten-block cases), empty input, `'a'` x {55, 56, 63, 64, 65, 119, 120, 128}
  (reference values generated with `shasum -a 1`), and the RFC 6455 example
  key plus its intermediate digest.

- `neel/sha1.nim`: SHA-1 digest over a string/openArray.
- `Sec-WebSocket-Accept` computation (SHA-1 + `std/base64`).
- Tests against RFC 3174 vectors and the RFC 6455 example key.

#### Task 4: HTTP/1.1
**Status:** done

Deviations: two safety bounds not in the task text were added as module
constants: `MaxHeaderBlock = 16 KiB` (as specified) and `MaxRequestBody =
1 MiB` (a larger `Content-Length` is malformed, so a client cannot make the
server buffer an unbounded body before it can answer 405). `Transfer-Encoding`
on a request is malformed (Neel does not frame chunked bodies). Unrecognized
HTTP versions (e.g. `HTTP/2.0`) are malformed (400) rather than 505.

Notes for later tasks (Task 6 / Task 13):
- Parser: `var p: HttpParser` per connection;
  `p.parseRequest(buf): ParseResult` with `status` in `{psIncomplete,
  psComplete, psMalformed}`, `consumed` (bytes to drop on `psComplete`,
  includes any skipped body and leading empty lines), `error` (reason on
  `psMalformed`), `request: HttpRequest`. Between `psIncomplete` results the
  caller must only append to the buffer; the parser keeps its scan position
  and the already-parsed header block, so it never re-scans. On `psComplete`
  and `psMalformed` it resets itself; `reset(p)` exists for discarding a
  connection. Server loop: `while true: r = p.parseRequest(buf); case r.status
  of psComplete: handle; buf.delete(0 ..< r.consumed) of psIncomplete: break
  of psMalformed: send badRequest() with keepAlive = false and close`.
- `HttpRequest` fields: `httpMethod: HttpMethod` (`hmGet`, `hmHead`,
  `hmOther`), `rawMethod` (token as sent, e.g. `"POST"`), `target`, `path`
  (target before the first `?`, **not** percent-decoded; Task 13 decodes and
  does containment), `query`, `version` (`hv10`, `hv11`), `headers:
  seq[HttpHeader]` (`tuple[name, value: string]`, values trimmed of SP/HTAB),
  `contentLength`. Lookup: `getHeader(req, name)` (first match, `""` if
  absent, case-insensitive), `hasHeader`, `headerHasToken(req, name, token)`
  for comma lists (`Connection: keep-alive, Upgrade`), `keepAlive(req)`.
  Upgrade detection for Task 6: `req.headerHasToken("Connection", "Upgrade")`,
  `cmpIgnoreCase(req.getHeader("Upgrade"), "websocket") == 0`,
  `req.getHeader("Sec-WebSocket-Version") == "13"`, and
  `webSocketAccept(req.getHeader("Sec-WebSocket-Key"))` (already trimmed, as
  Task 3 requires).
- Response: `HttpResponse` (`status`, `headers`, `body`), `initResponse(status,
  body = "", contentType = "")`, `addHeader`, `setHeader`, `getHeader`,
  `hasHeader`, `encodeResponse(r, keepAlive, headOnly = false): string`.
  Always emits `HTTP/1.1`; appends `Content-Length: body.len` unless the
  response already has one or the status is 1xx/204/304, and `Connection:
  keep-alive|close` unless already present. For `HEAD` pass `headOnly =
  req.httpMethod == hmHead` (same headers, no body). For `101` build
  `initResponse(101)` with `Upgrade: websocket`, `Connection: Upgrade`,
  `Sec-WebSocket-Accept`; the encoder adds no `Content-Length` and respects
  the explicit `Connection` header. Helpers: `okResponse(body, contentType)`,
  `badRequest()`, `notFound()`, `methodNotAllowed()` (adds `Allow: GET,
  HEAD`), `partialContent(slice, contentType, range, totalLen)` (adds
  `Content-Range: bytes a-b/len` and `Accept-Ranges: bytes`; `slice` must
  already be cut to `range`), `rangeNotSatisfiable(totalLen)`
  (`Content-Range: bytes */len`). `okResponse` does **not** add
  `Accept-Ranges`; Task 13 should add it on 200 asset responses so browsers
  issue `Range` requests for media. `reasonPhrase(status)` is exported.
- Range: `parseRange(headerValue, totalLen): RangeResult` with `status` in
  `{rsIgnored, rsSatisfiable, rsUnsatisfiable}` and `range: ByteRange(first,
  last)` (inclusive; `len(range)` exported). `rsIgnored` means serve 200 with
  the whole body (covers absent, malformed, non-`bytes`, multi-range, and
  `a > b`). `bytes=-0` and `totalLen == 0` are unsatisfiable. Digit strings
  are parsed with saturation so absurd values clamp instead of overflowing.
- MIME: `contentTypeFor(path): string`, extension lookup (case-insensitive),
  `OctetStream` (`"application/octet-stream"`) for unknown or missing
  extensions. The `MimeDB` is a compile-time `const` so the lookup is `gcsafe`
  with no global. Overrides added on top of `std/mimetypes`: `.js`/`.mjs` ->
  `application/javascript` (stdlib has `text/javascript`), `.map` ->
  `application/json` (stdlib has no entry). Verified correct in the stdlib
  table: `.wasm` `application/wasm`, `.woff2` `font/woff2`, `.webp`
  `image/webp`, `.svg` `image/svg+xml`, `.json` `application/json`, `.html`
  `text/html`, `.png` `image/png`. No `charset` is appended.
- Gotchas: empty lines before a request line are skipped (RFC 7230 3.5), so a
  stray CRLF after a pipelined request does not break the next one. Bare LF
  line endings are malformed (a request using only `\n\n` never terminates and
  hits the 16 KiB bound). Obsolete header folding and whitespace before the
  colon are malformed. Absolute-form targets (`GET http://host/x`) are not
  normalized; `path` is returned as sent. Every proc in `http.nim` is inferred
  `gcsafe` (verified with a `{.gcsafe.}` caller).
- Tests (`tests/t_http.nim`, 51 cases): one-shot, byte-at-a-time, splits
  mid-header and inside the terminator, pipelining with and without bodies,
  HEAD/POST, every malformed category, 16 KiB boundary (exactly at the limit
  passes, one over fails, unterminated at the limit fails), keep-alive matrix,
  exact 200/404 framing, HEAD framing, 405/400/206/416 strings, 101 shape,
  range arithmetic including clamping and saturation, MIME table.

- `neel/http.nim`: incremental request parser (request line, headers, skip
  body via `Content-Length` if present), response writer, keep-alive.
- Methods: `GET`, `HEAD`. Others return 405.
- `Range` support: single byte range, 206 and 416 responses, `Accept-Ranges`.
- MIME via `std/mimetypes` with `application/javascript` for `.js`/`.mjs`.
- Status handling: 400 malformed, 404 missing, 405 method.
- Tests: parsing (split reads, pipelining, malformed), response formatting,
  range arithmetic.

#### Task 5: WebSocket framing
**Status:** done

Deviations: binary frames are decoded and reassembled like text (minus the
UTF-8 check) rather than rejected in this module; whether to accept them is a
protocol decision, so `server.nim`/`protocol.nim` must close with 1003 on
`mkBinary` (the module doc header says so). Malformed input raises
`NeelFrameError` (per the task) instead of returning a third status like
`http.nim`'s `psMalformed`; "need more data" is still a status. The decoder
has a role (`frServer` requires masking, `frClient` forbids it) so the Task
7/10 scripted clients can decode server frames with the same code. Encoder
misuse (fragmented control frame, control payload > 125, close code that must
not go on the wire, reason > 123 bytes or invalid UTF-8) also raises
`NeelFrameError`, with `closeCode = CloseInternalError` (1011).

Notes for later tasks (Task 6 drives the state machine; Tasks 7/10 need the
masked encoder for scripted clients):
- Decoder: `var d = initFrameDecoder(role = frServer, maxPayload =
  DefaultMaxMessageSize)` per connection (a zero-initialized `FrameDecoder`
  behaves the same); `d.decodeFrame(buf: openArray[char]): FrameResult` with
  `status` in `{fsIncomplete, fsComplete}`, `consumed`, and `frame: Frame`
  (`fin`, `opcode`, `masked`, `maskKey`, `payload: string`, already
  unmasked). Takes `openArray[char]` like `parseRequest`, so the server keeps
  one `string` receive buffer per connection across the HTTP -> WebSocket
  switch. Same loop as HTTP: `while true: r = d.decodeFrame(buf); case
  r.status of fsComplete: feed; buf.delete(0 ..< r.consumed) of fsIncomplete:
  break`, wrapped in `try ... except NeelFrameError as e: send
  encodeClose(e.closeCode) and close`. Between `fsIncomplete` results only
  append; the parsed header is kept so the payload is never rescanned. On
  `fsComplete` and after an error the decoder resets itself (`reset(d)`
  also exists). Header fields are validated as soon as their bytes arrive,
  and a declared length above `maxPayload` raises 1009 before any payload is
  buffered, so a `2^62`-byte declaration is rejected on the 10th byte.
- Assembler: `var a = initMessageAssembler(maxMessageSize =
  DefaultMaxMessageSize)` per connection; `a.feed(frame): AssembleResult`
  with `status` in `{asNone, asMessage, asControl}`, `message: Message`
  (`kind: mkText|mkBinary`, `payload: string`), `control: Frame`. Control
  frames come back as `asControl` even mid-message (ping -> send
  `encodePongFor(frame)`; pong -> ignore; close -> `decodeClose(frame)`,
  reply with `encodeCloseReply(info)` unless we already sent a close, then
  close the socket). Close payloads are validated inside `feed`, so a bad
  close frame raises there too. Text is validated as UTF-8 only once the
  message is complete (1007). `inProgress(a)` and `reset(a)` exist. Use the
  same limit for decoder and assembler; `DefaultMaxMessageSize` is 16 MiB.
- Encoder (all return the wire bytes as `string`): `encodeFrame(opcode,
  payload, fin = true)` and `encodeFrame(opcode, payload, maskKey: MaskKey,
  fin = true)`; wrappers `encodeText`, `encodeBinary`, `encodeContinuation`
  (each `(payload, fin = true)` and `(payload, maskKey, fin = true)`),
  `encodePing(payload = "")`, `encodePong(payload = "")`,
  `encodePongFor(ping: Frame)`, `encodeClose(code = CloseNormal, reason =
  "")`, `encodeCloseReply(info: CloseInfo)`, each with a `maskKey` overload.
  Server-to-client frames use the unmasked forms; a scripted client passes
  any 4-byte `MaskKey = array[4, byte]` (this module never generates keys;
  pick one with `std/random` or a constant in tests). Minimal length encoding
  always. `MaxFrameHeader = 14`, `MaxControlPayload = 125`.
- Close codes: `CloseNormal` 1000, `CloseGoingAway` 1001,
  `CloseProtocolError` 1002, `CloseUnsupportedData` 1003 (use for binary),
  `CloseNoStatus` 1005 (returned by `decodeClose` for an empty payload;
  `encodeClose(CloseNoStatus)` emits an empty payload), `CloseAbnormal`
  1006, `CloseInvalidPayload` 1007, `ClosePolicyViolation` 1008 (use for a
  bad launch token after upgrade if needed), `CloseMessageTooBig` 1009,
  `CloseMandatoryExtension` 1010, `CloseInternalError` 1011,
  `CloseTlsHandshake` 1015. `isValidCloseCode(code)` is the on-the-wire set
  {1000-1003, 1007-1011, 3000-4999}; `decodeClose` raises 1002 for anything
  else (including 1004/1005/1006/1015 and 1012-2999) and for a 1-byte
  payload, 1007 for a non-UTF-8 reason. `CloseInfo` is `(code, reason)`.
- Masking: `applyMask(var string, key)` in place, `xorMask(string, key):
  string` copy; both symmetric.
- Gotchas: `std/unicode.validateUtf8` rejects truncated sequences, stray
  continuation bytes, and 2-byte overlongs but accepts UTF-16 surrogates
  (`ED A0 80`), 3/4-byte overlongs, and code points above U+10FFFF; good
  enough for Neel (JSON parsing happens next) but not Autobahn-strict. A
  masked frame is 4 bytes longer than its unmasked twin, so tests computing
  offsets must account for the key. `Frame.payload` and `Message.payload`
  are `string` for both text and binary. Every proc is callable from a
  `{.gcsafe.}` proc (verified with a throwaway program).
- Tests (`tests/t_websocket.nim`, 49 cases): RFC 6455 section 5.7 examples,
  text/binary round-trips at 0/125/126/65535/65536, masked round-trip,
  byte-at-a-time and splits inside the 16-bit length, 64-bit length and
  mask key, three pipelined frames, three-fragment reassembly, ping/pong/
  close interleaved with fragments, UTF-8 split across fragments, every
  malformed category with its close code, oversize before payload and
  across fragments, close encode/decode/echo, encoder refusals.

- `neel/websocket.nim`: frame encode/decode, client-to-server masking
  enforcement, fragmentation reassembly, ping/pong, close handshake with
  status codes, configurable max message size.
- Tests: text/binary round-trips, fragmented messages, control frames
  interleaved with fragments, malformed frames, oversize rejection.

#### Task 6: Server and worker pool
**Status:** done

Deviations: tasks are `std/tasks.Task` values (built with `toTask f(args)`)
rather than closures; see the decision below. `Pool` and `Server` are `ref`s
to a one-field object wrapping a `ptr` to shared-allocated state (a custom
`=destroy` does not destroy sibling fields and fields are destroyed in
reverse declaration order on 2.2.10, so the destructor lives on the wrapper).
When the pool queue is full the IO thread does not drop or block: it parks
the task on the connection, stops reading it, and retries (10 ms tick) -
this was not in the task text. `onOpen`/`onClose` are WebSocket-level (not
per TCP connection). Hooks do not receive the `Server`; Task 13's hooks reach
it through their own module global.

Notes for later tasks:
- Task representation (decided): `std/tasks.Task`. `toTask f(a, b)` requires
  `f` to be a `{.gcsafe.}` non-closure proc and every argument to pass
  `isolate`; it copies the arguments into an `allocShared` block owned by the
  task, so moving a task across threads touches no closure environment and no
  shared `ref` refcount - the exact hazard with ORC's non-atomic RC. `ptr`,
  `int`, `distinct int`, `string`, `seq`, and plain objects of those (e.g.
  `HttpRequest`) all isolate; a `ref` argument does not compile unless the
  compiler can prove it unique. `Task` is move-only; a plain `proc` is still
  fine as a *hook* type because hooks are only ever called, never moved.
- Pool API (`neel/pool.nim`): `newPool(workers = DefaultWorkers (64),
  queueCapacity = DefaultQueueCapacity (1024)): Pool`;
  `submit(p, task: sink Task, timeoutMs = DefaultSubmitTimeoutMs (5000)):
  bool` blocks with back-pressure while the queue is full and returns
  `false` (destroying the task) on timeout or when the pool is stopping or
  stopped - no exception; `trySubmit(p, task: var Task): bool` never blocks
  and leaves the task with the caller on failure so it can be retried;
  `stop(p, drain = true)` (drain runs the queued tasks, `false` discards
  them, in-flight tasks always finish; idempotent; wakes idle workers;
  `doAssert`s if called from one of its own workers because it would join
  itself); `workerCount`, `capacity`, `queued`, `running`, `isStopped`.
  Dropping the last `Pool` reference performs `stop(drain = false)`.
  A task that raises a `CatchableError` is swallowed; the worker survives.
  Idle workers re-check the stop flag every second as a safety net.
- `waitTimeout*(cond: var Cond; lock: var Lock; timeoutMs): bool` is
  exported from `pool.nim`: the timed condition-variable wait `std/locks`
  lacks (`pthread_cond_timedwait` on POSIX via `CLOCK_REALTIME`,
  `SleepConditionVariableCS` on Windows). `false` = timed out; spurious
  wake-ups are possible, so loop on the predicate. Task 7's pending-call
  table should use it for its deadlines.
- Server API (`neel/server.nim`): `ConnId = distinct int` (unique for the
  server's lifetime, never reused like fds; `==`, `hash`, `$`).
  `newServer(onRequest = nil, onMessage = nil, onOpen = nil, onClose = nil,
  workers = 64, queueCapacity = 1024, maxMessageSize = DefaultMaxMessageSize,
  closeTimeoutMs = DefaultCloseTimeoutMs (2000)): Server`; `listen(s, port =
  0)` binds `127.0.0.1` only (hand-built `Sockaddr_in`, never a hostname),
  raises `OSError` on failure, starts the pool and the IO thread, and may be
  called once; `port(s): int` (bound port, 0 before `listen`); `running(s)`;
  `shutdown(s)` (idempotent; `ssNew` -> no-op). `send(s, conn, text): bool`
  queues one text frame from any thread, `false` if the connection is
  unknown, not upgraded, or closing. `close(s, conn, code = CloseNormal,
  reason = ""): bool` from any thread: on a WebSocket connection it sends
  the close frame and tears down after the peer's reply or `closeTimeoutMs`;
  on a plain HTTP connection it closes after the queued output is flushed;
  later `send`s are refused; raises `NeelFrameError` for a code that may not
  go on the wire. `isWebSocketUpgrade(req): bool` = GET + `Connection`
  lists `Upgrade` + `Upgrade` lists `websocket` (case-insensitive) +
  `Sec-WebSocket-Version: 13` + non-empty `Sec-WebSocket-Key`.
- Hooks (all `{.gcsafe.}`, all run on pool workers, never on the IO thread):
  `RequestHandler = proc(conn: ConnId; req: HttpRequest): RequestAction`
  returns `respond(response)` or `upgrade()`. For `respond` the server
  encodes with `keepAlive = req.keepAlive` and `headOnly = (method == HEAD)`
  and closes after the response when keep-alive is off; a raising handler
  yields a 500 (connection survives); a `nil` handler yields 404 for
  everything. For `upgrade()` the server validates `isWebSocketUpgrade`
  (else 400 + close), builds `initResponse(101)` with `Upgrade: websocket`,
  `Connection: Upgrade`, `Sec-WebSocket-Accept`, and switches the connection
  to frames once the IO thread applies it. Whether a request *may* upgrade
  (path `/ws`, token/window id in `req.query`) is entirely the handler's
  decision; call `isWebSocketUpgrade(req)` yourself first if you need to
  record state (e.g. the conn <-> window mapping) before saying `upgrade()`.
  `MessageHandler = proc(conn: ConnId; message: string)` gets complete text
  messages; `ConnectionHandler = proc(conn: ConnId)` for `onOpen` (queued
  when the 101 is applied) and `onClose`. Exceptions from message/open/close
  hooks are swallowed. `onClose` fires iff `onOpen` fired, exactly once, for
  any reason (peer close, protocol error, `close()`, `shutdown`). Plain HTTP
  connections never fire `onOpen`/`onClose`.
- Ordering and concurrency guarantees: every hook invocation is its own pool
  task. For one connection, tasks are *queued* in wire order (`onOpen`, then
  messages, then `onClose`) but may *run concurrently* and finish out of
  order; two messages on one connection can be handled on two workers at the
  same time and `onClose` may run while a message handler for that
  connection is still executing. This is deliberate: serializing per
  connection would deadlock Task 9's `js.wait` (an exposed proc blocking for
  a `ret` that arrives on the same connection). Echo tests therefore check
  sets, not sequences. `send` from several threads is safe; each call is one
  whole frame, so frames never interleave.
- IO thread behaviour: HTTP requests on one connection are handled one at a
  time (while a request is on a worker the connection is not read, so
  pipelined requests are answered in order; browsers do not pipeline
  anyway). `psMalformed` -> 400 with `Connection: close`, then close after
  flush. Frames: ping -> `encodePongFor`, pong -> ignored, close ->
  `encodeCloseReply` then close after flush (or immediate teardown if we had
  sent the close), `mkBinary` -> close 1003, `NeelFrameError` -> close with
  `e.closeCode` (1002/1007/1009). After the server sent a close frame,
  incoming data frames are ignored and pings are not answered. If the pool
  queue is full the task is parked on the connection and reading stops until
  it can be queued (TCP back-pressure; nothing is dropped or blocked);
  `onOpen`/`onClose` use a bounded 1 s `submit` instead. Deadlines
  (`closeTimeoutMs`) cover the flush-before-close and the wait for the
  peer's close reply; there is no idle timeout for HTTP keep-alive sockets.
  `shutdown` sets a flag and wakes the selector; the IO thread closes the
  listener, sends a best-effort `encodeClose(CloseGoingAway)` to every
  upgraded connection, tears every connection down (queueing their
  `onClose`), closes the selector; then `shutdown` joins the IO thread and
  `stop(drain = true)`s the pool, so every `onClose` has run when
  `shutdown` returns. `shutdown` must be called from outside the pool (not
  from a hook); Task 12/13's `quit()` must signal the main thread rather than
  call `shutdown` on a worker.
- Memory model: `Conn` objects are `ptr ConnObj` from `allocShared0`, owned
  by the IO thread and reachable from workers only through
  `byId: Table[ConnId, Conn]` under the server lock, which also guards each
  connection's `outbound` string, its `pending` action list, and the `dirty`
  list; the IO thread is woken with a `SelectEvent` (triggered at most once
  per batch because the kqueue backend's pipe write raises when full). The
  IO-only fields (parser, decoder, assembler, receive buffer, write buffer,
  selector interest) are never touched under the lock. Do not capture the
  `Server` ref inside a hook closure that the server stores: that creates a
  cycle through the untraced `ptr` impl and the handle (not the threads or
  sockets) leaks after `shutdown`; use a module global (`{.cast(gcsafe).}`,
  write-once at init) or a `ptr` as the tests do.
- For Task 7 (protocol): run the pending-call table cleanup in `onClose`
  (fail every waiter on that `ConnId` with `NeelDisconnectedError`); because
  `onClose` can overlap a still-running message handler, the table must
  tolerate a `ret` arriving for an already-cancelled id and a late `send`
  (which simply returns `false`). `ret`/`err` messages reach you through
  `onMessage` on a worker like everything else; if saturation experiments
  show that waking a waiter must not queue behind user calls, add an
  IO-thread pre-filter hook then (not needed so far: wake-ups are O(1) and
  the queue holds 1024 entries). Use `waitTimeout` for per-call deadlines.
- For Task 10 (scripted client against this server): `tests/t_server.nim`
  has the recipe - `newSocket(buffered = false)`, `connect("127.0.0.1",
  Port(srv.port))`, send the handshake text (`GET /ws HTTP/1.1`, `Host`,
  `Upgrade: websocket`, `Connection: Upgrade`, `Sec-WebSocket-Key`,
  `Sec-WebSocket-Version: 13`), read the status line and headers with
  `recvLine(timeout)`, then `initFrameDecoder(frClient)` over a growing
  buffer with masked `encodeText(payload, key)` frames. Gotcha:
  `net.recv(size, timeout)` on an unbuffered socket insists on reading
  `size` bytes (one at a time) and only returns early on EOF, so "read what
  is available" needs `nativesockets.selectRead([fd], timeout)` followed by
  one raw `recv(sock, addr buf[0], len)` (see `recvSome` in the test).
  Bound every read; the suite uses 3 s.
- For Task 12 (windows and lifecycle): count connections with
  `onOpen`/`onClose` (WebSocket only, exactly once each, HTTP sockets
  excluded, so the grace-period count is the number of live browser
  windows). Establish the conn <-> window mapping in the request handler
  from the window id in `req.query`, *before* returning `upgrade()`; the
  handler runs before the 101 is sent, so the mapping exists before the
  first message can arrive, whereas `onOpen` is queued before the first
  message task but may still be running when it starts. Known gap: if the
  handler returns `upgrade()` and the socket dies before the IO thread
  applies the 101, neither `onOpen` nor `onClose` fires and the mapping
  entry is stale - treat it like a window whose browser never connected.
  `closeWindow` should `close(conn, CloseGoingAway)` (or 1000) and the
  browser's reply, or the 2 s timeout, tears the socket down; `shutdown`
  already sends 1001 to every window.
- For Task 13 (routing and wiring): the handler sees `req.path` raw
  (percent-decode and containment-check in `assets.nim`), `req.query`, and
  `req.httpMethod`; answer with `respond(okResponse(...))`,
  `respond(notFound())`, `respond(methodNotAllowed())` for non-GET/HEAD
  (the server does not 405 by itself; HEAD body stripping *is* automatic),
  `respond(partialContent(...))`/`rangeNotSatisfiable` for ranges. For `/ws`
  check `isWebSocketUpgrade(req)` and the launch token in `req.query`, then
  `upgrade()`; anything else gets 404/403. Hooks are plain module-level
  procs (or closures that do not capture the `Server`), and `startApp`
  keeps the `Server` in a module global; `listen` first, read `port`, then
  launch the browser. Default worker count and queue capacity come from
  `newServer`'s parameters (`DefaultWorkers`, `DefaultQueueCapacity`).
- Gotchas: `import std/posix` alongside `std/nativesockets` is ambiguous
  (`AF_INET`, `htons`, `send`...), so `server.nim` uses `from std/posix
  import RLimit, getrlimit, setrlimit, RLIMIT_NOFILE, TCP_NODELAY` and
  qualifies `nativesockets.AF_INET`; forward declarations of procs called
  from the `{.thread.}` loop need an explicit `{.gcsafe.}` or the thread
  proc fails the GC-safety check; `SelectEvent.trigger` raises
  `IOSelectorsException` when the kqueue pipe is full (catch it);
  `strutils.delete(s, slice)` is what the buffer loops use. `nim c` of any
  test from a sandboxed tool run needs `--nimcache:/tmp/...` (Task 1 note).
  Accepted sockets get `TCP_NODELAY` and, on macOS, `SO_NOSIGPIPE`; sends
  use `MSG_NOSIGNAL` where it exists. The POSIX fd-limit raise and the
  Windows `{.passC: "-DFD_SETSIZE=1024".}` from spike (c) are in place.
- Tests: `tests/t_pool.nim` (10 cases: completion on worker threads,
  isolated-argument copy, back-pressure with timed-out `submit` and
  `trySubmit`, drain, discard, double stop, submit after stop, raising task,
  destructor stop, `waitTimeout`) and `tests/t_server.nim` (26 cases: port
  0 and idempotent shutdown, HTTP request/response, pipelined keep-alive
  and `Connection: close`, 400 on garbage, 404/405/HEAD, 500 from a raising
  handler, RFC 6455 accept value, `upgrade()` on a non-upgrade request,
  echo, fragmented echo, 200 KB echo, ping/pong, 1003 on binary, 1002 on an
  unmasked frame, 1009 before an oversize payload, client close with and
  without code, server close with reply and with timeout, unknown ConnId,
  open/close exactly once (clean and abrupt), send from the test thread and
  from a new thread, three messages in one segment, pool saturation stall,
  shutdown with open connections). Every read is bounded by a 3 s timeout.

- `neel/pool.nim`: bounded task queue, N worker threads
  (`std/typedthreads` + `std/locks`), graceful stop.
- `neel/server.nim`: single IO thread on `std/selectors`; per-connection state
  machine (HTTP -> upgrade -> WebSocket); per-connection locked outbound queue
  with writable-event draining; connection open/close callbacks; request
  handler and message handler hooks; clean shutdown that closes all sockets
  and joins threads; binds `127.0.0.1`, supports `port = 0` and reports the
  bound port.
- File-descriptor limits (added by Task 2 spike (c)): in `server.nim`, emit
  `when defined(windows): {.passC: "-DFD_SETSIZE=1024".}` so the Windows
  `select` backend is not capped at 64 handles (`-d:FD_SETSIZE` has no
  effect; the C macro must be set). On POSIX, before `newSelector`, raise the
  `RLIMIT_NOFILE` soft limit to `min(hard, 4096)` if it is lower (macOS GUI
  default is 256); ignore failure. `maxDescriptors()` is read at
  `newSelector` time, so the raise must happen first.
- Integration test using a `std/net` client: HTTP request/response, upgrade,
  echo over WebSocket, shutdown.

### Phase 2 - Bridge

#### Task 7: Protocol
**Status:** done

Deviations: a wire `id` must be a *positive* integer (the task said
non-negative) because `0` is the `NoId` sentinel, so `"id":0` is malformed.
The id allocator is a standalone atomic `IdAllocator` value rather than a
counter inside the pending table: a monotonic per-connection counter must
outlive every wait on that connection, but the table only learns that a
connection is gone from `disconnect`, and a `register` racing `onClose`
would recreate (and leak) the record; keeping the counter with the owner of
the connection (Task 12's window record) lets table records vanish as soon
as they are empty. `decode` additionally rejects nesting deeper than
`MaxJsonDepth = 256` with a linear pre-scan (`std/json` parses recursively,
so a 16 MiB message of `[` would otherwise overflow the stack). The message
type is named `Msg` (not `Message`) to avoid clashing with
`websocket.Message` in modules that import both.

Notes for later tasks:
- Messages (`neel/protocol.nim`): `Msg` is an object variant on `kind:
  MsgKind` (`msgCall = "call"`, `msgRet = "ret"`, `msgErr = "err"`) with
  `id: int` (`NoId = 0` means absent; `hasId(m)`), `name` + `args:
  seq[JsonNode]` for `call`, `value: JsonNode` for `ret`, `error: ErrorInfo`
  (`kind`, `msg: string` object) for `err`; structural `==`. Constructors:
  `callMsg(name, args, id = NoId)`, `retMsg(id, value)` (`nil` -> `null`),
  `errMsg(id, ErrorInfo)`, `errMsg(id, kind, msg)`, `errMsg(id, e: ref
  CatchableError)`, `errorInfo(e): ErrorInfo` (`kind = $e.name`, `msg =
  e.msg`; a `NeelRemoteError` forwards its original remote `kind` instead
  of `"NeelRemoteError"`). `encode(m): string` is compact JSON with fields
  in reference order (`t`, `id` if any, then `name`/`args` | `value` |
  `error`): `{"t":"call","id":17,"name":"add","args":[1,2]}`. `decode(text):
  Msg` raises `NeelProtocolError` (with a reason) for anything else;
  `JsonParsingError`/`KeyError` never escape.
- Exceptions defined here: `NeelProtocolError`, `NeelTimeoutError`,
  `NeelDisconnectedError`, `NeelRemoteError` (`kind*: string` field; `msg`
  is the remote message verbatim). All `object of CatchableError`.
- `IdAllocator`: zero-initialised object, `nextId(a: var IdAllocator): int`
  returns 1, 2, 3, ... via atomic fetch-add; any number of threads may call
  it for the same connection. Keep one per connection and drop it with the
  connection (never reset it while the connection lives: a repeated id could
  match a late `ret` from a timed-out call).
- Pending table: `newPendingTable(): PendingTable` (a `ref` to a one-field
  wrapper around an `allocShared0` impl, same pattern as `Pool`/`Server`;
  one `Lock` guards the table and every entry's state, each entry has its
  own `Cond`; two-level `Table[ConnId, Table[int, ptr Entry]]` so
  `disconnect` is O(entries on that connection); a connection record exists
  exactly while it has entries). Procs, all `{.gcsafe.}`, any thread:
  - `register(t, conn, id)`: O(1); call before `send`. Re-registering a
    pending `(conn, id)` is a `doAssert`.
  - `wait(t, conn, id, timeoutMs): JsonNode`: blocks on the entry's `Cond`
    with `pool.waitTimeout` in a predicate loop until the deadline;
    `timeoutMs <= 0` polls once. Exception map: `ret` -> returns `value`;
    `err` -> `NeelRemoteError(kind, msg)`; connection closed (before or
    during the wait) -> `NeelDisconnectedError`; deadline ->
    `NeelTimeoutError`. The entry is removed and freed on every exit path.
    Waiting on an unregistered id is a `doAssert`.
  - `complete(t, conn, id, reply: Msg): bool`: deep-copies `reply.value`
    into the entry on the calling thread and signals; `false` (never
    raises) when the id is unknown, cancelled, timed out, already answered,
    or on another connection. `reply.kind` must be `msgRet`/`msgErr`.
  - `disconnect(t, conn): int`: marks every waiting entry on `conn`
    disconnected and signals each; returns the count; unknown conn -> 0.
  - `cancel(t, conn, id): bool`: for the registering thread when `send`
    fails after `register`.
  - `pendingCount(t)` / `pendingCount(t, conn)` for tests and diagnostics.
  Ownership rule: entries are created and freed only by the waiter's thread
  (`register`/`wait`/`cancel`); `complete`/`disconnect` only mutate state
  under the lock. So a reply landing between the deadline expiring and the
  waiter re-taking the lock still wins (state is re-checked), and a reply
  after the waiter left is a harmless `false`. Verified with a 300-round
  race test where both outcomes occur.
- For Task 8 (dispatcher): on an incoming `call` with `hasId`, run the
  wrapper inside `try`: success -> `encode(retMsg(m.id, result))` (a `nil`
  JsonNode from a void proc encodes as `null`); `except CatchableError as
  e` -> `encode(errMsg(m.id, e))` (gives `kind = $e.name`, e.g.
  `"ValueError"`; a `NeelRemoteError` from a nested `js.wait` keeps the JS
  kind); unknown name -> `errMsg(m.id, "NeelUnknownProcError", "no exposed
  proc named ...")` or similar structured kind. Without an id: run, log the
  exception in debug builds, send nothing. A `NeelProtocolError` from
  `decode` of an incoming message is a peer bug: log and drop (or `close`
  with 1008); do not reply because there is no trustworthy id.
- For Task 9 (`jsSend` / `jsCallWait`): fire-and-forget is
  `server.send(conn, encode(callMsg(name, args)))` with no table
  involvement. Blocking is `let id = alloc.nextId(); tbl.register(conn,
  id); if not srv.send(conn, encode(callMsg(name, args, id))): discard
  tbl.cancel(conn, id); raise NeelDisconnectedError; return tbl.wait(conn,
  id, timeoutMs)`. `register` must precede `send` (a reply can arrive
  before `send` returns). Default `timeoutMs` is the configured call
  timeout (10 s). `NeelNoWindowError` belongs to Task 9, not here.
- For Task 10 (`neel.js` wire contract): emit exactly `{"t":"call","id":N,
  "name":"f","args":[...]}` (omit `id` entirely for `.send`; never emit
  `id: null` or `id: 0`), `{"t":"ret","id":N,"value":V}` (`V` may be `null`;
  the key must be present, so use `value: result === undefined ? null :
  result`), `{"t":"err","id":N,"error":{"kind":"TypeError","msg":"..."}}`
  (`kind` = `e.name` or `"Error"`, `msg` = `String(e.message ?? e)`; both
  must be strings). Accept from Nim the same three shapes; `args` is
  always an array; `id` is always a positive integer; extra fields may be
  ignored. Malformed = anything `decode` rejects: non-object root,
  missing/unknown `t`, `id` that is a string/float/negative/zero/null,
  `call` without string `name` or array `args`, `ret` without `id` or
  without the `value` key, `err` without `id` or whose `error` is not an
  object with string `kind` and `msg`. Nesting deeper than 256 levels is
  rejected too. A JSON reply from Nim is compact and keys are in the order
  above (do not rely on it).
- For Task 13 (wiring): keep one `PendingTable` in a module global next to
  the `Server`. `onMessage(conn, text)`: `decode` (catch
  `NeelProtocolError`), then `case m.kind of msgCall: dispatch (Task 8) of
  msgRet, msgErr: discard tbl.complete(conn, m.id, m)` - the `false` for a
  late reply after `onClose` is expected and needs no log. `onClose(conn)`:
  `discard tbl.disconnect(conn)` (plus the window-mapping cleanup from Task
  12). Because `onClose` may overlap a running message handler, a handler
  that calls `js.wait` after `disconnect` ran will simply see `send` return
  `false` and raise `NeelDisconnectedError` via the Task 9 recipe. On
  `shutdown`, every `onClose` runs before `shutdown` returns, so every
  waiter has been failed by then; destroy the table after `shutdown`.
- Gotchas: `%*` in tests needs `nil` (not `null`) for a JSON null.
  `std/json` parses big integers beyond `int64` as raw-number strings, so
  `decode` rejects them as non-integers. `Atomic[int]` is fine inside a
  plain object reached via `ptr`; `copy(JsonNode)` is a deep copy and the
  Nim 2 allocator is shared, so a tree built on one thread may be freed on
  another once ownership has moved. Thread start-up on macOS is > 1 ms, so
  a race test needs a pre-started, spinning thread to land inside a
  millisecond deadline.
- Tests (`tests/t_protocol.nim`, 34 cases): reference examples, compact
  encoding and field order, round-trips for all three kinds with and
  without id, mixed-type args, `value: null`, unicode, ignored extras,
  exception helper (including the `NeelRemoteError` forward), every
  malformed category, depth limit; allocator start/monotonic and 8 threads
  x 2000 unique ids; pending table: cross-thread ret, early reply, deep
  copy isolation, err -> `NeelRemoteError`, bounded timeout and cleanup,
  `timeoutMs = 0`, unknown/answered/wrong-conn `complete`, `cancel`,
  `disconnect` of two waiters leaving a third connection untouched,
  disconnect between register and wait, disconnect from another thread,
  six concurrent waiters each getting their own ret/err, 300-round
  complete-vs-timeout race with the `completed == gotValue` invariant,
  destructor freeing never-waited entries. Every wait is bounded (3 s max).

- `neel/protocol.nim`: message types, encode/decode with validation, id
  allocation, error shape.
- Pending-call table for Nim->JS waits: per-call `Lock`/`Cond` and result
  slot, deadlines, `NeelTimeoutError`, cleanup on connection close (all
  pending waiters on that connection fail with `NeelDisconnectedError`).
- Tests: encode/decode round-trips, malformed input, pending-table wake-up,
  timeout, disconnect behavior.

#### Task 8: `expose` pragma and dispatch
**Status:** done

Deviations: conversions use `std/jsonutils` (`jsonTo` / `toJson`) as the
module header already said, not `std/json`'s `to` / `%`; see the type list
below. `expose.nim` re-exports `jsonutils.fromJsonHook` / `toJsonHook` (a
deliberate exception to the no-stdlib-re-export rule): `jsonutils` finds its
`Option` / `Table` / `HashSet` hooks by `mixin` lookup in the module that
instantiates the conversion, which is the user's module, so without the
re-export `Option[int]` silently converted as a two-field object. Shape
pre-checks were added in `convertArg` because `jsonutils` reads a non-array
as an empty `seq` and its `Table` / `HashSet` hooks `assert` (a Defect would
kill a worker). One `{.cast(gcsafe).}` is used
around `toJson`: the compiler cannot infer GC-safety for
`toJson[enum] -> toJson[string]` (recursive generic instantiation); the
module is global-free, and the comment says so. Nested-proc detection uses
`macros.owner` (deprecated, warning suppressed locally); the compiler's own
`'export' is only allowed at top level` appears first at the same line.
Duplicate names are detected in `generateDispatch` as specified (not at
`neelRegister`), so a test binary that exposes without dispatching compiles.

Notes for later tasks:
- Pragma: `{.expose.}` on a top-level `proc` or `func`. Expansion is
  `nnkStmtList(userProc, wrapper, neelRegister("<name>", <name>NeelSym))`.
  The user proc is emitted unchanged (the compiler strips the `expose`
  pragma itself). Wrapper: `proc <name>NeelSym*(args: seq[JsonNode]):
  JsonNode {.gcsafe.}` built with `newProc`; every generated node carries
  the user's proc-name lineInfo (`stamp`), so compiler diagnostics about the
  wrapper (e.g. `'fooNeelSym' is not GC-safe as it calls 'foo'`) point at
  the user's `proc` line. The wrapper's own parameter is `genSym`'d, all
  helpers are `bindSym`'d, so a user parameter named `args` or a module
  that does not import `std/json` both work. Body: `checkArity(name,
  args.len, minArgs, maxArgs)`; per required parameter `let p =
  convertArg(args, i, "proc", "p", T)`; per defaulted parameter `var p: T =
  default; if args.len > i: p = convertArg(..., typeof(p))` (a default may
  reference an earlier parameter); then `convertResult(f(a, b, c))` or, for
  void, `f(a, b, c); newJNull()`. `minArgs` = index of the last parameter
  without a default + 1 (positional semantics), `maxArgs` = parameter
  count. Multi-name `IdentDefs` are expanded per name.
- Supported types (everything `jsonutils` handles): `bool`, integers,
  floats (an integer JSON value is accepted for a float parameter),
  `string` (JSON `null` becomes `""`, `std/json` behaviour), enums
  (argument: name or ordinal; result: name via `joptEnumString`), `seq` /
  `array` / `set` (argument must be a JSON array), tuples, objects (extra
  keys ignored via `allowExtraKeys`, missing keys are an error), `ref T`
  (`null` <-> `nil`), `distinct`, `Option[T]` (`null` <-> `none`),
  `Table[string, V]` / `OrderedTable` (from an object), `HashSet` /
  `OrderedSet` (from an array), `JsonNode` (passed through; a `nil`
  `JsonNode` result is `null`). Rejected at compile time with a message at
  the parameter: `var`, `ptr` / `pointer`, `openArray`, `varargs`, `sink` /
  `lent`, proc types, `typedesc` / `static` / `auto` / `A | B`. Also
  rejected: non-proc targets (template, iterator, ...), nested procs,
  generic procs, operator names (the name becomes `neel.<name>`), forward
  declarations / bodiless procs, a second `expose`, `compileTime`,
  `varargs`, and `thread` pragmas. Overloads cannot share an exposed name
  (the wrapper would be redefined). Exposed procs must be GC-safe (they run
  on pool workers); a user `fromJsonHook` must raise a `CatchableError`,
  not `assert`.
- Registry: `var exposedRegistry {.compileTime.}: seq[ExposedProc]` with
  `ExposedProc = object(name: string, sym: NimNode, info: LineInfo)`;
  `neelRegister(name: static string; wrapper: typed)` appends (handles a
  sym choice by picking the symbol declared in the registering file, checks
  `nskProc`, the `proc(seq[JsonNode]): JsonNode` shape, and top-level
  placement). Accessors: `exposedProcs(): seq[ExposedProc] {.compileTime.}`
  (for other macros) and `macro exposedNames(): untyped`, which expands to
  a `seq[string]` literal in registration order (`newSeq[string]()` when
  empty) - this is the list for `__NEEL_EXPOSED__`. Registration order is
  semantic-check order: imported modules first, then the current module
  top to bottom.
- Dispatch: `generateDispatch(ident)` expands to `proc ident(name: string;
  args: seq[JsonNode]): JsonNode {.gcsafe.}` = `case name of "a": return
  aNeelSym(args) ... else: raiseUnknownProc(name)` with the stored
  `nnkSym`s spliced (works from a module that imports neither the exposing
  module nor its wrapper; non-exported wrappers resolve too). Empty
  registry -> body is just the raise. Duplicate names -> `error()` at the
  second proc: `exposed name 'dup' is used twice: first at a.nim(2, 6),
  again at b.nim(3, 6). Exposed names must be unique across all modules
  because they become neel.<name> in JS` (1-based columns like the
  compiler; never "duplicate case label"). `DispatchProc = proc(name:
  string; args: seq[JsonNode]): JsonNode {.gcsafe.}` (closure type; a named
  proc converts implicitly, a closure is accepted).
- Exceptions and wire kinds (`kind = $e.name` via `errMsg(id, e)`):
  `NeelArgumentError` -> `"NeelArgumentError"` with `msg` one of
  `"<proc>: expected 2 arguments, got 1"`, `"<proc>: expected 1 argument,
  got 0"`, `"<proc>: expected 1 to 3 arguments, got 4"`, `"<proc>: argument
  '<p>' expects <Type>, got <kind>"` where `<kind>` is one of `null`,
  `boolean`, `integer`, `float`, `string`, `array`, `object`, optionally
  followed by `": <detail>"` when the reason is more than the kind (e.g.
  `key 'y' for Point not in { "x": 1 }`, `Invalid enum value: purple`);
  `NeelUnknownProcError` -> `"NeelUnknownProcError"`, `msg = "no exposed
  proc named '<name>'"`. Any other `CatchableError` from the user proc
  gives its own type name (`"ValueError"`); a `NeelRemoteError` keeps its
  remote kind (`protocol.errorInfo`). Type labels drop the `system.`
  qualifier (`Option[int]`, `seq[int]`, `Table[string, int]`).
- Reply builder: `handleCall(m: Msg; dispatch: DispatchProc): Option[Msg]
  {.gcsafe.}`. `m.kind` must be `msgCall` (`doAssert`). With id:
  `some(retMsg(m.id, dispatch(m.name, m.args)))`, or `some(errMsg(m.id,
  e))` for a `CatchableError`. Without id: runs, discards the result,
  `none(Msg)`; a failure is written to stderr as `neel: fire-and-forget
  call '<name>' raised <kind>: <msg>` only when `not defined(release)`.
  Defects are not caught (they are bugs; the pool's behaviour applies).
- For Task 9 (`js` proxy): nothing here sets a current window. `handleCall`
  is a plain proc taking the dispatcher, so Task 13 brackets it: in
  `onMessage`, look up the window for `conn`, set the thread-local current
  window, call `handleCall(m, neelDispatch)`, clear the thread-local in a
  `finally` (or pass a closure `DispatchProc` that does the same around
  `neelDispatch`). Exposed procs run on pool workers, so the thread-local is
  per worker and must be set for every call, never cached.
- For Task 10 (`neel.js`): `__NEEL_EXPOSED__` = `exposedNames()` evaluated
  inside `startApp` (after the user's exposed procs, see the ordering rule).
  Error strings JS will see in `err.error`: `kind: "NeelArgumentError"` for
  arity and type problems, `kind: "NeelUnknownProcError"` for an unknown
  name (which can only happen with a hand-built message, since generated
  `neel.<name>` functions exist only for registered names), the Nim
  exception type name otherwise; `msg` formats as listed above. A
  fire-and-forget `.send` never gets a reply, even on failure.
- For Task 13 (`startApp`): emit `generateDispatch(neelDispatch)` from the
  `startApp` macro (a macro may emit a call to another macro; it expands
  right after, at the `startApp` call site, with the registry as of that
  point). Ordering rule: `startApp()` must come after every `{.expose.}`
  proc in the module and after the imports of modules containing exposed
  procs; it may be inside `proc main()`. A proc exposed later is simply
  not in the `case` (runtime `NeelUnknownProcError`). `onMessage(conn,
  text)`: `let m = decode(text)` (catch `NeelProtocolError`: log/drop or
  close 1008); `case m.kind of msgCall: let reply = handleCall(m,
  neelDispatch); if reply.isSome: discard srv.send(conn,
  encode(reply.get))` - `send` returning `false` (connection gone) needs no
  log; `of msgRet, msgErr: discard tbl.complete(conn, m.id, m)`.
  `handleCall` is `{.gcsafe.}` so it is callable directly from the
  `MessageHandler` hook. `src/neel.nim` should re-export `expose`
  (pragma), `NeelArgumentError`, `NeelUnknownProcError`; `neelRegister`,
  `generateDispatch`, `exposedNames`, `checkArity`, `convertArg`,
  `convertResult`, `raiseUnknownProc` are referenced by generated code via
  `bindSym` and need no re-export.
- Gotchas: fresh `NimNode`s created in a macro carry the lineInfo of the
  macro's *own* source line, not line 0, so "point at user code" needs an
  explicit recursive `copyLineInfo` over the generated tree. `macros.error`
  is not fatal: the compiler keeps going and reports later errors too (a
  failed `generateDispatch` is followed by "undeclared identifier" for the
  dispatcher name). A `compiles((block: <decl>; true))` wrapper works for
  negative macro tests but every declaration inside it is nested, so
  positive `compiles` checks are impossible and `nim check` subprocesses
  are needed for message/location assertions (`tests/t_expose.nim` has
  `nimCheck(dir, file)`: polling loop with `hasData` / `peekExitCode`,
  120 s deadline, `--path:<repo>/src`, `--nimcache` under the temp dir;
  about 2 s per invocation). `nim check` prints macOS temp paths as
  `/private/...`; compare file names, not full paths. `macros.LineInfo`
  columns are 0-based; the compiler prints 1-based.
- Tests (`tests/t_expose.nim`, 41 cases, plus `tests/fixtures/
  exposed_helper.nim` with an exported and a non-exported exposed proc):
  direct wrapper calls for every scalar kind, seq, object, enum (name and
  ordinal), `JsonNode`, `Option` (both directions), `Table`, `HashSet`,
  multi-name IdentDefs, defaults (1/2/3 args, default referencing an
  earlier parameter), void -> `JNull`, object result, `func`, parameter
  named `args`, propagated `ValueError`; exact arity messages (singular,
  plural, range), exact type-mismatch messages, detail for missing key /
  bad enum / wrong element; dispatch routing, unknown name, ordering rule
  (`earlyDispatch` vs `fullDispatch`), cross-module dispatch of exported
  and non-exported fixture procs, `exposedNames` order; `handleCall` ret,
  null ret, `ValueError`, forwarded `NeelRemoteError` kind,
  `NeelArgumentError`, `NeelUnknownProcError`, no-id success and failure,
  closure dispatcher; `compiles` negatives (generic, template, varargs)
  and `nim check` negatives with file/line assertions (nested, generic,
  template, duplicate across two modules naming both locations, GC-unsafe
  proc). The release build was also run once (no stderr log lines).

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
- Added by Task 2 spike (a):
  - Build the wrapper with `newProc` and `copyLineInfo(def)` (not `quote do`)
    so the registered symbol's `lineInfo` points at the user's `proc` line;
    store that `lineInfo` in the registry entry too.
  - The dispatch generator must detect duplicate exposed names (same name
    exposed in two modules) and `error()` with both locations; otherwise the
    user sees "duplicate case label" pointing into `macros.nim`.
  - Registration order matters: only procs whose `{.expose.}` was
    semantically checked before the `startApp()` call site are dispatched.
    Document: `startApp` must come after every `{.expose.}` proc and after
    the imports of modules that contain them. `startApp` itself may be called
    inside a proc (e.g. `main()`).
  - The `*` on `<name>NeelSym` is not required for dispatch (spliced symbols
    resolve without export); keep it for tests and predictability.
- Tests: expansion snapshots, arity and type-mismatch errors, defaults, return
  values, cross-module registration (per spike results), duplicate-name
  diagnostic.

#### Task 9: `js` proxy
**Status:** done

Deviations: `wait` is one proc with a defaulted parameter (`wait(p,
timeoutMs = UseDefaultTimeout)`) rather than two overloads; both call forms
work. Arguments are converted with `expose.convertResult` (`std/jsonutils`
`toJson`, enums as names), so `jsproxy.nim` imports `expose.nim` (not in the
dependency sketch; no cycle). The module is `src/neel/jsproxy.nim`, not the
planned `js.nim` (approved in review): a module name wins over a symbol of
the same name, so with a module called `js` every `import neel/js` turned
`js.foo(1)` into module-qualified access ("undeclared identifier: 'foo'";
verified with `let` and `const`, and a plain `import neel/js; export js` in
`neel.nim` leaked the module name to the user as well). The test file is
`tests/t_jsproxy.nim` accordingly.

Notes for later tasks:
- Types (`neel/jsproxy.nim`): `JsProxy = object(windowId: int)`, `JsWaitProxy =
  object(windowId, timeoutMs: int)`; plain ints, no refs, so both are usable
  from `{.gcsafe.}` code and `Task`-isolatable. Sentinels: `CurrentWindow =
  0` (`windowId` meaning "this thread's current window"), `NoWindow = 0`
  (`currentWindowId()` when none is set), `UseDefaultTimeout = 0`
  (`timeoutMs` meaning the bridge's default). Window ids are therefore
  positive integers (Task 12 must never issue 0). `DefaultCallTimeoutMs =
  10_000`. `NeelNoWindowError` (`object of CatchableError`) lives here.
- Globals and constructors: `const js* = JsProxy(windowId: CurrentWindow)`;
  `initJsProxy(windowId): JsProxy` for an explicit window; `wait(p: JsProxy;
  timeoutMs = UseDefaultTimeout): JsWaitProxy` (`js.wait`, `js.wait(500)`;
  a non-positive `timeoutMs` means the default).
- Dot operators: `macro `.()`(p: JsProxy; name: untyped; args:
  varargs[untyped])` expands to `jsSend(p, "name", @[convertResult(a),
  ...])` (`newSeq[JsonNode]()` for no arguments), returns `void`; the
  `JsWaitProxy` overload expands to `jsCallWait(...)` returning `JsonNode`.
  No logic in the macros. Accepted argument types = everything
  `convertResult` handles (the Task 8 list: scalars, `string`, enums as
  names, `seq`/`array`/`set`, tuples, objects, `ref`, `distinct`, `Option`,
  `Table[string, V]`, `HashSet`, `JsonNode` passed through); any expression,
  not only literals; `nil` has no type, use `newJNull()`. `js.foo` without
  parentheses is the compiler's "undeclared field" error. Method-call syntax
  wins over dot operators: `js.echo("x")` calls Nim's `echo`, `js.repr()`
  calls `repr`; `js.len()`, `js.add()`, `js.close()`, `js.open()` etc.
  reach the operator. Escape hatch for collisions and dynamic names:
  `jsSend(p: JsProxy; name: string; args: seq[JsonNode])` and
  `jsCallWait(p: JsWaitProxy; name: string; args: seq[JsonNode]): JsonNode`,
  both `{.gcsafe.}`, both public.
- Semantics: `jsSend` = `sendText(conn, encode(callMsg(name, args)))`, no
  table; a `false` from the send proc (connection closing) is swallowed,
  fire-and-forget never reports. `jsCallWait` = `id = ids[].nextId();
  pending.register(conn, id); if not sendText(...): cancel + raise
  NeelDisconnectedError; pending.wait(conn, id, timeoutMs)` with `timeoutMs`
  = the proxy's or the bridge default. Exceptions: `NeelNoWindowError`
  (bridge not initialised; `CurrentWindow` with no thread-local set; window
  id the resolver does not know / not connected), then the `PendingTable`
  set (`NeelRemoteError` with the JS `kind`, `NeelDisconnectedError`,
  `NeelTimeoutError`).
- Current window: `var currentWindowVar {.threadvar.}: int`; API
  `currentWindowId(): int` (`NoWindow` if unset), `setCurrentWindow(id)`,
  `clearCurrentWindow()`, `template withCurrentWindow(id; body)` (saves the
  previous value, sets, runs, restores in `finally`; nests). All
  `{.gcsafe.}`. Nothing is inherited by new threads.
- Bridge (injection seam): `initJsBridge(sendText: SendProc; resolveWindow:
  WindowResolver; pending: PendingTable; defaultTimeoutMs =
  DefaultCallTimeoutMs)` and `resetJsBridge()`. `SendProc = proc(conn:
  ConnId; text: string): bool {.gcsafe.}`; `WindowResolver = proc(windowId:
  int): WindowRoute {.gcsafe.}` with `WindowRoute = object(conn: ConnId,
  ids: ptr IdAllocator)` where `ids == nil` means "unknown or not
  connected" (`CurrentWindow` is resolved to a real id before the resolver
  is called, so it never sees 0). The record is a module global written
  once on the main thread (`doAssert`s on nil procs / table and a
  non-positive timeout) and read through one `{.cast(gcsafe).}` accessor;
  readers call through the `ref` fields without copying them. Calling
  `initJsBridge` again is allowed only after `shutdown` (no worker running);
  `resetJsBridge` makes every `js.*` raise `NeelNoWindowError` again.
- Importing: `import neel/jsproxy` (plain); nothing to alias. Do not add a
  module, type, or proc named `js` anywhere in the package: it would shadow
  the global.
- For Task 10 (`neel.js`): a Nim -> JS call arrives as exactly
  `{"t":"call","name":"foo","args":[1,"x",true]}` (fire-and-forget, no `id`
  key at all) or `{"t":"call","id":N,"name":"foo","args":[...]}` with a
  positive `N`; `args` is always an array (`[]` for no arguments) and its
  elements follow the Task 8 result encoding (enums as name strings,
  objects as JSON objects, `Option` none as `null`). Reply with
  `{"t":"ret","id":N,"value":V}` / `{"t":"err","id":N,"error":{"kind":...,
  "msg":...}}` only when `id` is present; the `err.error.kind` string
  becomes `NeelRemoteError.kind` on the Nim side and is forwarded verbatim if
  it crosses back to JS via an exposed proc's failure. Ids on the two
  directions are independent counters (Nim's starts at 1 per connection).
- For Task 12 (windows): `Window.js* = initJsProxy(w.id)` at creation; the
  id must be a positive `int` (it also goes into `__NEEL_WINDOW_ID__`).
  Keep one `IdAllocator` per window/connection record (never reset while
  the connection lives; drop it with the record) and implement
  `WindowResolver` over the window table: `proc(windowId: int): WindowRoute
  {.gcsafe.}` = under the window-table lock, look up the window; if it has a
  live connection return `WindowRoute(conn: w.conn, ids: addr w.ids)`, else
  `WindowRoute()`. The `ptr IdAllocator` must stay valid while a
  `jsCallWait` may be using it: allocate window records in shared memory or
  keep them in a container that does not move them (`ptr`/`ref` records,
  not value entries of a growing `Table`), and free a record only after
  `onClose` has run. `currentWindow()` is `currentWindowId()` mapped
  through the window table (`NoWindow` -> none / error). A `jsSend` after
  the connection is gone is silently dropped; a `jsCallWait` raises
  `NeelDisconnectedError` either from the failed send or from `disconnect`.
- For Task 13 (`startApp`): order is `tbl = newPendingTable()`; `srv =
  newServer(...)`; `initJsBridge(proc(conn, text) = srv.send(conn, text)`
  -- or a plain proc over the module-global server --, `resolver`, `tbl`,
  `callTimeoutMs)`; `srv.listen(port)`; launch the browser. The send proc
  may capture the `Server` (the bridge is not stored by the server, so the
  Task 6 cycle warning does not apply), but a plain proc reading the module
  global is simplest. `onMessage(conn, text)`: `let m = decode(text)`
  (catch `NeelProtocolError`); `case m.kind of msgCall: var reply:
  Option[Msg]; withCurrentWindow(windowIdOf(conn)): reply = handleCall(m,
  neelDispatch); if reply.isSome: discard srv.send(conn,
  encode(reply.get))` (use `NoWindow` if the connection has no window, so
  `js.*` inside raises `NeelNoWindowError` cleanly); `of msgRet, msgErr:
  discard tbl.complete(conn, m.id, m)`. `onClose(conn)`: mark the window
  disconnected (so the resolver returns `ids == nil`), then `discard
  tbl.disconnect(conn)`; a worker blocked in `jsCallWait` on that
  connection then raises `NeelDisconnectedError`, `handleCall` turns it
  into an `err`, and the `send` of that reply simply returns `false`.
  Because `onClose` may overlap a running handler, a `jsCallWait` that
  starts after the mark sees `NeelNoWindowError` (resolver) or
  `NeelDisconnectedError` (send returns `false`); both are fine. After
  `shutdown` (all `onClose` done): `resetJsBridge()`, then drop the table.
  `src/neel.nim` does `import neel/jsproxy; export jsproxy` so users get
  `js`, `wait`, `jsSend`, `jsCallWait`, `JsProxy`, `JsWaitProxy`,
  `NeelNoWindowError`, `currentWindowId`, and the sentinels. The
  integration test in `tests/t_jsproxy.nim` is a working model of this wiring
  (hooks as plain procs over a module global, `handleCall` bracketed by
  `withCurrentWindow`, ret / err / timeout / disconnect paths).
- Gotchas: `inMilliseconds` truncates, so a wait with a 50 ms deadline can
  measure as 49 ms; timing assertions need a margin. The `.()` macro with
  `varargs[untyped]` receives zero arguments as an empty node list, so the
  empty-args case must be built explicitly (`@[]` has no type there).
- Tests (`tests/t_jsproxy.nim`, 24 cases): exact wire text for `js.foo(1, "x",
  true)` and `js.noArgs()`, object/seq/enum/float/JsonNode/null/expression
  arguments compared with `convertResult`, blocking `js.wait.foo(1)` with a
  cross-thread `ret`, `js.wait(50)` timeout bounds, per-connection id
  sequence, `not compiles(js.foo)` and void-ness, proxy sizes; routing by
  thread-local, explicit proxy vs thread-local, nested `withCurrentWindow`
  restore (also on exception), `NeelNoWindowError` for no current window /
  unknown window / uninitialised bridge, thread-local isolation across
  threads; `.to(int)` on a `ret`, `err` -> `NeelRemoteError` kind/msg,
  bridge default timeout, failed send -> `NeelDisconnectedError` with
  `pendingCount == 0`, `disconnect` during a wait; escape hatch for
  `echo`/`repr`/`len` and dynamic names, `.to(Point)` chaining; one
  integration test against the real server (scripted client triggers an
  "exposed proc" that does `js.wait.foo(1)`; ret, forwarded `TypeError`,
  `NeelTimeoutError`, and abrupt close -> `NeelDisconnectedError` are all
  checked; shutdown in `finally`). Every wait and read is bounded (3 s).

Revised by Task 2 spike (b): the original `js.foo(...).wait()` design is not
implementable (see "Spike results"). The wait modifier moves onto the proxy.

- `neel/jsproxy.nim` (planned as `js.nim`): `JsProxy`, `JsWaitProxy`, and dot operators
  (`{.experimental: "dotOperators".}` only in this module; the user's module
  needs nothing).
  - `js.foo(args...)` sends a fire-and-forget `call` immediately and returns
    nothing (`void`; no handle, no `discard` needed).
  - `js.wait.foo(args...)` and `js.wait(timeoutMs).foo(args...)` send with an
    id, block via the pending table, and return `JsonNode`. `wait` is a plain
    proc `JsProxy -> JsWaitProxy`; the two proxy types each have their own
    `.()` macro, so fire-and-forget vs blocking is decided by type at compile
    time. Typed convenience is `js.wait.foo(...).to(T)` from `std/json`
    (no generic `.wait[T]`).
  - Both `.()` macros expand to a call of an ordinary proc
    (`jsSend` / `jsCallWait`) taking `(proxy, name: string, args: seq[JsonNode])`;
    those procs are also the public escape hatch for dynamic names and for JS
    function names that collide with Nim procs (`js.echo(...)`, `js.repr()`
    resolve to the Nim procs via UFCS before dot operators are tried).
  - `js` is a global `let`/`const` of a plain-int-field object so it is usable
    from `{.gcsafe.}` worker code. Thread-local current window set by the
    dispatcher while an exposed proc runs; `js.foo` targets it.
  - `win.js.foo(...)` / `win.js.wait.foo(...)` target an explicit window via a
    `js*: JsProxy` **field** on `Window` (a `proc js(w: Window)` cannot
    coexist with the global `js`).
  - Defined behavior when no window is connected (`NeelNoWindowError`).
- Tests: expansion of both proxies, routing to the current vs explicit window,
  timeout, name-collision escape hatch.

#### Task 10: Frontend `neel.js`
**Status:** done

Deviations: the placeholders are substituted at *serve* time, not compile
time - the token is random per launch and the window id differs per window,
so only the `staticRead` is compile-time; `renderNeelJs` is a pure
`{.gcsafe.}` proc Task 13 calls per `/neel.js` request. The `static:` block
asserts the placeholder invariants at compile time instead. A close with
code 1000 or 1001 is treated as final (no reconnect); the task text's
"reconnect policy for page refresh" is really "reconnect after an abnormal
close" - a refresh reloads the shim, which simply connects again with the
same window id. No JS runtime is installed here (no node/deno/bun), so the
shim has no Nim unit test; it was verified in the IDE browser against a
throwaway Task 6 server (details below). The `/ws` path and the query
parameter names are exported constants so Task 13 and the shim share one
definition (checked at compile time).

Notes for later tasks:
- `neel/frontend.nim`: `NeelJsSource*` (the raw shim), `TokenPlaceholder*`
  / `WindowIdPlaceholder*` / `ExposedPlaceholder*` (`__NEEL_TOKEN__`,
  `__NEEL_WINDOW_ID__`, `__NEEL_EXPOSED__`), `WsPath* = "/ws"`,
  `TokenQueryParam* = "token"`, `WindowQueryParam* = "window"`,
  `jsStringLiteral*(s): string` (JSON string literal via `std/json`, plus
  `</` -> `<\/`), `jsStringArrayLiteral*(seq[string]): string` (`[]` when
  empty), and `renderNeelJs*(token: string; windowId: int; exposed:
  seq[string]): string {.gcsafe.}`: one `multiReplace` pass (a token that
  contains a placeholder name is emitted verbatim inside its literal),
  byte-identical for equal arguments, `doAssert windowId > 0`. The `static:`
  block checks each placeholder occurs exactly once, `__NEEL_` occurs
  exactly three times, the shim's URL literal uses `/ws?token=` and
  `&window=`, and a rendered sample has no `__NEEL_` left.
- Shim connection: `ws://<location.host>/ws?token=<encodeURIComponent(token)>
  &window=<id>` (`wss:` under `https:`). Task 13 should generate a URL-safe
  token (hex or base64url) so `req.query` needs no percent-decoding;
  `std/uri.decodeQuery(req.query)` yields `(key, value)` pairs and decodes
  anyway. The shim never sends binary frames and never sends `id: null` or
  `id: 0`; ids are positive integers starting at 1 per connection and are
  allocated when the frame goes on the wire (so queued calls get fresh ids on
  the connection that carries them).
- `neel` object surface (all own, non-writable properties; `typeof neel ===
  "object"`, installed as `globalThis.neel`, classic script only - module
  code reads `window.neel`): `neel.<name>(...args): Promise` and
  `neel.<name>.send(...args): undefined` for every name in `__NEEL_EXPOSED__`
  (generated at load; `fn.name === name`); `neel.call(name, ...args):
  Promise` and `neel.send(name, ...args)` for dynamic names (`TypeError` for
  a non-string name); `neel.expose(fn)` (uses `fn.name`, `TypeError` if
  anonymous), `neel.expose(name, fn)`, `neel.expose({name: fn, ...})`
  (`TypeError` if a value is not a function); `neel.ready: Promise` (resolved
  on the first open, rejected with `NeelDisconnectedError` if the shim gives
  up or is closed before ever opening; an internal `.catch` prevents an
  unhandled-rejection report when nobody awaits it); `neel.windowId:
  number`; `neel.close()`. The names `call`, `send`, `expose`, `ready`,
  `windowId`, `close` are reserved: an exposed Nim proc with one of those
  names gets no generated function (a `console.warn` says to use
  `neel.call(name, ...)`). Loading `neel.js` twice is a no-op with a warning.
- Error names JS -> app (rejections): an `Error` with `name` and `kind` both
  set to the wire `kind` and `message` = wire `msg` (`"ValueError"`,
  `"NeelArgumentError"`, `"NeelUnknownProcError"`, ...);
  `"NeelDisconnectedError"` for a pending call when the connection closes
  for any reason (message names the close code), for calls made after the
  shim is terminated (`"neel: connection is closed"`), and for queued calls
  when the retries run out (`"neel: gave up reconnecting after 5 attempts"`).
  Error kinds JS -> Nim (in `err.error`): `e.name` when it is a non-empty
  string else `"Error"` (a thrown string gives `kind: "Error", msg: <the
  string>`); `"NeelUnknownFunctionError"` with `msg: "no exposed JS function
  named '<name>'"` when the name is neither in the registry nor a function
  on `globalThis`. Lookup order is the `neel.expose` registry first, then
  `window[name]`; a Nim call to a global like `alert` therefore works.
  Replies are sent only when the call had an `id`, only on the socket the
  call arrived on (never queued), and `undefined` results become `null`;
  thenables are awaited. Without an id, an unknown name or a throw is a
  `console.warn`. Malformed inbound text (not JSON, non-object, unknown `t`,
  bad `id`, missing fields - the same set `protocol.decode` rejects, minus
  the depth limit) and a `ret`/`err` for an unknown id are `console.warn`ed
  and dropped.
- Queueing: a call or `.send` issued while the socket is not open (before the
  first open or during a reconnect) is queued and flushed in order on open;
  nothing is dropped unless the shim terminates. Replies to Nim are never
  queued.
- Reconnect numbers: on a close that is not `neel.close()` and whose code is
  not 1000 or 1001, in-flight promises are rejected with
  `NeelDisconnectedError` and the shim retries up to `MAX_RECONNECT_ATTEMPTS
  = 5` times with delays `250 * 2^(attempt-1)` ms (250, 500, 1000, 2000,
  4000; 7.75 s total, measured 7.8 s), presenting the same token and window
  id; a successful open resets the counter and flushes the queue. After the
  fifth failure the shim is terminated: queued promises are rejected, every
  later call rejects immediately, `neel.ready` is rejected if it never
  resolved. A close with code 1000 or 1001 terminates the shim at once (no
  retry). `neel.close()` sends 1000, rejects pending and queued calls, and
  terminates. Terminated is permanent for the page; a refresh starts over.
- For Task 12 (windows): a reconnect presents the *same* window id on a
  *new* connection (new `ConnId`), as does a page refresh; the window table
  must re-associate the window with the new connection rather than treat it
  as a duplicate. The old connection's `onClose` may run after the new
  connection's upgrade handler (hooks are concurrent), so re-association
  must be keyed on the `ConnId`: only clear a window's connection in
  `onClose` if it still points at the closing `ConnId`. During the backoff
  window the connection count drops by one, so a grace period shorter than
  the first retry (250 ms) would exit on a transient hiccup; the defaults (3
  s / 10 s) are fine. When `shutdown` sends 1001, the shim does not
  reconnect and every later `neel.*` call in that page rejects with
  `NeelDisconnectedError`; `closeWindow` with 1000 or 1001 behaves the same.
  Closing with any other code (e.g. 1011) makes the shim reconnect, so use
  1000/1001 for deliberate closes. A client-side `neel.close()` arrives as a
  1000 close from the browser and should be treated like a closed window.
- For Task 13 (wiring): route `GET /neel.js` -> `respond(okResponse(
  renderNeelJs(token, windowId, exposedNames()), "application/javascript"))`
  plus `Cache-Control: no-store` (no caching, so a refresh gets a new token
  if the app restarted; `exposedNames()` is evaluated inside `startApp` after
  the user's exposed procs); the window id comes from the launch URL (e.g. a
  query parameter on `/`) or the window table - this task does not decide
  that. Route `/ws`: `if req.path == WsPath and isWebSocketUpgrade(req)`,
  parse `req.query` with `std/uri.decodeQuery`, require `TokenQueryParam`
  equal to the launch token and `WindowQueryParam` to parse as a known
  positive window id, record the conn <-> window mapping, then `upgrade()`;
  otherwise `respond(initResponse(403, ...))` (the browser sees a 1006 close
  and the shim retries, harmlessly, five times). `index.html` must load
  `<script src="/neel.js">` before the app's own script; module code uses
  `window.neel`. A token/window mismatch is also what the shim's five
  refused reconnects look like in the log after a restart with a new token;
  a refresh fixes it because `/neel.js` is re-rendered.
- Verified in the IDE browser (Chromium) against a throwaway server under
  `/tmp` (Task 6 server on a fixed port; `/neel.js` rendered with a known
  token, window 1, exposed `["add", "fail", ...]`; `/ws` upgraded only with
  the right token *and* window id; `onMessage` = `decode` + `handleCall`
  with a hand-written dispatcher; Nim -> JS calls pushed after `onOpen`; the
  raw wire text logged server-side and read back over HTTP): `await
  neel.add(2, 3) === 5`; `neel.fail()` rejects with `e.name === "ValueError"`
  and `e instanceof Error`; `neel.add.send(1, 1)` and `neel.send("add", 7,
  7)` arrive as `{"t":"call","name":"add","args":[1,1]}` with no `id`;
  `neel.call("add", 4, 5)`; unknown Nim name -> `NeelUnknownProcError`;
  arity -> `NeelArgumentError` with the Task 8 message; a call and a `.send`
  issued synchronously at load (before open) are delivered after open, the
  `.send` to a raising proc gets no reply; `neel.expose(function jsDouble)`,
  `expose({jsThrow})`, `expose("jsAsync", fn)` all receive Nim calls and the
  server got `{"t":"ret","id":1,"value":42}`, `{"t":"err","id":2,"error":
  {"kind":"RangeError","msg":"out of range"}}`, `{"t":"ret","id":4,
  "value":6}` (awaited promise), `value: null` for `undefined`, a nested
  object/array result, `kind: "Error"` for a thrown string; `window[name]`
  fallback (fire-and-forget) ran; unknown name -> `{"kind":
  "NeelUnknownFunctionError", ...}`; non-JSON, `{"t":"bogus"}`, `id: 0`, and
  a `ret` for an unknown id were warned and dropped with the connection
  intact; wrong token and wrong window id -> 403 -> browser close 1006;
  server close 1011 -> pending rejects with `NeelDisconnectedError`, a call
  queued during the backoff resolved after the reconnect (263 ms), ids
  restarted at 1 on the new connection; server close 1001 -> pending rejects,
  no reconnect attempt for 1.5 s, later calls reject immediately; with the
  server refusing every upgrade: exactly 5 retries, 7797 ms, the queued call
  rejected with "gave up", later calls reject immediately, and (fresh page)
  `neel.ready` rejected with `NeelDisconnectedError`; `neel.close()` rejects
  a pending call and later calls; anonymous `neel.expose(fn)` and
  `expose("x", 42)` throw `TypeError`; `Object.keys(neel)` is exactly the
  documented surface plus the exposed names. Not verified: `wss:`, binary
  frames arriving at the shim (the server never sends them), behaviour in
  non-Chromium browsers, and the fragment/large-message paths (covered by
  `t_server.nim` at the frame level).
- Tests (`tests/t_frontend.nim`, 13 cases): literal escaping round-trips
  through `parseJson` for a token with `"`, `\`, `</script>`, control
  characters and non-ASCII; no raw `</` in a literal; array literal for
  empty/one/many/escaped; exact rendering equals an independent
  `multiReplace`; each literal appears once; hostile token parses back; empty
  and multi-name exposed lists (counts against the source's own `[]`); no
  `__NEEL_` left and exactly three in the source; single-pass substitution;
  purity (byte-identical, and different for each changed argument);
  `AssertionDefect` for window id 0 / -1; the shared constants appear in the
  rendered URL; no top-level `import`/`export` and `globalThis.neel = neel`
  present.

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
**Status:** done

Deviations: discovery takes a `hostOs` parameter (default: the compile
target) so the macOS, Windows, and Linux search rules and the three opener
commands are all unit-tested on any host; the probes are a `Discovery` record
of five procs. A `browserPath` override that does not exist raises
`NeelBrowserError` rather than falling through to discovery (an explicit
misconfiguration should be loud). A `launchWithFallback` convenience that
combines search result, `fallback`, and the error page was added so Task 13
does not re-derive the four cases. The reserved members carry a display name
(for the "reserved, not supported" line) but are otherwise empty. The
no-browser URL carries the probed names in its query so the page can render
without server state. Chromium has no Windows `App Paths` key on purpose.
All real launches ran as throwaway programs under `/tmp/neelb/` (deleted).

Notes for later tasks:
- Types (`neel/browser.nim`): `Browser = enum Chrome, Chromium, Edge, Brave,
  Opera, Vivaldi, Default`; `HostOs = enum hoMacos, hoWindows, hoLinux` with
  `CurrentHostOs` (BSDs use the Linux rules); `BrowserSpec` fields `name`,
  `supported`, `supportsAppMode`, `macAppPaths` (`~/` expanded with `HOME`),
  `macBundleIds` + `macExecutable` (mdfind fallback), `windowsRelativePaths`
  (under `%ProgramFiles%`, `%ProgramFiles(x86)%`, `%LocalAppData%`, in that
  order), `windowsAppPathsKeys` (HKCU then HKLM
  `SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\<exe>`),
  `linuxExecutables` (`findExe`); `const BrowserSpecs: array[Browser,
  BrowserSpec]` with a `static:` consistency block (populated entries have
  candidates on every OS and app mode; `Default` and reserved members have
  none). Helpers `isSupported(b)`, `isReserved(b)` (`Edge`, `Brave`,
  `Opera`, `Vivaldi`), `displayName(b)`, `hasCandidates(spec, os)`.
- Discovery: `Discovery = object(fileExists, findExe, getEnv, mdfind,
  registryAppPath)` - five `{.gcsafe.}` procs; `systemDiscovery()` is the
  real one (`mdfind` via `execProcess` with an args array on macOS, empty
  elsewhere; `std/registry.getUnicodeValue` on Windows, empty elsewhere).
  `probeBrowser(b, discovery, hostOs = CurrentHostOs): ProbeResult(browser,
  candidates: seq[string], path)` records every location examined.
  `findBrowser(preferences: seq[Browser]; browserPath = ""; discovery =
  systemDiscovery(); hostOs = CurrentHostOs): BrowserSearch` with
  `found: Option[FoundBrowser(browser, path, fromOverride)]`, `probed:
  seq[ProbeResult]` (in order, including the one found), `skipped:
  seq[Browser]` (reserved members). Walk: `Default` is always "found"
  (`path == ""`) and stops the walk; reserved members are skipped; a
  non-empty `browserPath` must exist (`NeelBrowserError` otherwise) and is
  returned as-is with `browser` = first app-mode preference (or `Chrome`),
  `fromOverride = true`, nothing probed. Empty list -> nothing found.
  `searchedNames(s): seq[string]` (display names), `describeSearch(s):
  seq[string]` (`Google Chrome: <candidate>, <candidate>, ...` plus
  `Microsoft Edge: reserved, not supported in this release`). Both
  `findBrowser` and the launch procs are `{.gcsafe.}` (`openWindow` from an
  exposed proc runs on a worker).
- Launch: `buildLaunchArgs(url, userDataDir; size = none(WindowSize);
  position = none(WindowPosition); extraFlags: openArray[string] = []):
  seq[string]` (pure; also an overload over `LaunchOptions(size, position,
  extraFlags)`) returns exactly `["--app=<url>", "--user-data-dir=<dir>",
  "--window-size=W,H"?, "--window-position=X,Y"?, "--disable-http-cache",
  "--no-first-run", "--no-default-browser-check", extras...]`; one argv
  element each, nothing quoted; `WindowSize = tuple[width, height: int]`
  (non-positive -> `ValueError`), `WindowPosition = tuple[x, y: int]`
  (negatives allowed). `launchBrowser(found: FoundBrowser; url, userDataDir;
  opts = LaunchOptions()): BrowserHandle` = `startProcess(found.path, args,
  options = {poParentStreams, poDaemon})` (the browser inherits our stdio: a
  pipe nobody reads would eventually block Chromium's logging; expect its
  stderr noise in the terminal); `OSError` -> `NeelBrowserError`.
  `userDataDirFor(windowId; pid = getCurrentProcessId(); tempDir =
  getTempDir())` = `<tempDir>/neel-<pid>-<windowId>`.
- User-data-dir policy (decided, measured on this Mac with Chrome): **one
  private dir per window** (`userDataDirFor(windowId)`). Measured: a second
  `--app` launch with the *same* dir prints "Opening in existing browser
  session.", opens the window inside the first instance, and the launcher
  exits after ~210 ms with code 0, so its handle tracks nothing; with
  distinct dirs every window is its own process that stays alive. Cost: each
  window is a full browser instance (memory) and a fresh profile
  (`--no-first-run` suppresses the welcome flow). Also measured: closing the
  only app window (DevTools `/json/close`, equivalent to the user's close
  button) leaves the macOS process *running* - "process alive" does not
  mean "window open". `terminate()` (SIGTERM) exits in ~80-100 ms with code
  0 and takes the helper processes along; `kill()` gives 137 in ~60 ms.
- Handle (`BrowserHandle`, a `ref object`, not thread-safe - guard it with
  the window-table lock): `kind: LaunchKind` (`lkAppWindow` | `lkDefaultBrowser`),
  `browser`, `path`, `args`, `url`, `userDataDir` (`""` for the default
  browser), private `process: Process`. Procs: `isRunning(h)` (`false` for
  nil, default-browser, or closed handles), `pid(h)` (0 when none),
  `exitCode(h)` (-1 while running / none), `terminate(h, graceMs =
  TerminateGraceMs (2000)): bool` (SIGTERM, poll, SIGKILL after `graceMs`,
  `true` when gone), `close(h)` (releases the OS handle, idempotent),
  `removeUserDataDir(h)` (best effort, only when not running). What the
  handle guarantees: for `lkAppWindow` with a per-window dir, the process
  *is* the window's browser instance, so `terminate` closes the window and
  `isRunning == false` means the browser is gone (crash or quit). It does
  **not** guarantee that a live process has a window (macOS keeps the app
  running after the last window closes). For `lkDefaultBrowser` nothing is
  tracked: `isRunning` is always `false`, `terminate` is a no-op `true`.
- Default browser: `defaultBrowserCommand(url, hostOs = CurrentHostOs):
  OpenerCommand(command, args)` = `open <url>` (macOS), `xdg-open <url>`
  (Linux/other POSIX), `rundll32.exe url.dll,FileProtocolHandler <url>`
  (Windows); the URL is one argv element. `openDefaultBrowser(url):
  BrowserHandle` runs it with `{poUsePath, poParentStreams, poDaemon}`,
  polls up to 3 s for the opener to exit (`open` takes ~100 ms), raises
  `NeelBrowserError` if it cannot start or exits non-zero (verified: `open`
  of a missing file -> code 1 -> error), returns an `lkDefaultBrowser`
  handle with no process.
- Error page: `NoBrowserPath* = "/neel/no-browser"`, `NoBrowserQueryParam* =
  "searched"`; `noBrowserPageUrl(baseUrl, search)` =
  `<baseUrl>/neel/no-browser?searched=Chrome,Chromium` (enum names, comma
  separated, query omitted when nothing was probed; trailing slash on
  `baseUrl` tolerated). `NeelBrowserError = object of CatchableError` with
  `searched*: seq[string]` (display names; empty for the override and
  `startProcess` cases).
- `launchWithFallback(search, url, errorPageUrl, fallback, userDataDir, opts
  = LaunchOptions()): BrowserHandle`: found app-mode -> `launchBrowser`;
  found `Default` -> `openDefaultBrowser(url)`; none + `fallback` ->
  `openDefaultBrowser(url)`; none + not `fallback` -> best-effort
  `openDefaultBrowser(errorPageUrl)` then raises `NeelBrowserError` listing
  the searched names (the opener failure, if any, is appended to the
  message).
- For Task 12 (windows): create the window record (positive id, Task 9),
  compute `userDataDirFor(id)`, launch, and store the `BrowserHandle` in the
  record. Poll liveness with `h.isRunning` under the window lock if you want
  to detect a crashed/quit browser early, but drive the lifecycle from the
  WebSocket connection count (Task 6 notes) because a live process may have
  no window (macOS). `closeWindow`: `close(conn, CloseNormal)` so the shim
  does not reconnect, then `h.terminate()` (the browser exits in ~100 ms and
  the window disappears), `h.close()`, `h.removeUserDataDir()` once
  `isRunning` is `false`; `quit()`/shutdown: the same for every window. A
  handle whose process exited immediately with code 0 after launch (within
  ~250 ms) means Chrome handed the window to an already-running instance -
  this cannot happen with `userDataDirFor` unless the user passes the same
  `--user-data-dir` in `extraFlags` (the later flag wins in Chromium); treat
  such a window as untrackable (connection count only, no terminate). The
  window id should be carried in the launch URL's query: launch
  `http://127.0.0.1:<port><path>?window=<id>` (reuse `WindowQueryParam`
  from `frontend.nim` so the page URL, `/neel.js`, and `/ws` share one
  name). The page then loads `<script src="/neel.js">`; that request's
  `Referer` is the page URL (same-origin script loads carry the full URL
  under Chromium's default referrer policy), so Task 13 can render
  `__NEEL_WINDOW_ID__` from `Referer`'s `window=` and fall back to the
  single not-yet-served window when the header is absent. A refresh keeps
  the query, so the same id is presented again (Task 10). Gotcha:
  `osproc.waitForExit(p, timeout)` on
  macOS/BSD **SIGKILLs** the child when the timeout expires; never use it to
  wait politely - `terminate` polls `running()` instead.
- For Task 13 (`startApp`): parameters `browsers: seq[Browser]` (suggested
  default `@[Chrome, Chromium]` - with `Default` in the list "nothing found"
  can never happen and `fallback` is moot; `@[Default]` forces a tab),
  `fallback = true`, `browserPath = ""`, `size`, `position`, `extraFlags`.
  Order: `srv.listen(port)` -> `let base = "http://127.0.0.1:" & $srv.port`
  -> `let search = findBrowser(browsers, browserPath)` (may raise
  `NeelBrowserError` for a bad override; do it before `listen` if you prefer
  failing fast) -> create window 1 -> `launchWithFallback(search, base &
  "/?window=1", noBrowserPageUrl(base, search), fallback, userDataDirFor(1),
  LaunchOptions(size, position, extraFlags))`. Serve `GET /neel/no-browser`
  (`NoBrowserPath`) as `text/html` without needing the token: list
  `search.describeSearch` (one line per probed browser with the locations
  tried, plus the reserved members), say that `fallback = false` was set,
  and how to fix it (`browserPath`, install Chrome/Chromium, or
  `fallback = true`); the `searched` query names are redundant with the
  retained `BrowserSearch` and may be ignored. When `launchWithFallback`
  raises in the `fallback = false` case the error page has already been
  opened in the default browser, so keep the server up for the grace period
  (treat it like a window that never connected) before shutting down,
  otherwise the page 404s/refuses. `src/neel.nim` should re-export
  `Browser`, `NeelBrowserError`, and `LaunchOptions`/`WindowSize`/
  `WindowPosition` if they appear in the `startApp` signature.
- Tests (`tests/t_browser.nim`, 47 cases): spec-table consistency (supported
  / reserved / `Default`, per-OS candidates, names, `supportsAppMode`,
  `CurrentHostOs`); `probeBrowser` on all three OS rule sets with a canned
  `Discovery` that logs every question (macOS fixed path, `~` expansion with
  and without `HOME`, mdfind fallback, full candidate list when missing;
  Windows root order, trailing backslash, registry last and
  existence-checked, Chromium never consults the registry, unset roots;
  Linux `findExe` order), usage errors for `Default`/reserved/incomplete
  `Discovery`; `findBrowser` resolution (first found, second found, nothing,
  empty list, `Default` first and mid-list, reserved skipped and recorded,
  override exists / missing / with no app-mode preference); `describeSearch`
  and `noBrowserPageUrl` formatting (round-trip of the enum names through
  `parseEnum`); exact argv for every `buildLaunchArgs` shape, one-argument
  URL with no quoting, extras verbatim and in order, `LaunchOptions`
  equivalence, `ValueError`/`AssertionDefect` cases, `userDataDirFor`
  policy; the three opener commands; nil / default-browser handle queries;
  `NeelBrowserError` shape. Nothing launches. Manual verification on this
  Mac (throwaway `/tmp/neelb/real.nim`, deleted): `systemDiscovery` found
  Chrome at `/Applications/...` and listed the Chromium locations plus the
  mdfind query; `launchBrowser` opened a 500x320 app window at (80,80) with
  the exact argv above; same-dir second launch exited with 0 within 1.5 s;
  `terminate` returned `true` in 79 ms with exit 0; `removeUserDataDir`
  removed the profile; `openDefaultBrowser` of a missing file raised with
  "exited with code 1" and of a real page opened one tab; `launchWithFallback`
  with nothing found and `fallback = false` raised with `searched =
  @["Chromium"]`. Also compiled with `--os:windows` and `--os:linux
  --compileOnly` to check the `std/registry` and opener branches.

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
  - `Window` type with id, browser process handle, connection reference, and
    the `js*: JsProxy` field required by Task 9 (per Task 2 spike (b)).
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
  - Added by Task 4 (see its "Notes for later tasks" for the full `http.nim`
    API): `HttpRequest.path` is **not** percent-decoded, so decode it here
    before containment checks; add `Accept-Ranges: bytes` to 200 asset
    responses yourself (`okResponse` does not) so browsers issue `Range`
    requests for media; use `parseRange` + `partialContent` /
    `rangeNotSatisfiable` for `GET`/`HEAD` on files and `contentTypeFor` for
    `Content-Type`.
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

All spikes ran on Nim 2.2.10 (macOS amd64, ORC, threads on) as throwaway
programs under `/tmp/neelspike/`; nothing from them is in the repo. Each entry
records what was tried, what happened, and what it means for later tasks.

### (a) Cross-module `typed` symbol registry — **works**

Tried, in the realistic shape: `neellib/expose.nim` (an `expose` pragma macro
that emits the user proc, a `<name>NeelSym(args: seq[JsonNode]): JsonNode`
wrapper, and `neelRegister("name", <name>NeelSym)`; `neelRegister` is a
`typed` macro that appends the received node to a
`var registry {.compileTime.}: seq[...]`), `neellib/app.nim` (a `startApp`
macro that imports only `expose`, never the user's modules, and splices each
stored node into `case name: of "x": return <sym>(args)`), `neellib.nim`
re-exporting both, a `helpers.nim` user module with an exposed proc, and
`user.nim` importing `neellib` and `helpers`, exposing three procs and calling
`startApp()`.

Result:
- `neelRegister` receives `nnkSym` with `symKind == nskProc` for every wrapper,
  including the one in `helpers.nim`.
- Splicing those syms into the `case` in a module that does not import
  `helpers` or `user` compiles and dispatches correctly (`add(2,3) = 5`,
  `helperMul(6,7) = 42`, void proc returns `null`, unknown name hits `else`).
- Works with the wrapper **not** exported (the symbol resolves anyway), and
  with `startApp()` called inside `proc main()` rather than at top level.
- Duplicate exposed names across modules produce `Error: duplicate case label`
  pointing into `lib/core/macros.nim`, not at user code.
- An `{.expose.}` proc declared *after* the `startApp()` call site is not in
  the registry when `startApp` expands (runtime "unknown exposed proc").
- A wrapper built with `quote do` carries the lineInfo of `expose.nim`; built
  with `newProc(...)` plus `copyLineInfo(def)`, the registered symbol's
  `lineInfo` points at the user's `proc` line.

Consequence: the planned design stands; fallback (d) is not needed. Task 8
gained: `newProc` + `copyLineInfo`, duplicate-name detection with both
locations, and the documented ordering rule (`startApp` after all exposed
procs and their imports). `startApp` is not restricted to top level.

### (b) Dot operators: pragma scope and `wait` chaining — **pragma works; chaining revised**

Tried: `jslib.nim` with `{.experimental: "dotOperators".}` and a
`macro `.()`(p: JsProxy, name: untyped, args: varargs[untyped])` expanding to
an ordinary proc call with `name.strVal` and `@[%a, %b]`; `user.nim` importing
it **without** the pragma.

Result:
- `js.foo(1, "x")`, `js.noArgs()`, nested `js.outer(js.inner(1).wait())`, and
  use inside a `{.gcsafe.}` proc all compile in the user module with no
  pragma. The pragma is only needed where the `.()` macro is defined.
- `let js* = JsProxy(...)` and `proc js*(w: Window): JsProxy` cannot coexist
  (`redefinition of 'js'`). A `js*: JsProxy` field on `Window` gives
  `win.js.foo(...)` and `win.js.wait.foo(...)` with no further machinery.
- UFCS wins over dot operators: `js.echo("x")` calls Nim's `echo`,
  `js.repr()` calls `repr`. `js.len()`, `js.add(1)`, `js.close()`,
  `js.open()`, `js.print()`, `js.alert()` all reach the dot operator. An
  explicit `jsSend(js, "echo", ...)` escape hatch covers collisions and
  dynamic names.
- Bare `js.foo` without parens is a clean error ("undeclared field: 'foo'").
- `js.foo(...).wait()` as specified does not work, for three independent
  reasons, each confirmed:
  1. Literal reading (send on `js.foo()`, send again with an id on `.wait()`)
     sends twice.
  2. Lazy handle (object or `ref` with `=destroy` doing the fire-and-forget
     send unless `.wait` consumed it): `js.foo(1).wait()` is correct, but a
     discarded statement-form `js.foo(1)` is destroyed at the end of the
     **enclosing proc**, not the statement (verified for value and ref types,
     with and without explicit `discard`, inside `block:` too). A
     `js.showSpinner()` would be sent after the proc returns.
  3. Making `wait` a macro that rewrites the chained AST: with method-call
     syntax `x.wait()` the compiler semchecks `x` first, so the dot operator
     has already expanded to the fire-and-forget call when `wait` sees it
     (fails whether `wait` has one overload or several; the prefix form
     `wait js.foo(1)` does receive the raw AST and works).
- Two syntaxes work cleanly: prefix `waitFor js.foo(1)` /
  `waitFor(js.foo(1), 500)` (macro on untyped AST), and proxy-level
  `js.wait.foo(1)` / `js.wait(500).foo(1)` / `win.js.wait.foo(1)` where
  `wait: JsProxy -> JsWaitProxy` is a plain proc and `JsWaitProxy` has its own
  `.()` macro returning `JsonNode`. Both tested with `.to(string)` chaining.

Consequence: Task 9 and the "Nim API" decision row were revised to the
proxy-level form (`js.wait.foo(...)`), chosen because it is type-driven (no AST
pattern matching, a plain `wait` proc, `void` vs `JsonNode` decided by the
proxy type), reads left-to-right like the fire-and-forget form, and composes
with `win.js`. `js.foo(...)` is now `void` (no handle, no `discard`). The
generic `.wait[T]` is dropped in favor of `std/json`'s `.to(T)`. `Window`
carries a `js` field. This is a visible API change from the original plan and
is flagged for review.

### (c) `std/selectors` backends and fd limits — **kqueue needs nothing; Windows needs `passC`**

Backend selection (`lib/pure/selectors.nim`, when-chain): Linux -> epoll,
macOS/BSD -> kqueue, Windows -> select, others -> poll; `-d:nimIoselector=...`
overrides. Measured locally on macOS by registering sockets in a selector
until failure:

| Setup | Limit observed |
|---|---|
| kqueue, `ulimit -n 256` (macOS GUI-launch default) | 249 sockets; `socket()` fails with EMFILE, selector never the bottleneck |
| kqueue, `ulimit -n 1024` / `8192` | 1017 / 8185 sockets (soft limit minus already-open fds) |
| select forced, default | exactly 1024 (`FD_SETSIZE` on Darwin), "Maximum number of descriptors is exhausted!" |
| select forced, `-d:FD_SETSIZE=4096` | still 1024 — the Nim define is **not** consulted anywhere |
| select forced, `{.passC: "-DFD_SETSIZE=4096".}` | 4096 — the C macro is honored and `passC` is global, so the selectors C unit sees it |
| `setrlimit(RLIMIT_NOFILE)` from inside the process under `ulimit -n 256` | soft raised 256 -> 4096 (hard is unlimited on macOS) |

From the stdlib source:
- kqueue (`ioselectors_kqueue.nim`): `fds` array sized from
  `sysctl kern.maxfilesperproc`; the real cap is the `RLIMIT_NOFILE` soft
  limit. `MAX_KQUEUE_EVENTS = 64` is only the per-`select` batch size.
- epoll (`ioselectors_epoll.nim`): `fds` sized from `maxDescriptors()`
  (= soft `RLIMIT_NOFILE` - 1, read at `newSelector` time) and **grown** on
  demand (`reallocSharedArray` in `checkFd`); typical desktop soft limit is
  1024, hard 524288. No fixed cap.
- select (`ioselectors_select.nim`): `fd_set` and `FD_SETSIZE` are `importc`
  from `<winsock2.h>` / `<sys/select.h>`; capacity is exactly `FD_SETSIZE`.
  winsock2.h defaults it to **64** under `#ifndef FD_SETSIZE`, so a
  `-DFD_SETSIZE=N` C define raises it the same way it did on macOS. Unrelated
  `std/winlean` constants (`FD_SETSIZE* = 64`, `TFdSet`) are used by
  `std/net.select`, not by `std/selectors`, and remain layout-compatible.
- `newSelectEvent` costs 1 fd (eventfd) on Linux, 2 (pipe) on macOS/BSD,
  2 sockets on Windows.

Budget per browser window: 1 WebSocket plus up to 6 Chrome HTTP keep-alive
connections, so about 7 fds per window at peak, plus listener, kqueue/epoll
fd, wake-up event, and the kqueue backend's spare socket.

Consequence: macOS and Linux need nothing for "several windows" (256 soft
limit already allows roughly 30 windows). Windows' 64-entry `select` would cap
at about 8 windows, so Task 6 now requires
`when defined(windows): {.passC: "-DFD_SETSIZE=1024".}` in `server.nim`
(`-d:FD_SETSIZE` does nothing). Task 6 also gained an optional POSIX soft-limit
raise to `min(hard, 4096)` before `newSelector`, since `maxDescriptors()` is
read then. No alternative backend is needed.

### (d) Fallback: macro-emitted `from "/abs/path/mod.nim" import sym` — **works, with limits; not needed**

Tried: an `untyped` registration macro recording `(name, lineInfoObj.filename,
wrapperName)` strings, and a `startApp` variant emitting `nnkFromStmt(newLit
path, ident wrapper)` per entry before the `case`.

Result: compiles and dispatches when (1) `startApp` is called at module top
level ("'from' is only allowed at top level" otherwise) and (2) every wrapper is
exported ("undeclared identifier" for a non-exported one). Re-importing an
already-imported module by absolute path is fine.

Consequence: viable but strictly worse than (a) (top-level-only `startApp`,
export required, absolute paths baked into generated code). Not adopted; kept
here as the documented fallback should a future Nim version break (a).
