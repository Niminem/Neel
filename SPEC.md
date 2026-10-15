# Serve mode: specification

Status: decisions settled (reviewed 2026-10-14); implementation in progress.
Progress is tracked per step in section 13; findings, deviations, and gotchas
are logged in section 16.

Serve mode runs a Neel app as a persistent server for **one user**, reached
from any of their devices through a tunnel or reverse proxy (Cloudflare
Tunnel, Tailscale, nginx, Caddy, an SSH port forward). The programming model
does not change: `{.expose.}`, `neel.foo()`, `js.foo()`, `js.wait.foo()`.

```nim
startApp(serve = true, port = 8080,
         allowedOrigins = @["https://myapp.example.com"])
```

---

## 1. Goals and non-goals

**Goals**

- No browser is launched; the app stays up until `quitApp()` or a stop signal.
- One active connection at a time: a new device displaces the previous one,
  and the displaced page knows it was displaced.
- Works behind HTTPS tunnels and reverse proxies, including auth proxies that
  redirect through a login page.
- Survives proxy idle timeouts and phones that sleep.
- Local mode (the default) behaves as it does today. Section 11 lists the
  only observable difference.
- Supported on macOS, Windows, and Linux.

**Non-goals**

- Multi-user anything: no authentication, sessions, or per-user state. Access
  control belongs to the tunnel or proxy in front of Neel.
- TLS in Neel. The proxy terminates TLS.
- Binding anything other than `127.0.0.1`.
- Multiple windows in serve mode (deferred, see section 15).

---

## 2. Findings that shaped this spec

These were checked against primary sources; none of them has been observed on
a live setup yet. The manual checklist (13.8) includes them.

**2.1 Auth-proxy logins arrive as cross-site navigations.** The Fetch Metadata
spec (W3C, "Sec-Fetch-Site", section 2.3 and "Redirects", section 4.1) walks
the request's whole URL list: if any URL in the redirect chain is cross-site
to the target, the request carries `Sec-Fetch-Site: cross-site`. A Cloudflare
Access login redirects from `<team>.cloudflareaccess.com` back to the app, so
the first page load after login is cross-site. So is any link to the app
clicked on another site (chat, email, a start page). Today `requestRefusal`
refuses every cross-site request (`frontend.nim` 105–106). That has to change
in serve mode, or the recommended deployment 403s on login.

