# Serve mode: specification

Status: draft, not yet implemented. Supersedes `DISCUSSION.md` and
`THOUGHTS.md`.

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
a live setup yet. Section 13 includes them in the manual test plan.

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

Entries are normalized once: scheme and host lowercased, and a default port
(`:80` for `http`, `:443` for `https`) removed, since browsers omit it.

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
| `GET /` with `startPath != "/"` | serves `index.html` | 302 to `startPath` |
| `/neel/no-browser` | the no-browser page | 404 |
| WebSocket pings | none | every 30 s on idle connections |
| Startup line on stdout | none | always (section 6) |
| Shim after giving up reconnecting | terminated until reload | dormant; retries when the page becomes visible or goes online |

---

## 4. Request filtering (`frontend.nim`)

`requestRefusal` takes a small immutable filter value built once by `runApp`,
for example:

```nim
type RequestFilter* = object
  port*: int
  serve*: bool
  origins*: seq[string]   # normalized allowed origins
  hosts*: seq[string]     # host[:port] of each origin, derived once
```

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
`openWindow`'s code, so the record goes through the normal path. A `nil`
handle is already the "not launched" state: `finishHandle(nil)` is a no-op
(`window.nim` 180). The public `openWindow` and `closeWindow` check `m.serve`
first and raise `NeelServeModeError`.

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
   before `listen`, read by workers, like the other fields);
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

Routing changes in serve mode: `GET /` returns `302 Location: <startPath>`
when `startPath != "/"`; `/neel/no-browser` is a 404.

---

## 7. Stop signals (new module `neel/signals.nim`)

Installed only in serve mode, for the duration of `runApp`, and removed
(previous handlers restored) before `runApp` returns. The handler never calls
`quitApp()`: that takes a lock and signals a condition variable, which is not
safe in a signal handler. It only sets an atomic stop flag that
`waitForAppExit` checks on every wake-up (at most every `IdleTickMs`).

**Linux and macOS:** `SIGINT` and `SIGTERM` (`sigaction` from `std/posix`).
A second signal while the flag is already set exits immediately with
`_exit(130)` for `SIGINT` / `_exit(143)` for `SIGTERM`, so a hung shutdown
can always be interrupted.

**Windows:** `SetConsoleCtrlHandler` (imported from `kernel32`), handling
`CTRL_C_EVENT`, `CTRL_BREAK_EVENT`, `CTRL_CLOSE_EVENT`, `CTRL_LOGOFF_EVENT`,
and `CTRL_SHUTDOWN_EVENT`. The handler runs on a new thread.

- Ctrl-C and Ctrl-Break: set the flag and return `TRUE`.
- Close, logoff, shutdown: Windows terminates the process as soon as the
  handler returns (or after its own timeout of a few seconds). The handler
  sets the flag, then waits, bounded to about 4 s, for `runApp` to report
  that shutdown has finished, then returns `TRUE`. Code after `startApp` may
  not run in this case; documented.

Running as a Windows service is out of scope for v1. Service wrappers that
send Ctrl-C to the console (NSSM does by default, to be confirmed in testing)
work through the Ctrl-C path.

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

**10.1 Close codes.** `ws.onclose` terminates on 1000, 1001, and 4000.

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

## 13. Build order and tests

Each step is reviewable on its own and leaves local mode working. Every step
runs `nimble test` on the developer's OS; the manual OS checklist below runs
at the end (and after step 4 for signals).

**Step 1: request filtering (`frontend.nim`).**
Tests in `t_frontend`:
- allowed origin accepted on `/ws`; port mismatch, scheme mismatch, trailing
  slash, and different-case input (normalized at validation) behave as
  specified;
- `Host` rewritten to `127.0.0.1:<port>` with a public `Origin` accepted;
- serve mode: cross-site `navigate` + `document` passes; cross-site
  `navigate` + `iframe` refused; cross-site `script` for `/neel.js` refused;
- local mode: every existing case unchanged, including cross-site
  navigations refused;
- origin validation and normalization (section 3.2).

**Step 2: serve core (`window.nim`, `neel.nim`).**
Tests in `t_window` / `t_neel`:
- window 1 exists after start, with no launch;
- window 1 survives past `startupTimeoutMs` without a connection, and past
  `gracePeriodMs` after a disconnect;
- `quitApp()` returns `erQuit`;
- `openWindow` / `closeWindow` raise `NeelServeModeError`;
- `onWindowOpen` fires once across two connections; `onWindowClose` fires
  once at teardown;
- `GET /` redirects when `startPath != "/"`; `/neel/no-browser` is a 404;
- `port = 0` and `allowedOrigins` without `serve` raise `ValueError`.

**Step 3: displaced close code (`window.nim`, `frontend.nim`, `neel.js`).**
Tests: displacement sends 4000 (`t_window` fake close records the code);
the shim treats it as final (manual, two browser tabs).

**Step 4: stop signals (`signals.nim`).**
Tests on Linux/macOS: send `SIGTERM` to the process during a serve-mode run
and expect `erQuit`. Windows: manual (Ctrl-C, Ctrl-Break, closing the console
window).

**Step 5: pings (`server.nim`).**
Tests in `t_server` with a short interval (e.g. 300 ms): an idle upgraded
connection receives a ping frame; an active one does not; `pingIntervalMs =
0` sends none.

**Step 6: shim serve behavior (`neel.js`, `frontend.nim`).**
Tests: render with the serve flag (`t_frontend` static checks). Dormant/wake
behavior: manual (desktop browser with DevTools offline toggle, then a phone).

**Step 7: docs and example.** README section, guide section, an
`examples/serve` app with run instructions for an SSH forward and
`cloudflared`.

### Manual checklist, per OS (macOS, Windows, Linux)

Local mode regression:
- the three examples run as before (open, call, second window, close, exit
  after the grace period).

Serve mode:
- starts without a browser and prints the startup line;
- page loads at `http://127.0.0.1:<port>`; a second tab displaces the first,
  which reports 4000 and does not reconnect;
- Ctrl-C exits cleanly; on Linux/macOS `kill -TERM` exits cleanly; on Windows
  closing the console window exits cleanly;
- left idle behind a proxy for 5 minutes with no reconnect (pings working).

Once, on Linux (the realistic deployment target):
- behind Cloudflare Tunnel with Access: the first load after login works
  (confirms 2.1 in practice);
- from a phone: open, lock the phone for 5 minutes, unlock: the page
  reconnects on its own;
- restart the server: the documented reload recipe recovers the page.

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