**2.2 Proxies close idle WebSockets.** nginx closes a proxied connection after
60 s without data from the upstream (`proxy_read_timeout`) and recommends that
the upstream "periodically send WebSocket ping frames to reset the timeout"
([nginx WebSocket proxying](https://nginx.org/en/docs/http/websocket.html)).
Cloudflare closes WebSockets idle "for a period of time" (widely reported as
100 s on non-Enterprise plans) and recommends a ping/pong heartbeat. It also
terminates WebSockets when it restarts its edge servers
([Cloudflare WebSockets](https://developers.cloudflare.com/network/websockets/)).
Neel sends no pings today (`server.nim` only answers them), so serve mode
needs server pings and a robust reconnect.

**2.3 `Host` may or may not be rewritten; `Origin` never is.** nginx's default
`proxy_pass http://127.0.0.1:8080` sends `Host: 127.0.0.1:8080`. cloudflared
and Caddy forward the public host. Browsers always send the public `Origin`
on the WebSocket handshake, with the default port omitted
(`https://myapp.example.com`, not `:443`). Matching must therefore be by full
origin, not by host plus Neel's port.

---

## 3. Public API

### 3.1 New `startApp` parameters

| Parameter | Default | Meaning |
|---|---|---|
| `serve` | `false` | serve mode: no browser, no idle exit, one virtual window |
| `allowedOrigins` | `@[]` | extra origins the app may be loaded from, e.g. `"https://myapp.example.com"`; serve mode only |

The `startApp` macro forwards unknown keyword arguments to `runApp` already
(`neel.nim` 443–444), so only `runApp`'s signature changes.

### 3.2 Validation (at startup, before anything is bound)

Each of these raises `ValueError` with a message naming the parameter:

- `serve = true` with `port = 0`. A tunnel or proxy needs a fixed port.
- `allowedOrigins` non-empty without `serve = true`.
- An `allowedOrigins` entry that is not `http://host[:port]` or
  `https://host[:port]`: anything with a path (including a trailing `/`), a
  query, a fragment, user info, a wildcard, or another scheme.

A valid `host` is ASCII letters, digits, `-`, `.`, and `_`, or a bracketed
IPv6 literal (`[::1]`); a valid `port` is digits naming 1–65535. Also
rejected: surrounding whitespace (entries are not trimmed), an empty host or
port, and non-ASCII (browsers send an internationalized host in punycode, so
such an entry could never match).

Entries are normalized once: scheme and host lowercased, the port rewritten
as a plain integer (`:0443` is `:443`), and a default port (`:80` for
`http`, `:443` for `https`) removed, since browsers omit it. Entries that are
equal after normalization are kept once.

### 3.3 Ignored in serve mode

`browsers`, `fallback`, `browserPath`, `size`, `position`, `extraFlags`,
`gracePeriodMs`, `startupTimeoutMs`. They are accepted and ignored, as
documented (they cannot be detected reliably, since they have defaults).

### 3.4 New exports

- `NeelServeModeError = object of CatchableError`: raised by `openWindow` and
  `closeWindow` in serve mode. Reaches the page as a structured error when
  raised in an exposed proc.
- `CloseDisplaced* = 4000`: the close code a displaced connection receives
  (section 9). Documented for page code; `neel.onclose` reports it.

`ExitReason` gets no new member. A stop signal returns `erQuit` (decision:
keeps the change additive, since adding an enum member breaks exhaustive
`case` statements in user code).

### 3.5 Behavior: local mode vs. serve mode

| Aspect | Local mode (unchanged) | Serve mode |
|---|---|---|
| Browser | discovered and launched | never discovered or launched |
| Window 1 | opened in the browser at `startPath` | created by `startApp`, launches nothing |
| Exit | `quitApp()`, last window closed + grace period, or startup timeout | `quitApp()` or a stop signal (section 7) |
| Window retirement | after grace period / startup timeout | never |
| `openWindow` / `closeWindow` | as today | raise `NeelServeModeError` |
| `onWindowOpen` | first connection of a window | first connection ever (once) |
| `onWindowClose` | close, retirement, teardown | teardown only (once, at exit) |
| Accepted `Host` | `127.0.0.1:<port>` | that, or the host of an allowed origin |
| Accepted `/ws` `Origin` | `http://127.0.0.1:<port>` | that, or an allowed origin |
| Cross-site requests | refused | refused, except top-level document navigations |
| `GET /` (and `HEAD /`) when `startPath`'s path is not `/` | serves `index.html` | 302 to `startPath` |
| `/neel/no-browser` | the no-browser page | 404 |
| WebSocket pings | none | every 30 s on idle connections |
| Startup line on stdout | none | always (section 6) |
| Shim after giving up reconnecting | terminated until reload | dormant; retries when the page becomes visible or goes online |

---

## 4. Request filtering (`frontend.nim`)

`requestRefusal(req, port, filter)` takes the server's bound port (read per
request, as before: with `port = 0` it is only known once `listen` has
started the IO thread) and a small immutable filter value built once by
`runApp`, before `listen`, with `initRequestFilter(serve, allowedOrigins)`:

```nim
type RequestFilter* = object
  serve*: bool
  origins*: seq[string]   # normalized allowed origins
  hosts*: seq[string]     # host[:port] of each origin, derived once
```

`initRequestFilter` normalizes each entry with `normalizeOrigin` (section
3.2), which raises `ValueError`. It does not check the `serve` / `port`
combinations of section 3.2; `runApp` does. The zero value (and
`initRequestFilter(serve = false)`) is local mode; a non-serve filter
ignores its `origins` and `hosts`.

Rules, in order (the first failure is the 403 reason):

1. **Host.** Accept `127.0.0.1:<port>` (and bare `127.0.0.1` on port 80, as
   today). In serve mode, also accept an exact match in `hosts`. A missing
   `Host` is refused.
2. **Cross-site.** `Sec-Fetch-Site: cross-site` is refused, except in serve
   mode when the request is a top-level document navigation:
   `Sec-Fetch-Mode: navigate` **and** `Sec-Fetch-Dest: document`.
   - Local mode keeps today's rule unchanged.
   - Requiring `Sec-Fetch-Dest: document` keeps cross-site **iframes** out:
     a framed app could be clickjacked into calling exposed procs, and its
     shim would displace the user's real page.
   - A request without the header (older browsers) passes, as today.
3. **Origin on `/ws`.** Accept `http://127.0.0.1:<port>`. In serve mode, also
   accept an exact match in `origins`. A missing `Origin` is refused.

The 403 texts are today's in local mode, and in serve mode without allowed
origins. In serve mode with allowed origins, the `Host` and `Origin` texts
end in `or the host of an allowed origin` / `or an allowed origin`; they
never list the origins.

The guarantee this preserves: no other website can obtain the token or open
the WebSocket. Cross-site script loads of `/neel.js` are still refused (their
`Sec-Fetch-Dest` is `script`), and `/ws` still requires an exact origin.

The SSH port-forward case needs no allowed origins: the browser on the laptop
loads `http://127.0.0.1:8080`, which passes rules 1 and 3 as they are.

---

## 5. Window model and lifecycle (`window.nim`)

### 5.1 The virtual window

No special record type. `initWindows` gains `serve: bool`, and `runApp`
passes a launcher that launches nothing:

```nim
proc noLaunch(url, userDataDir: string; opts: LaunchOptions): BrowserHandle
    {.gcsafe.} = nil
```

`runApp` creates window 1 through a private entry point that shares
`openWindow`'s code (`openVirtualWindow`, exported by `window.nim` but not
re-exported by `neel`), so the record goes through the normal path. A `nil`
handle is already the "not launched" state: `finishHandle(nil)` is a no-op.
In serve mode the shared code names and clears no profile directory (the
record's `userDataDir` is empty; `clearStaleUserDataDir` is not called).
The public `openWindow` and `closeWindow` check `m.serve` first and raise
`NeelServeModeError` (before an id is allocated; `closeWindow` raises for
any id). `initWindows(serve = true)` skips the `gracePeriodMs` /
`startupTimeoutMs` assertions, since serve mode ignores both.

### 5.2 `waitForAppExit` in serve mode

Returns only `erQuit`: when `quitRequested` is set, or when the stop flag
(section 7) is set. The per-window retirement loop (`window.nim` 606–640)
and both idle exits (645–656) are skipped entirely. It still waits on the
condition variable with the `IdleTickMs` bound, so a stop flag set by a
signal handler is noticed within a second.

### 5.3 Hooks

- `onWindowOpen` fires once, when the first connection ever binds to window
  1. Later devices, refreshes, and reconnects do not fire it: the server
  cannot tell them apart, since all three are a new connection binding to
  window 1. Pages should request their initial state with a `neel.<name>()`
  call, as the guide already recommends.
- `onWindowClose` fires once, during teardown (`teardownWindows`).

### 5.4 Displacement

Unchanged logic in `bindConnection`, but the displaced connection is closed
with `CloseDisplaced` (4000) instead of `CloseNormal` (section 9). This
applies in both modes.

A known consequence, documented rather than changed: `js` resolves a window
to its current connection at call time, so an exposed proc started by the
displaced device that calls `js.foo(...)` afterwards reaches the new device.

---

## 6. `runApp` (`neel.nim`)

In serve mode, `runApp`:

1. validates the parameters (section 3.2);
2. skips `findBrowser` (no `NeelBrowserError` from a stale `browserPath`, no
   probing on a machine without a browser);
3. builds the `RequestFilter` and stores it in `AppState` (written once
   before `listen`, read by workers, like the other fields); the bound port
   is not part of it and is passed to `requestRefusal` per request
   (section 4);
4. creates the server with the ping interval (section 8);
5. calls `initWindows(..., serve = true, launcher = noLaunch)` and creates
   window 1 at `startPath` (section 5.1);
6. installs the stop-signal handlers (section 7);
7. prints the startup line to stdout, in debug and release builds:
   `neel: serving http://127.0.0.1:8080 (allowed origins: https://myapp.example.com)`,
   or `(allowed origins: none)`. Writing is wrapped like `debugLog`, so an
   app without a console (`--app:gui`) does not fail;
8. `waitForAppExit`, then the usual `shutdown`;
9. removes the signal handlers;
10. skips the profile sweep (serve mode never creates profiles).

Routing changes in serve mode: `GET /` (and `HEAD /`) returns
`302 Location: <startPath>` when the path part of `startPath` (before any
`?` or `#`, with a leading `/` added as `launchUrl` does) is not `/`;
`Location` is that normalized `startPath`, query and fragment included. A
`startPath` such as `/?tab=2` or `/#x` is not redirected to, since the
browser would land on `/` again and loop; `/` then serves `index.html`.
`/neel/no-browser` is a 404.

The parameter checks (item 1 of the list above) run first in `runApp`, before the web
directory check and before `AppState` is written, so a refused start leaves
nothing behind and a later `startApp` works. The `testhooks` launcher is
ignored in serve mode (`noLaunch` is always used); the `testhooks` sweep is
never called.

---

## 7. Stop signals (new module `neel/signals.nim`)

Installed only in serve mode, for the duration of `runApp`, and removed
(previous handlers restored) before `runApp` returns. The handler never calls
`quitApp()`: that takes a lock and signals a condition variable, which is not
safe in a signal handler. It only sets an atomic stop flag that
`waitForAppExit` checks on every wake-up (at most every `IdleTickMs`).

As built (step 4): the flag is a module-level atomic in `window.nim`
(outside the `WindowManager`, which `teardownWindows` frees while the
handlers are still installed), set by `window.requestStop()` (returns
whether it was already set) and cleared by `initWindows`. Only the serve
wait (`waitForQuit`) reads it; local mode ignores it. `runApp` installs the
handlers right after window 1 exists, and after `shutdown` (in a nested
`finally`, so also when the run raised) reports shutdown finished and then
removes them. `neel/signals` is not re-exported.

**Linux and macOS:** `SIGINT` and `SIGTERM` (`sigaction` from `std/posix`,
`SA_RESTART`, empty mask). A second signal while the flag is already set
exits immediately with `_exit(130)` for `SIGINT` / `_exit(143)` for
`SIGTERM`, so a hung shutdown can always be interrupted. Removal restores
the exact saved `sigaction` of both signals: for `SIGINT` that is Nim's own
handler, or whatever `setControlCHook` installed (16.1).

**Windows:** `SetConsoleCtrlHandler` (imported from `kernel32`), handling
`CTRL_C_EVENT`, `CTRL_BREAK_EVENT`, `CTRL_CLOSE_EVENT`, `CTRL_LOGOFF_EVENT`,
and `CTRL_SHUTDOWN_EVENT`. The handler runs on a new thread. Handlers are
called last registered first and `TRUE` ends the chain, so ours pre-empts the
C runtime's (which runs Nim's `SIGINT` handler); "restoring" is removing ours
from the chain, which brings the earlier handlers back untouched. Other event
types return `FALSE`.

- Ctrl-C and Ctrl-Break: set the flag and return `TRUE`. There is no
  second-signal exit on Windows; a hung shutdown is ended by closing the
  console window (next item).
- Close, logoff, shutdown: Windows terminates the process as soon as the
  handler returns (or after its own timeout of a few seconds). The handler
  sets the flag, then waits, bounded to `ShutdownWaitMs` = 4 s, for `runApp`
  to report that shutdown has finished, then returns `TRUE`. Code after
  `startApp` may not run in this case; documented. The report is a
  manual-reset kernel event (created once, never closed, reset at install,
  set after `shutdown`) that the handler waits on with `WaitForSingleObject`.
- Logoff and shutdown reach the handler only while the process has not
  loaded `user32.dll` or `gdi32.dll` (Windows rule for console apps). Neel
  loads neither; an app that does (a GUI library) is killed at logoff
  without a clean shutdown. Documented in step 7.

Running as a Windows service is out of scope for v1. Service wrappers that
send Ctrl-C to the console (NSSM does by default, to be confirmed in testing)
work through the Ctrl-C path. A process started with
`CREATE_NEW_PROCESS_GROUP` has Ctrl-C disabled by Windows and only sees
Ctrl-Break (16.1).

---

## 8. Keep-alive pings (`server.nim`)

`newServer` gains `pingIntervalMs = 0` (0 = off, the default, so local mode
and the existing server tests are unaffected). `runApp` passes
`PingIntervalMs = 30_000` in serve mode: below nginx's 60 s and Cloudflare's
reported 100 s.

- Each upgraded connection records the time of its last read or write (IO
  thread only, no lock).
- The IO loop, which already walks connections for close deadlines, queues
  `encodePing()` on any `csWebSocket` connection idle for at least the
  interval, and lowers its `select` timeout accordingly (bounded by
  `IoTickMs` as today).
- Browsers answer pings automatically; pongs are already accepted and
  ignored (`server.nim` 514–526). No `neel.js` change is involved.
- Dead-peer detection (closing connections that do not answer) is deferred:
  serve mode has no exit to trigger, and the next displacement or reconnect
  cleans up.

This touches the module with platform branches (Windows sockets, `select` on
Windows, kqueue on macOS, epoll on Linux), but only through the existing queue
and flush paths.

---

## 9. The displaced close code

- `CloseDisplaced* = 4000` lives in `frontend.nim`, next to the other
  constants shared with the shim. Its `static:` block checks that `neel.js`
  uses the same number, as it already does for the query parameter names.
- `bindConnection` closes a displaced connection with `CloseDisplaced` and
  the reason `"displaced by another connection"` (both modes).
- The shim treats 4000 as final, like 1000 and 1001. **This is required:**
  any other unknown code makes the shim reconnect, and two open devices would
  then displace each other forever.
- `neel.onclose(fn)` receives `4000`, so a page can show "Opened on another
  device" with a button that reloads the page to take the session back.

No version skew is possible: the shim is compiled into the same binary
(`staticRead`), so server and shim always agree.

---

## 10. Shim changes (`neel.js`)

**10.1 Close codes.** `ws.onclose` terminates on 1000, 1001, and 4000, in
one branch: a 4000 close rejects pending and later calls with
`neel: server closed the connection (close code 4000)`, like 1000 and 1001,
and `onclose` receives `(4000, false)`. The shim names the code
`CLOSE_DISPLACED`.

**10.2 Serve flag.** A fourth placeholder, `__NEEL_SERVE__`, rendered as
`true` / `false` by `renderNeelJs`. The `static:` checks in `frontend.nim`
are updated (four placeholders, each exactly once). Not exposed on `neel`, so
`Object.keys(neel)` is unchanged.

**10.3 Dormant instead of terminated (serve mode only).** When the shim runs
out of reconnect attempts:

- local mode: unchanged (terminated permanently);
- serve mode: the shim becomes *dormant*. Pending and queued calls are
  rejected and `onclose(code, false)` fires, exactly as today, and new calls
  reject at once with `NeelDisconnectedError`. Unlike terminated, a dormant
  shim reconnects, with attempts reset, when `document.visibilityState`
  becomes `"visible"` or the window fires `online`. On success it behaves as
  a normal reconnect (`onreconnect` fires, calls work again).
- Deliberate closes (1000, 1001, 4000, `neel.close()`) still terminate
  permanently in both modes.
- `neel.ready`, once rejected, stays rejected (a Promise cannot be
  re-resolved); pages that may sleep should use `onreconnect`.

**10.4 Server restarts.** A restart changes the token, so a dormant shim's
reconnects get a 403 until the page reloads. The guide documents an
app-level recipe: reload on a 1001 close, or when a dormant shim's wake-up
attempt gives up. **Never reload on 4000**, or two devices loop. A stable token
across restarts would remove the need for this; deferred (section 15).

---

## 11. Effect on local mode

Only one observable difference: a displaced local connection (a duplicated
tab, or a stale page refreshed against a fixed port) now receives close code
4000 instead of 1000. The shim's behavior is identical (final, no
reconnect); only the code reported to `neel.onclose` changes. The guide's
caveat about fixed ports is updated accordingly.

Everything else is behind `serve`: pings default to off, the cross-site
exception and allowed origins apply only in serve mode, the shim renders
`serve = false`, and the window lifecycle is unchanged.

---

## 12. Security model (guide text)

> In serve mode, Neel trusts whoever can reach the server. Put it behind a
> private tunnel (Tailscale, WireGuard, an SSH port forward) or an
> authenticating proxy (Cloudflare Access, Authelia, oauth2-proxy). Neel's own
> checks keep other websites in the user's browser out: the WebSocket only
> accepts the exact origins you list, `/neel.js` (which carries the token) is
> not served to other sites, and the app cannot be framed by another site.
> They do not authenticate the user.

Additional notes for the guide:

- Only list origins you control; never a shared or wildcard domain.
- Cross-site top-level navigations are allowed so that links and login
  redirects work. Pages should therefore not perform actions based on URL
  parameters alone (`/?action=delete`) without user confirmation.
- Another site can open the app in a new tab, which displaces the user's
  current page. It cannot read or control that tab. Accepted as low risk.
- The HTTP server has request size limits (16 KiB headers, 1 MiB body) but no
  idle timeout for plain HTTP connections. Always put a real proxy or tunnel
  in front; do not expose the port directly.
- Proxy-specific notes: nginx needs explicit WebSocket headers
  (`proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection
  "upgrade";`). Cloudflare quick tunnels (`trycloudflare.com`) get a new
  hostname every run, so they need a matching `allowedOrigins` each time.

---

## 13. Build steps

### 13.0 How to work a step

One step per session, in order (each step lists what it depends on).

1. Read this spec fully, including section 16 (findings, deviations,
   gotchas), then the modules the step touches.
2. Implement only that step. Do not start the next one or refactor unrelated
   code. If the spec conflicts with the code or is unclear, stop and ask; do
   not silently pick one.
3. Run `nimble test` and `nim c src/neel.nim`, and note the Nim version
   (`nim -v`).
4. Update the step below: set **Status** to `done` (or `partial` with what is
   missing), fill in **Notes** (deviations from the spec, in one or two lines
   each), list the manual checks the user still has to run for this step, and
   confirm or correct its **Cross-OS** line (see "Cross-OS testing" below).
5. Log anything a later step needs in section 16: a dated finding, a
   deviation that changes the spec (also edit the spec section it changes, so
   the spec stays the truth), or a new gotcha.
6. Do not commit unless the user asks.

Every step leaves local mode working and `nimble test` green.

**Cross-OS testing.** There is no CI. Testing on other machines is batched,
with one early checkpoint where the code is platform-specific:

- **Every session (macOS):** `nimble test` and `nim c src/neel.nim` run in
  the session itself, on the user's Mac.
- **Checkpoint after step 5 (Windows and Linux):** the user runs
  `nimble test` on both, plus the Windows signal checks (Ctrl-C, Ctrl-Break,
  closing the console window) with any serve-mode app. Steps 4 and 5 are the
  only steps with platform branches (`sigaction` / `SetConsoleCtrlHandler`;
  Windows `select`, kqueue, epoll), and Windows is where cross-thread memory
  bugs have shown up before. Checking here keeps a failure attributable to
  two steps instead of six.
- **Final pass after step 7 (all three OSes):** the full 13.8 matrix,
  including the examples, the browser checks, proxies, and the phone. The
  manual checks listed in each step are the input to this pass, not a to-do
  after every step.
- **Commit after each step** (when the user asks), so a failure found late
  can be bisected to a step.
- **From step 4 on (user's plan, 2026-10-15):** the user runs `nimble test`
  on macOS, Windows, and Linux (Ubuntu in VirtualBox) after every step, not
  only at the checkpoints. The session still runs it on its own machine; the
  step's entry records which OSes the user has confirmed. The checkpoint and
  final-pass manual checks are unchanged.

Each step entry has a **Cross-OS** line: `safe to defer` (covered by the
final pass) or `checkpoint` (needs a Windows/Linux run before the final
pass), with the reason. A session that adds platform branches
(`when defined(windows)` / `when defined(posix)`), OS APIs, or new state
shared between threads in a step marked `safe to defer` changes the line to
`checkpoint`, says why, and tells the user in its summary.

### 13.1 Step 1: request filtering

- **Status:** done (2026-10-14; `nimble test` and `nim c src/neel.nim` green
  on macOS 13 with Nim 2.2.12, which Nimble also used:
  `~/.nimble/bin/nim`)
- **Depends on:** nothing
- **Touches:** `frontend.nim`; the `handleRequest` call site in `neel.nim`
- **Spec:** sections 3.2 (origin validation and normalization), 4
- **Cross-OS:** safe to defer. Pure string logic, no platform code, no new
  threads; the filter is written once on the main thread and freed there.

Scope:
- `RequestFilter`, the origin validation/normalization proc, and the new
  `requestRefusal` rules, all pure.
- `neel.nim` builds a local-mode filter (`serve = false`, no origins) so
  behavior is unchanged. The `serve` / `allowedOrigins` parameters are wired
  in step 2.

Tests (`t_frontend`):
- allowed origin accepted on `/ws`; port mismatch, scheme mismatch, and
  trailing slash refused or rejected at validation as specified; mixed-case
  input normalized;
- `Host` rewritten to `127.0.0.1:<port>` with a public `Origin` accepted;
- serve mode: cross-site `navigate` + `document` passes; cross-site
  `navigate` + `iframe` refused; cross-site `script` for `/neel.js` refused;
- local mode: every existing case unchanged, including cross-site
  navigations refused;
- validation errors for each malformed origin form in 3.2.

**Notes:**
- The bound port is not in `RequestFilter`; the signature is
  `requestRefusal(req, port, filter)` (deviation, 16.2). Sections 4 and 6
  updated.
- Origin validation follows the strict reading confirmed with the user
  (allowed host characters, port range, no trimming, no non-ASCII); section
  3.2 updated.
- Built: `RequestFilter`, `normalizeOrigin`, `initRequestFilter` in
  `frontend.nim`; `neel.nim` stores `initRequestFilter(serve = false)` in
  `AppState` and passes it at the `handleRequest` call site.
- Tests: `t_frontend` gains suites for normalization, filter construction,
  and serve-mode rules. Local mode is proven by an equivalence test against
  a verbatim copy of the old rules over ~19,000 header combinations; a
  mutation that drops the `serve` guard fails it. `t_neel` adds an end-to-end
  check that a cross-site top-level navigation is still refused locally.

Manual checks (deferred to the final pass, 13.0):
- `nimble test`: passed on macOS in this session; Windows and Linux are
  covered by the checkpoint after step 5.
- Local mode: the three examples behave as before (open, call, second
  window, close, exit after the grace period). No serve-mode manual check
  exists for this step: serve-mode filtering is not reachable from
  `startApp` until step 2.

### 13.2 Step 2: serve core

- **Status:** done (2026-10-15; `nimble test` and `nim c src/neel.nim` green
  on **Windows 11** (win32 10.0.26200) with Nim 2.2.12. `nim` on PATH is
  `~/.nimble/bin/nim.exe`; Nimble compiled with
  `~/.nimble/pkgs2/nim-2.2.12-1ce02ec.../bin/nim.exe`, also 2.2.12. The user
  then ran `nimble test` on macOS the same day: passed. Linux not yet run.)
- **Depends on:** step 1
- **Touches:** `window.nim`, `neel.nim`
- **Spec:** sections 3, 5, 6 (except signals, pings, and the shim)
- **Cross-OS:** safe to defer (confirmed). No platform branches and no OS
  APIs. The only new state shared between threads is `WindowManager.serve`,
  written once in `initWindows` before any worker runs; the serve wait reuses
  the existing lock, condition variable, and `quitRequested`. `nimble test`
  has passed on Windows (in the session) and macOS (run by the user); Linux
  is covered by the step-5 checkpoint.

Scope: `serve` and `allowedOrigins` parameters and their validation; skip
`findBrowser`; the no-op launcher and window 1; `waitForAppExit` serve
branch; `NeelServeModeError`; `GET /` redirect; `/neel/no-browser` 404;
startup line; no profile sweep.

Tests (`t_window`, `t_neel`):
- window 1 exists after start, with no launch;
- window 1 survives past `startupTimeoutMs` without a connection, and past
  `gracePeriodMs` after a disconnect;
- `quitApp()` returns `erQuit`;
- `openWindow` / `closeWindow` raise `NeelServeModeError`;
- `onWindowOpen` fires once across two connections; `onWindowClose` fires
  once at teardown;
- `GET /` redirects when `startPath != "/"`; `/neel/no-browser` is a 404;
- `port = 0`, and `allowedOrigins` without `serve`, raise `ValueError`.

**Notes:**
- Serve-mode `GET /` redirects only when the path part of `startPath` is not
  `/` (agreed with the user; the literal rule loops for `/?tab=2` or `/#x`).
  `HEAD /` follows `GET /`. Sections 3.5 and 6 updated (16.2).
- Serve mode names and clears no profile directory for window 1 (agreed
  with the user). `initWindows(serve = true)` skips the grace-period and
  startup-timeout assertions, since serve mode ignores both. Section 5.1
  updated (16.2).
- Built: `NeelServeModeError` (re-exported), `noLaunch`,
  `openVirtualWindow` (not re-exported), `initWindows(serve)`, and the serve
  branch of `waitForAppExit` (`waitForQuit`) in `window.nim`. `runApp`
  gained `serve` and `allowedOrigins`, plus `checkServeParams`, the `/`
  redirect, the `/neel/no-browser` 404, the startup line (`printLine`, stdout,
  flushed, `IOError` ignored), and skips `findBrowser`, the test launcher,
  and the sweep in serve mode. The doc comments for `startApp`, `runApp`,
  and both module headers now describe serve mode; the full documentation
  pass is still step 7.
- Tests: `t_window` gains the "window: serve mode" suite. It covers window 1
  with no launch and no profile dir (a stale `neel-<pid>-1` survives), outliving
  `startupTimeoutMs` and `gracePeriodMs`, `quitApp`, `NeelServeModeError`
  from both procs, `onWindowOpen` once across a displacement and a reconnect,
  `onWindowClose` once at teardown, the ignored timeouts, and a local-mode
  counterpart. `t_neel` gains a local run with `startPath = "/sub/page.html"`
  (`/` still 200, no-browser page 200, open/close/quit, sweep runs) and the
  "neel: serve mode" suite: the three `ValueError` refusals, each with nothing
  launched, swept, or bound; a full serve run (no launch even with a
  nonexistent `browserPath`, the redirect, 404, public `Host`, cross-site
  login navigation, refused iframe, three devices on window 1, structured
  `NeelServeModeError`, survival past both timeouts, `quitApp`, no sweep);
  and the redirect loop guard. The public-surface test checks
  `NeelServeModeError` is exported and `noLaunch` / `openVirtualWindow` are
  not.
- The startup line is printed into the `nimble test` output (one line per
  serve run in `t_neel`). Its format is not asserted automatically: stdout
  cannot be captured portably in-process. Checked by eye in this session
  (normalized origins, comma-separated).

Manual checks (deferred to the final pass, 13.0):
- `nimble test` on Linux (Windows and macOS passed on 2026-10-15).
- A small serve app (`startApp(serve = true, port = 8080)`, optionally with
  `startPath = "/other.html"` and an `allowedOrigins` entry): no browser
  opens; the startup line appears on stdout; `http://127.0.0.1:8080/`
  redirects to `startPath` and the page works; closing the tab and waiting
  longer than the grace period (and the startup timeout, without opening
  it) does not end the app; `/neel/no-browser` is a 404; a second tab takes
  over the first (close code 1000 until step 3); `quitApp()` from the page
  ends it. Until step 4, Ctrl-C ends the process without Neel's shutdown.
- Windows: the same app built with `--app:gui` starts and serves (the
  startup-line write must not fail).
- Local mode: the three examples behave as before.

### 13.3 Step 3: displaced close code

- **Status:** done (2026-10-15; `nimble test` and `nim c src/neel.nim` green
  on **Windows 11** (win32 10.0.26200) with Nim 2.2.12. `nim` on PATH is
  `~/.nimble/bin/nim.exe`; Nimble compiled with
  `~/.nimble/pkgs2/nim-2.2.12-1ce02ec.../bin/nim.exe`, also 2.2.12. macOS
  and Linux not run for this step.)
- **Depends on:** step 2
- **Touches:** `frontend.nim`, `window.nim`, `neel.js`; `neel.nim` (the
  re-export and `appClose`)
- **Spec:** section 9, 10.1, 11
- **Cross-OS:** safe to defer (confirmed). A constant, a close reason, and a
  shim branch: no platform branches, no OS APIs, no new state shared between
  threads (`CloseProc` gained a parameter; the reason is a constant passed
  through the existing `Server.close`). Browsers handle close code 4000 the
  same on every OS. The two-tab checks run in the final pass.

Tests: displacement sends 4000 (the `t_window` fake close records the
code); the `frontend.nim` static check ties `CloseDisplaced` to `neel.js`.
Manual: two tabs, the first reports 4000 and does not reconnect.

**Notes:**
- `CloseProc` gained a `reason: string` parameter, so `bindConnection` can
  send `"displaced by another connection"`; `closeWindow` passes `""` (its
  frame is byte-identical to before). `neel.nim`'s `appClose` forwards it.
  Agreed with the user (16.2).
- The shim treats 4000 in the existing 1000/1001 branch, so calls reject with
  `neel: server closed the connection (close code 4000)` and `onclose` gets
  `(4000, false)`. Agreed with the user; section 10.1 updated.
- Built: `CloseDisplaced* = 4000` in `frontend.nim` (re-exported by `neel`),
  with a `static:` check that `neel.js` defines `const CLOSE_DISPLACED =
  4000;` exactly once (a mutation to 4001 fails the build, checked in this
  session); `CLOSE_DISPLACED` in the shim's final-close branch and its header
  comments; `bindConnection` closes with `CloseDisplaced` and the reason, in
  both modes.
- Tests: the three displacement assertions (16.3) now expect 4000 and the
  reason: `t_window` "a reconnect re-associates..." (local) and the serve
  hooks test, the `t_window` integration test (on the wire, code and reason;
  its `closeWindow` frame is checked as 1000 with no reason), and `t_neel`'s
  serve run. New: `t_window` "a displaced connection gets 4000; closeWindow
  still sends 1000 to the new one"; `t_frontend` checks the constant, that
  4000 is a valid wire code, the definition, and that the only close-code
  comparison in the shim is the terminating branch with all three codes;
  `t_neel`'s local run 3 now covers, end to end through `startApp`, a
  duplicated tab displaced with 4000 and the reason, a connected second
  window closed by `closeWindow` with 1000, and `quitApp` with 1001; the
  public-surface test checks `neel.CloseDisplaced == 4000` (qualified, so the
  test's own `neel/frontend` import cannot satisfy it).
- The rendered shim passes `node --check` (syntax only; no JS test runner is
  a dependency).
- Not changed here, for step 7: `docs/GUIDE.md` (the `neel.onclose` row and
  the fixed-port caveat still say 1000) and the `examples/stresstest` page,
  which says the displaced window reports "close code 1000" (16.1;
  section 14 updated).

Manual checks (deferred to the final pass, 13.0):
- `nimble test` on macOS and Linux (Windows passed in this session).
- Serve mode: open the app in two tabs. The first tab's `neel.onclose`
  reports `(4000, false)`, its calls reject with `NeelDisconnectedError`, and
  DevTools shows no further `/ws` attempts from it. Reloading it takes the
  session back and displaces the second tab the same way (once, not in a
  loop).
- Local mode, fixed port (`examples/stresstest` with `./stresstest 8765`):
  open `http://127.0.0.1:8765/?window=1` in a normal browser tab. The app
  window is displaced with 4000 and does not reconnect; everything else
  (`closeWindow`, quit, the grace-period exit) behaves as before.

### 13.4 Step 4: stop signals

- **Status:** done (2026-10-15; `nimble test` and `nim c src/neel.nim` green
  on **Windows 11** (win32 10.0.26200) with Nim 2.2.12. `nim` on PATH is
  `~/.nimble/bin/nim.exe` (choosenim toolchain 2.2.12); Nimble compiled with
  `~/.nimble/pkgs2/nim-2.2.12-1ce02ec.../bin/nim.exe`, also 2.2.12. The POSIX
  branch was **type-checked only** (`nim check --os:linux` and
  `--os:macosx`), never compiled to C or run: the POSIX signal tests run for
  the first time on the user's Mac and Linux machines. User-confirmed OSes:
  none yet.)
- **Depends on:** step 2
- **Touches:** new `signals.nim`, `window.nim` (stop flag), `neel.nim`; new
  `tests/t_signals.nim`
- **Spec:** section 7
- **Cross-OS:** checkpoint (confirmed), to run **before step 5** under the
  every-step plan (13.0), not only at the post-step-5 checkpoint. Entirely
  platform-specific (`sigaction`; `SetConsoleCtrlHandler`, whose handler runs
  on a thread Windows creates), and it adds state shared between threads:
  the stop flag (written from a handler on any thread, read by the main
  thread) and the Windows shutdown event (set by the main thread, waited on
  by the handler thread). macOS and Linux: `nimble test` (first run of the
  POSIX signal tests) plus the `kill -TERM`, Ctrl-C, and second-signal checks
  below. Windows: `nimble test` plus the Ctrl-C, Ctrl-Break, and console-close
  checks below.

Tests: on Linux/macOS, send `SIGTERM` to the process during a serve-mode run
and expect `erQuit`; handlers are restored after `startApp` returns. Windows:
manual (Ctrl-C, Ctrl-Break, closing the console window).

**Notes:**
- No behavior deviations from section 7. Section 7 now records what was
  built: where the flag lives and how it is cleared, Windows restore =
  removing our handler from the chain, no second-signal exit on Windows
  (as specified), the kernel event behind "shutdown finished", and the
  `user32` / `gdi32` limit on logoff and shutdown events.
- Handler code is frame-free: `std/atomics` wrappers carry stack-trace frames
  (thread-local state) in debug builds, so the stop flag uses the GCC/Clang
  `__atomic` builtins (other compilers fall back to `std/atomics`), the
  Windows wait uses a kernel event, and the handlers are compiled with
  `stackTrace: off`. Checked in the generated C (16.1).
- Built: `neel/signals.nim` (`installStopHandlers`, `reportShutdownFinished`,
  `removeStopHandlers`, `stopHandlersInstalled`; on Windows the exported
  `onConsoleCtrl`, the `Ctrl*Event` constants, and `ShutdownWaitMs` for
  tests); `window.requestStop()` and the stop flag check in `waitForQuit`;
  `runApp` installs after `openVirtualWindow`, and its `finally` became
  `try: shutdown finally: report; remove`, so a raising shutdown still
  restores the handlers. Doc comments for `runApp` and the `neel.nim` and
  `window.nim` headers mention stop signals; the guide is step 7.
- Tests: `t_signals` (new): install/remove bookkeeping and double install
  (all OSes); POSIX: actions replaced while installed and restored exactly,
  a `setControlCHook` hook and a custom `SIGTERM` handler restored and still
  working, real `SIGTERM` and `SIGINT` ending a serve wait; Windows: the
  handler called directly for Ctrl-C/Ctrl-Break (stop, `TRUE`), unknown
  events (`FALSE`, no stop), close released by the report, logoff/shutdown
  after a report, close without a report bounded by `ShutdownWaitMs`.
  `t_window`: `requestStop` from another thread ends the serve wait within
  `IdleTickMs`, before the wait at once, `initWindows` clears a stale
  request, local mode ignores it (still waiting past 1.3 s). `t_neel`: a new
  suite with POSIX `SIGTERM` and `SIGINT` sent to the process during a full
  serve run (`erQuit`, 1001 to the device, `onWindowClose` once, no sweep,
  actions identical before and after), and Windows Ctrl-C, Ctrl-Break, and
  console close through `onConsoleCtrl` (close returns only after `startApp`
  shut down, within `ShutdownWaitMs`); the three refusals plus a new
  taken-port refusal (fails inside the `try`) leave nothing installed and
  the actions unchanged; local run 3 installs nothing (state and POSIX
  actions checked during and after); the public-surface test checks none of
  the signal procs is exported by `neel`.
- Ad hoc on Windows (not in the repo): a real Ctrl-Break, sent with
  `GenerateConsoleCtrlEvent` to a serve app started in its own process
  group, ended it with `erQuit` and exit code 0 after 168 ms.
- Found, not fixed (out of scope): on Windows two serve apps bind the same
  fixed port, because `server.nim` sets `SO_REUSEADDR` (16.1). Needs a
  decision.

Manual checks. Test app (for example `/tmp/sig/app.nim` with a `web/` folder
holding any `index.html`):

```nim
import std/os
import neel
proc logClose(w: Window) {.gcsafe.} =
  writeFile(getAppDir() / "closed.txt", "onWindowClose ran\n")
  if existsEnv("NEEL_HANG"): sleep(15_000)  # simulates a hung shutdown
echo "returned ", startApp(webDir = "web", serve = true, port = 8080,
                           onWindowClose = logClose)
```

- macOS and Linux: `nimble test` (the POSIX tests above run for the first
  time).
- macOS and Linux: run the app, open `http://127.0.0.1:8080`, press Ctrl-C
  once. Expect `returned erQuit`, `closed.txt` written, exit code 0
  (`echo $?`), and the page's `neel.onclose` reporting 1001 with no
  reconnect attempts.
- macOS and Linux: `kill -TERM <pid>` from another terminal. Same result.
- macOS and Linux: with `NEEL_HANG=1`, press Ctrl-C, wait for `closed.txt`
  to appear, press Ctrl-C again. Expect an immediate exit with code 130 and
  no `returned` line. With `kill -TERM` twice instead, exit code 143.
- Windows: `nimble test`.
- Windows: run the app in a console, press Ctrl-C. Expect `returned erQuit`,
  `closed.txt` written, `$LASTEXITCODE` 0. Then the same with Ctrl-Break.
- Windows: start the app in its own console (`start app.exe`, or a
  double-click), delete any old `closed.txt`, then close that console window
  with its X button. Expect the process to be gone within about 2 s and
  `closed.txt` written (the `returned` line may not appear: Windows ends the
  process once the handler returns).
- Local mode, any OS: Ctrl-C on a local-mode example still ends it the old
  way (Nim prints `SIGINT: Interrupted by Ctrl-C.`; no Neel shutdown).

### 13.5 Step 5: keep-alive pings

- **Status:** not started
- **Depends on:** step 2 (for the `runApp` wiring only)
- **Touches:** `server.nim`, `neel.nim`
- **Spec:** section 8
- **Cross-OS:** checkpoint (run right after this step). `server.nim` has a
  separate IO path per OS (Windows sockets and `select`, kqueue, epoll), and
  the ping tests are timing-based.

Tests (`t_server`, with a short interval such as 300 ms): an idle upgraded
connection receives a ping; an active one does not; `pingIntervalMs = 0`
sends none.

**Notes:**

### 13.6 Step 6: shim serve behavior

- **Status:** not started
- **Depends on:** steps 2 and 3
- **Touches:** `neel.js`, `frontend.nim`
- **Spec:** sections 10.2–10.4
- **Cross-OS:** safe to defer. Browser-side JS; the DevTools offline toggle
  and the phone run in the final pass.

Tests: rendering with the serve flag and the updated `static:` checks
(`t_frontend`). Manual: dormant and wake behavior with the DevTools offline
toggle, then on a phone.

**Notes:**

### 13.7 Step 7: documentation and example

- **Status:** not started
- **Depends on:** steps 1–6
- **Touches:** `README.md`, `docs/GUIDE.md`, module headers, new `examples/serve`
- **Spec:** sections 12, 14
- **Cross-OS:** triggers the final pass: the full 13.8 matrix on all three
  OSes, using `examples/serve`.

Scope: everything in section 14, plus an `examples/serve` app with run
instructions for an SSH forward and `cloudflared`. Proxy configs are
published only once verified on a real setup.

**Notes:**

### 13.8 Manual verification

Run by the user on each OS in the final pass after step 7 (13.0). The
checkpoint after step 5 fills in the `nimble test` row and the Windows
Ctrl-C / console rows early. Record results here (`pass`, `fail` with a
section 16 entry, or `n/a`).

| Check | macOS | Windows | Linux |
|---|---|---|---|
| `nimble test` passes | | | |
| Local mode: the three examples behave as before (open, call, second window, close, exit after the grace period) | | | |
| Local mode, fixed port: a browser tab at the app's URL displaces the app window (4000, no reconnect) | | | |
| Serve: starts without a browser, prints the startup line | | | |
| Serve: page loads at `http://127.0.0.1:<port>` | | | |
| Serve: a second tab displaces the first (4000, no reconnect) | | | |
| Serve: Ctrl-C exits cleanly | | | |
| Serve: `kill -TERM` exits cleanly | | n/a | |
| Serve: closing the console window exits cleanly | n/a | | n/a |
| Serve: idle behind a proxy for 5 minutes without a reconnect | | | |
| Serve: dormant shim wakes (DevTools offline toggle) | | | |

Once, on Linux (the realistic deployment target):

| Check | Result |
|---|---|
| Behind Cloudflare Tunnel with Access: first load after login works (confirms 2.1) | |
| Phone: open, lock for 5 minutes, unlock: the page reconnects by itself | |
| Server restart: the documented reload recipe recovers the page | |

---

## 14. Documentation

- **README:** a short "Serve mode" section after "Compilation" with the
  minimal example and a link to the guide.
- **Guide:** a "Serve mode" section covering: when to use it; `serve`,
  `allowedOrigins`, and the validation rules; the virtual window and
  displacement (code 4000); hooks; the security model (section 12); the
  reconnect behavior and the reload recipe; known-good proxy setups
  (cloudflared, Tailscale Serve, nginx, Caddy, SSH forward), each verified on
  a real setup before publishing.
- **Guide updates elsewhere:** `startApp` parameter table (two rows); the
  `neel.onclose` row (code 4000); the Caveats entry "Neither side closes an
  idle connection on its own" (true locally, not behind proxies); the fixed-
  port caveat (1000 becomes 4000).
- **Examples:** the "Refresh after a restart" item in
  `examples/stresstest/web/index.html` says the displaced window reports
  "close code 1000"; it is 4000 since step 3.
- **Module headers:** `neel.nim` route list, `frontend.nim` contract,
  `window.nim` lifecycle, `server.nim` surface.

---

## 15. Deferred

- **Stable token across restarts** (e.g. a `token` parameter or an
  environment variable), so pages reconnect after a restart without a reload.
- **Multi-window serve mode.** Nearly free with the no-op launcher (each
  `openWindow` just creates an addressable id); needs a URL story for
  devices and a decision about retirement.
- **Dead-peer detection** from missing pongs.
- **Compile-time warning** when `serve = true` is a literal and browser
  parameters are passed.
- **Frame-ancestor headers** (`Content-Security-Policy: frame-ancestors`) as
  a second layer behind the `Sec-Fetch-Dest` check, for browsers without
  Fetch Metadata.
- **Windows service integration** (service control handler).

---

## 16. Findings, deviations, and gotchas

The running log for the implementation. Newest entries last within each
list. A deviation that changes behavior is also applied to the spec section
it affects, so sections 1–12 always describe what is built.

### 16.1 Findings

Format: `YYYY-MM-DD, step N, platform: what was found; what it means`.

- 2026-10-14, pre-implementation, all: `Sec-Fetch-Site` is `cross-site` for
  any request whose redirect chain crossed sites (Fetch Metadata spec), so
  auth-proxy logins and links from other sites arrive cross-site. Basis for
  section 4 rule 2. Not yet observed live (checklist 13.8).
- 2026-10-14, pre-implementation, all: nginx closes idle proxied WebSockets
  after 60 s and recommends upstream pings; Cloudflare closes idle WebSockets
  (reported 100 s) and restarts edge servers. Basis for section 8 and 10.3.
- 2026-10-14, step 1, macOS: `server.listen` binds the socket, records the
  port, and starts the IO thread in one call, so with `port = 0` the bound
  port does not exist before requests can arrive. Anything that must be
  written before `listen` cannot hold it (see 16.2).
- 2026-10-14, step 1, macOS: in a sandboxed agent shell, `t_neel` fails with
  `OSError: Operation not permitted` from `startApp` and Nim cannot write
  `~/.cache/nim`; both are the sandbox, not Neel. Run `nimble test` without
  the sandbox (or with `--nimcache` under `/tmp` for single files).
- 2026-10-15, step 2, Windows: the session ran on Windows 11, not the Mac;
  `nimble test` passed there (the first Windows run of steps 1 and 2). The
  user then ran `nimble test` on macOS the same day and it passed, so steps
  1 and 2 are green on Windows and macOS; Linux is pending. On Windows, use `$env:TEMP` instead of `/tmp`
  for ad-hoc `--nimcache` and `-o:` paths. `nim c src/neel.nim` writes
  `src/neel.exe` (ignored by git; deleted after the check).
- 2026-10-15, step 2, Windows: a TCP connect to a closed loopback port takes
  about 2 s to fail on Windows (SYN retries), not instantly as on POSIX.
  Test probes for "nothing is listening" (`t_neel` `canConnect`) need a
  short connect timeout, or they stall the suite.
- 2026-10-15, step 3, Windows: the session ran on Windows 11 again;
  `nimble test` passed there. macOS and Linux have not run step 3.
- 2026-10-15, step 3, all: besides the guide (section 14), the
  `examples/stresstest` page tells the user the displaced window reports
  "close code 1000"; since step 3 it is 4000. Left for step 7 with the other
  documentation; section 14 now lists it.
- 2026-10-15, step 3, Windows: `node` is available on the session machine.
  `node --check` on a rendered shim (placeholders replaced by literals,
  written under `$env:TEMP`) is a quick syntax check after shim edits; there
  is still no JS test runner in the repo.
- 2026-10-15, after step 3, all: the user now has Ubuntu in VirtualBox and
  will run `nimble test` on all three OSes after every step from step 4 on
  (13.0). Steps 1–3 have not been run on Linux yet; the first Linux run
  covers them too.
- 2026-10-15, step 4, all: how Nim's runtime handles `SIGINT` (Nim 2.2.12,
  `lib/system/excpt.nim`). Unless built with `-d:noSignalHandler`, program
  start calls C `signal(SIGINT, signalHandler)` (also for SEGV, ABRT, FPE,
  ILL, BUS; `SIGPIPE` is ignored). That handler prints a stack trace and
  `SIGINT: Interrupted by Ctrl-C.`, then on POSIX resets to `SIG_DFL` and
  re-raises (the shell sees a SIGINT death), on Windows calls `quit(1)`.
  `setControlCHook(hook)` is just `signal(SIGINT, hook)`; `unsetControlCHook`
  puts `signalHandler` back. Nim installs nothing for `SIGTERM`. Consequences:
  on POSIX, saving the whole `sigaction` at install and restoring it at
  removal puts back Nim's handler or a user hook exactly (`t_signals` checks
  both). On Windows the C runtime implements `signal(SIGINT)` with its own
  console control handler, registered during Nim's startup; handlers run last
  registered first and `TRUE` ends the chain, so Neel's pre-empts it and
  removing Neel's restores it without touching it. Edge: a `setControlCHook`
  call made during a serve run is overwritten on POSIX when the run ends.
- 2026-10-15, step 4, all: `std/atomics` operations are generic Nim procs.
  In debug builds their instances carry stack-trace frames (`nimfr_`), so
  calling them pushes onto the thread-local `framePtr`. `{.push stackTrace:
  off.}` at the call site does not remove them. On Windows the console
  handler runs on a thread Nim did not create, where MinGW's emulated TLS
  allocates on first access. The handler paths therefore use the GCC/Clang
  `__atomic` builtins directly (in `window.nim`) and a kernel event (in
  `signals.nim`). The generated C of `requestStop` is a single
  `__atomic_exchange_n`; `onConsoleCtrl` calls only that and
  `WaitForSingleObject`.
- 2026-10-15, step 4, Windows: the session ran on Windows 11 again;
  `nimble test` passed. The POSIX branch was checked with `nim check
  --os:linux` / `--os:macosx` only. On a Windows host that works except for
  `startApp(embedAssets = true)` in `t_neel`: the compile-time `parentDir`
  uses the target's separator, so the Windows source path resolves to `.`.
  Check a copy with that run switched to disk assets.
- 2026-10-15, step 4, Windows: a real Ctrl-Break can be tested without a
  console: start the app with `CreateProcessW(..., CREATE_NEW_PROCESS_GROUP)`
  and call `GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, pid)` (PowerShell
  `Add-Type`; pass `[NullString]::Value`, not `$null`, for null strings).
  The serve app returned `erQuit`, exit 0. Ctrl-C cannot be tested this way:
  `CREATE_NEW_PROCESS_GROUP` disables Ctrl-C for that process, which also
  matters for service wrappers (section 7).
- 2026-10-15, step 4, Windows: two serve apps started on the same fixed port
  both bind and print the startup line, because `openListener` sets
  `SO_REUSEADDR`, which on Windows allows binding a port that is already
  listening (Windows wants `SO_EXCLUSIVEADDRUSE`). This existed before step 4
  but matters for serve mode, which always uses a fixed port. Not fixed; the
  user should decide whether a later step changes `server.nim`. `t_neel`'s
  `occupyPort` uses `SO_EXCLUSIVEADDRUSE` so its taken-port test is reliable.
- 2026-10-15, step 4, Windows: console apps that load `user32.dll` or
  `gdi32.dll` never receive `CTRL_LOGOFF_EVENT` / `CTRL_SHUTDOWN_EVENT`
  (Microsoft `SetConsoleCtrlHandler` docs). A Neel serve binary imports only
  `KERNEL32`, `msvcrt`, and `WS2_32`, and loads `Advapi32`, `Bcrypt`,
  `kernel32`, and `Ws2_32` at runtime (checked with `objdump -p` and the
  generated C), so it does receive them. Section 7 updated; for the step 7
  guide.

### 16.2 Deviations from the spec

Format: `YYYY-MM-DD, step N: what changed and why; spec sections updated`.

- 2026-10-14, step 1: `RequestFilter` has no `port` field and
  `requestRefusal` takes `(req, port, filter)`, with the port read from the
  server per request as before. The spec put the port in a filter written
  before `listen`, which is impossible for the default `port = 0` (16.1).
  Agreed with the user. Sections 4 and 6 (step 3) updated; the example in
  `.cursor/rules/tests.mdc` updated to the new signature.
- 2026-10-14, step 1: section 3.2 made precise (agreed with the user): host
  characters, port range 1–65535 and integer re-serialization, no trimming,
  non-ASCII rejected, duplicates kept once. Section 3.2 updated.
- 2026-10-15, step 2: serve-mode `GET /` redirects only when the path part
  of `startPath` is not `/`. The literal rule (`startPath != "/"`) sends
  `/?tab=2` or `/#x` into an endless redirect. `HEAD /` behaves like
  `GET /`. Agreed with the user. Sections 3.5 and 6 updated.
- 2026-10-15, step 2: in serve mode, window 1's record has an empty
  `userDataDir` and `clearStaleUserDataDir` is not called, so serve mode never
  touches profile directories. `initWindows(serve = true)` skips the
  grace-period and startup-timeout assertions, because "accepted and
  ignored" (3.3) must not fail on values local mode rejects. The profile
  part was agreed with the user. Section 5.1 updated.
- 2026-10-15, step 3: `window.CloseProc` is now
  `proc(conn: ConnId; code: int; reason: string): bool`, because section 9's
  close reason could not pass through the old `(conn, code)` signature.
  `closeWindow` passes `""` (its close frame is unchanged), and `neel.nim`'s
  `appClose` forwards the reason to `Server.close`, so step 3 also touches
  `neel.nim` beyond the re-export. Agreed with the user. The 13.3 Touches
  line updated.
- 2026-10-15, step 3: the shim's rejection message for a 4000 close is the
  existing `neel: server closed the connection (close code 4000)` (same
  branch as 1000/1001), not a displacement-specific one. Agreed with the
  user. Section 10.1 updated.

### 16.3 Gotchas

Rules every step must respect. The first entries come from the existing code.

- **Free memory on a live thread.** Nim's allocator cannot take a block back
  once the thread that allocated it has exited (the reason for Nim >= 2.2.12).
  State grown on the IO thread or a worker is freed while that thread is
  alive: the IO thread clears its own tables before parking (`server.nim`
  `ioLoop`), and shared state is freed in `shutdown`'s `beforeJoin`
  (`releaseSharedState` in `neel.nim`). New shared state follows the same
  pattern.
- **Never block the IO thread.** Pings go through the existing outbound queue
  and flush paths; no new waits on the IO thread.
- **Hooks never run under the window lock.** Collect under the lock, release,
  then call (see `connectionOpened`, `closeWindow`, `waitForAppExit`).
- **Every wait is bounded.** `waitForAppExit` waits at most `IdleTickMs`; the
  stop flag relies on that.
- **The shim and `frontend.nim` move together.** The `static:` block in
  `frontend.nim` checks the placeholders (count and names) and the shared
  constants against `neel.js`; update both in the same step.
- **`ExitReason` gains no members.** Stop signals return `erQuit` (section
  3.4).
- **Serve-mode integration tests need a known port.** Serve mode refuses
  `port = 0`, and `t_neel` currently learns the port from the fake launcher's
  URL, which serve mode never calls. Obtain a free port up front (bind an
  ephemeral socket, read the port, close it) and pass it.
- **Shipped comments are self-contained.** Code comments and doc comments
  never cite `SPEC.md`, step numbers, or this log; they state the constraint
  itself. (The 2.0 merge needed a cleanup commit for exactly this.)
- **`initRequestFilter` does not reject origins without `serve`.** A
  non-serve filter silently ignores its origins, so the section 3.2 checks
  (`allowedOrigins` without `serve`, `serve` with `port = 0`) must be done in
  `runApp` before the filter is built, or a misconfiguration goes unnoticed.
- **Host and Origin matching is exact and case-sensitive.** Browsers send
  both lowercased and without a default port, which is why entries are
  normalized; never compare against raw, unnormalized `allowedOrigins`.
- **Local-mode filtering has an oracle.** `t_frontend` keeps a verbatim copy
  of the pre-serve rules (`legacyRefusal`) and compares every local filter
  against it over a header grid. If a later step changes local filtering on
  purpose, change the oracle in the same step and say so in 16.2.
- **Serve-mode tests wait for window 1, not for the port.** `listen` runs
  before `openVirtualWindow`, so a request in between finds no window
  (`/neel.js` 404, `/ws` 403). `t_neel`'s `serveRun` waits for
  `windows().len == 1`; do the same in new serve-mode integration tests.
- **The serve wait is `waitForQuit` in `window.nim`.** It loops on
  `quitRequested` with `waitTimeout(..., IdleTickMs)`. A stop flag set by a
  signal handler (it cannot signal the condition variable) must be checked
  in that loop condition. It still returns `erQuit`.
- **Displacement close-code assertions live in several places.** Since step
  3 they expect `CloseDisplaced` and the reason `"displaced by another
  connection"`: `t_window` ("a reconnect re-associates...", "a displaced
  connection gets 4000; closeWindow still sends 1000...", and the "window:
  serve mode" hooks test), the `t_window` integration test, and `t_neel`'s
  local run 3 and serve run. A change to displacement updates all of them.
- **`CloseProc` carries a reason.** `t_window`'s `fakeClose` records
  `(conn, code, reason)` and `closes()` returns those triples; a new close
  call in `window.nim` passes an explicit reason (`""` for none).
- **`CloseDisplaced` is tied to the shim by text.** The `static:` block in
  `frontend.nim` looks for `const CLOSE_DISPLACED = 4000;` in `neel.js`, and
  `t_frontend` expects exactly one close-code comparison line in `ws.onclose`.
  Step 6's dormant logic must keep 4000 in that terminating branch, and keep
  it ahead of any dormant or reconnect path.
- **Serve mode ignores the `testhooks` launcher.** `runApp` always passes
  `noLaunch`, so a test that installs `setTestLauncher` and sees no launch is
  checking that nothing is launched, which is intended.
- **Signal tests wait for the handlers, not for window 1.** `runApp` installs
  the stop handlers after `openVirtualWindow`, so `serveRun`'s "window 1
  exists" does not mean they are in place. A `SIGTERM` sent in between hits
  the default action and kills the test process. Wait for
  `stopHandlersInstalled()` first, as `serveRunStoppedBy` does.
- **Read test sockets only after a signal was handled.** A signal can land on
  the test thread and interrupt `select`, which makes the tests' `recvSome`
  fall through to a blocking `recv`. Send the signal, wait for the run to end,
  then read the frames, which are already buffered.
- **Code reachable from a signal handler stays frame-free.** No
  `std/atomics` calls (they carry frames in debug builds), no exceptions, no
  allocation; wrap it in `{.push stackTrace: off.}` and check the generated C.
  This covers `window.requestStop` and everything in `signals.nim`'s
  handlers.
- **The stop request cannot wake the wait.** It is noticed only when
  `waitForQuit` next wakes, so stop latency is `IdleTickMs` (1 s). Keep that
  bound if the wait changes.
- **Handlers stay installed during `shutdown`.** On POSIX a signal during a
  hung shutdown is the "second signal" and exits at once; on Windows a
  console close during shutdown waits for the report. The order in
  `runApp`'s `finally` is `shutdown`, then `reportShutdownFinished`, then
  `removeStopHandlers`, and the last two run even if `shutdown` raises.
- **Windows tests call the console handler directly.**
  `GenerateConsoleCtrlEvent` with group 0 reaches every process on the
  console, including `nimble` and the shell. Tests call `onConsoleCtrl` on a
  thread of their own instead, and anything that needs a real console event
  goes in the manual checks.
