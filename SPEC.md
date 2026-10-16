# Serve mode: specification

Status: decisions settled (reviewed 2026-10-14); steps 1–7 done
(2026-10-16); the final pass (13.8) is done on Windows and macOS
(2026-10-16) and pending on Linux.
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
  only observable differences.
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
never called. The `testhooks` ping observer (step 5) is called in both modes,
right after `newServer`, with the server's `pingIntervalMs` (0 locally,
30 000 in serve mode); it changes nothing.

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

As built (step 5, activity rule agreed with the user):

- **Activity** (`ConnObj.lastActivity`, a `MonoTime` on the IO thread): any
  successful receive of more than 0 bytes (pongs, partial frames, anything),
  any successful send of more than 0 bytes (our pings, the 101, every frame),
  the upgrade itself, and **queueing a ping**. The last one means a peer whose
  socket is backed up gets one ping per interval, not one per loop pass.
- `processPings` runs after `processDeadlines` in every loop pass: for each
  `csWebSocket` connection idle for at least the interval it appends
  `encodePing()` to `outbound` under the lock, unless `closing` is already
  set (a worker's `close` may have queued its frame since `processDirty`),
  and calls `flush`. A connection in `csClosing` or plain HTTP is never
  pinged.
- `selectTimeout` also takes the time until the next ping is due on any
  `csWebSocket` connection, rounded up by 1 ms so the loop does not spin, and
  stays bounded by `IoTickMs`. Nothing on the IO thread waits for a pong.
- `newServer(pingIntervalMs)` stores a negative value as 0; the read-only
  `pingIntervalMs(server)` returns it. `PingIntervalMs = 30_000` is a private
  constant in `neel.nim`; `server.nim` is not re-exported.
- **Exclusive bind on Windows** (folded into step 5 at the user's request):
  `openListener` sets `SO_EXCLUSIVEADDRUSE` on Windows instead of
  `SO_REUSEADDR`, so a second server (in any mode) on a port that is already
  listening fails `listen` with `OSError` instead of sharing it. POSIX keeps
  `SO_REUSEADDR` (it never allowed two listeners there). Checked on
  Windows 11: a restart still rebinds a port with server-side TIME_WAIT
  entries (16.1).

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
one branch, and `onclose` receives `(4000, false)`. The shim names the code
`CLOSE_DISPLACED`. Messages, as built (corrected in step 7, 16.1): calls in
flight reject with `neel: connection lost (close code 4000)` (`failPending`
runs first, for every code), calls made afterwards with `neel: connection
is closed`; `terminate`'s own reason, `neel: server closed the connection
(close code 4000)`, reaches only queued calls and an unsettled `neel.ready`,
neither of which can exist when the close arrives on an open socket. Same
for 1000 and 1001.

**10.2 Serve flag.** A fourth placeholder, `__NEEL_SERVE__`, rendered as
`true` / `false` by `renderNeelJs`. The `static:` checks in `frontend.nim`
are updated (four placeholders, each exactly once). Not exposed on `neel`, so
`Object.keys(neel)` is unchanged. As built (step 6): `ServePlaceholder*` in
`frontend.nim`; `renderNeelJs(token, windowId, exposed, serve: bool)` with no
default, so every caller states the mode; `neel.nim` passes `AppState.serve`.
The shim reads it as `const SERVE`; the two renderings differ only in that
literal.

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

As built (step 6, details agreed with the user):

- Only a dormant shim reacts to the wake events. While connected,
  reconnecting (backoff timer pending or a connect in flight), or
  terminated, `visibilitychange` and `online` do nothing; so several events
  in a row start one wake, and a visibility change to `"hidden"` never does
  anything.
- A wake clears dormant, resets `attempts` to 0, and connects at once; on
  failure the usual 250/500/1000/2000/4000 ms backoff follows (1 + 5
  connects, about 7.75 s, like a page load). Calls made during the round are
  queued as in any reconnect.
- A failed wake ends exactly like the first give-up: each failed attempt
  fires `onclose(code, true)`, the last `onclose(code, false)`, queued calls
  reject with `neel: gave up reconnecting after 5 attempts`, and the shim is
  dormant again until the next event.
- A call made while dormant rejects at once with `NeelDisconnectedError` and
  the message `neel: not connected; reconnects when the page becomes visible
  or goes online`. It does not start a wake. Consequence: a page that goes
  dormant while visible and online (the tunnel was down for more than about
  8 s while the user watched) stays dormant until a tab switch, a network
  change, or a reload.
- A successful wake fires `onreconnect`, also when the shim had never
  connected before (its `ready` is already rejected, so `onreconnect` is the
  page's only signal). The rule is now "every successful open except the one
  that resolves `neel.ready`" (in local mode that is the same as "except the
  first").
- `neel.close()` while dormant terminates and fires `onclose(1000, false)`,
  as `neel.close()` during a backoff does.
- The listeners are added once at load and only when `SERVE` is true; local
  mode adds none. They are never removed (they do nothing unless dormant).
- In the shim: `terminate`'s body became `giveUp`, shared by `terminate`
  (sets `terminated`, clears `dormant`) and `goDormant` (sets `dormant`);
  `scheduleReconnect`'s give-up branch calls `goDormant` when `SERVE`,
  otherwise `terminate`. `everOpened` became `readySettled` (set on the
  first open and by `giveUp`). `ws.onclose` is unchanged.

**10.4 Server restarts.** A restart changes the token, so a dormant shim's
reconnects get a 403 until the page reloads. The guide documents an
app-level recipe: reload on a 1001 close, or when a dormant shim's wake-up
attempt gives up. **Never reload on 4000**, or two devices loop. A stable token
across restarts would remove the need for this; deferred (section 15).

As documented (step 7, agreed with the user): the page does not reload at
once. It waits 2 s, then polls `fetch(location.href, {cache: "no-store",
redirect: "manual"})` every 2 s and reloads when the response is `ok` or
`type === "opaqueredirect"` (an auth proxy's login redirect); network errors
and 5xx (a tunnel answering 502) keep polling, and a successful reconnect
(`onreconnect`) stops it. "A wake-up attempt gives up" is detected in the
page by a flag set when `visibilitychange` (visible) or `online` fires while
the page shows dormant; the shim's own listeners run first. A restart first
noticed by an ordinary reconnect round (not a wake) ends dormant, and the
page reloads only after the next wake event (16.1).

---

## 11. Effect on local mode

Two observable differences:

- A displaced local connection (a duplicated tab, or a stale page refreshed
  against a fixed port) now receives close code 4000 instead of 1000. The
  shim's behavior is identical (final, no reconnect); only the code reported
  to `neel.onclose` changes. The guide's caveat about fixed ports is updated
  accordingly.
- On Windows only, a second app started on a fixed port that another Neel
  app already listens on now fails at start (`OSError` from `startApp`), as
  it already did on macOS and Linux. Before, both bound the port and
  connections went to either one (section 8, "Exclusive bind on Windows";
  agreed with the user in step 5). The default `port = 0` is unaffected.

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
- **From step 4 on (user's plan, 2026-10-15, revised the same day):** the
  user runs `nimble test`, plus the step's manual checks where it is a
  checkpoint, on **macOS and Windows** after every step. **Linux moves to the
  final pass after step 7**: Ubuntu runs in VirtualBox on the same Windows
  machine, which the user can only set up at the end. The session still runs
  `nimble test` on its own machine; the step's entry records which OSes the
  user has confirmed.
- **Consequence for the step-5 checkpoint:** it becomes macOS and Windows
  only. The epoll IO path in `server.nim` (and with it the Linux side of the
  pings) is first exercised in the final pass, so a Linux failure found
  there may come from step 5 or any later step; commit per step so it can be
  bisected. The POSIX signal code of step 4 is shared with macOS, where it
  passed, so its Linux risk is low. If VirtualBox stays impractical, WSL2 on
  the Windows machine is a real Linux kernel (epoll, signals) and a cheaper
  way to run `nimble test` on Linux earlier.
- **Update (2026-10-15, after step 5):** the user ran Linux (Ubuntu in
  VirtualBox) after all: `nimble test` and the step 4 and step 5 manual
  checks passed, after one test-only fix (16.1, `SA_RESTORER`). Steps 1–5
  are therefore green on all three OSes; the examples have not been run on
  any OS yet. Steps 6 and 7 follow the every-step plan above (macOS and
  Windows), and the final pass still runs everything on all three.

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
  `--os:macosx`), never compiled to C or run in the session. **User-confirmed
  (2026-10-15): macOS** (`nimble test`, the first real run of the POSIX
  signal tests, plus the macOS manual checks below) **and Windows**
  (`nimble test` plus the Windows manual checks below), all passed.
  **Linux** (user-run after step 5, 2026-10-15): `nimble test` and the POSIX
  manual checks below passed, after a test-only fix to how `t_neel` compares
  signal actions (16.1, `SA_RESTORER`).)
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
  checks below. Done on macOS and Windows (2026-10-15, all passed), and on
  Linux after step 5 (passed).

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
  fixed port, because `server.nim` sets `SO_REUSEADDR` (16.1). Fixed in
  step 5 (`SO_EXCLUSIVEADDRUSE`, 16.2).

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

Results (2026-10-15, user-run):
- macOS: `nimble test` and the macOS manual checks above (Ctrl-C, `kill -TERM`,
  second signal with `NEEL_HANG`): passed.
- Windows 11: `nimble test`, Ctrl-C, Ctrl-Break, closing the console window,
  and local-mode Ctrl-C (`examples/roundtrip`): passed. The machine has no
  Break key, so Ctrl-Break was sent with `GenerateConsoleCtrlEvent` to the
  app started in its own process group (the ad hoc script of 16.1): `returned
  erQuit`, `closed.txt` written, exit code 0, after 516 ms.
- Linux (Ubuntu in VirtualBox, run after step 5): `nimble test` and the
  POSIX manual checks above (Ctrl-C, `kill -TERM`, second signal with
  `NEEL_HANG`): passed. The first `nimble test` run failed one check in
  `t_neel` on a `SA_RESTORER` bit that glibc adds to restored actions; the
  test was fixed, not the handlers (16.1). Local-mode Ctrl-C on an example
  was not run (no examples run yet).

### 13.5 Step 5: keep-alive pings

- **Status:** done (2026-10-15; `nimble test` (three times) and
  `nim c src/neel.nim` green on **Windows 11** (win32 10.0.26200) with Nim
  2.2.12. `nim` on PATH is `~/.nimble/bin/nim.exe`; Nimble compiled with
  `~/.nimble/pkgs2/nim-2.2.12-1ce02ec.../bin/nim.exe`, also 2.2.12. Only the
  Windows `select` backend ran in the session; kqueue (macOS) and epoll
  (Linux) were **type-checked only** (`nim check --os:macosx` /
  `--os:linux` of `src/neel.nim`, `t_server`, and a `t_neel` copy with disk
  assets). **User-confirmed (2026-10-15): macOS and Windows**, `nimble test`
  several times back to back on each, all passed; the first real run of the
  ping timer on kqueue. The two-instance and restart check passed on both.
  **Linux** (Ubuntu in VirtualBox, 2026-10-15): `nimble test` and the
  two-instance check passed; the first real run of the epoll IO path and of
  the ping timer on it.)
- **Depends on:** step 2 (for the `runApp` wiring only)
- **Touches:** `server.nim`, `neel.nim`, `testhooks.nim` (ping observer);
  tests `t_server`, `t_neel`
- **Spec:** section 8 (and 11 for the Windows bind)
- **Cross-OS:** checkpoint (confirmed). `server.nim` has a separate IO path
  per OS (Windows sockets and `select`, kqueue, epoll); the ping timer runs
  inside it, and the ping tests are timing-based. The step also changes a
  Windows-only branch (`SO_EXCLUSIVEADDRUSE`). No new state shared between
  threads: `lastActivity` is IO-thread only, `pingIntervalMs` is immutable
  after `newServer`, and the ping bytes go through the existing `outbound`
  queue under the existing lock. Under the every-step plan (13.0): macOS
  (first run of the ping timer on kqueue) and Windows (`nimble test` on the
  user's machine) right after this step; Linux (epoll) in the final pass.

Tests (`t_server`, with a short interval such as 300 ms): an idle upgraded
connection receives a ping; an active one does not; `pingIntervalMs = 0`
sends none.

**Notes:**
- Activity rule agreed with the user: successful reads and writes of more
  than 0 bytes (pongs and our own pings included), the upgrade, and a
  queued ping all restart the idle time; the last one prevents one ping per
  loop pass on a backed-up socket. Section 8 "As built" updated (16.2).
- Windows `SO_REUSEADDR` replaced by `SO_EXCLUSIVEADDRUSE` in this step, at
  the user's request, after a probe showed restarts still rebind (16.1). A
  second local-mode app on a taken fixed port now fails on Windows; section
  11 updated (16.2).
- `runApp`'s interval is proven with a recording hook,
  `testhooks.setTestPingObserver` (the user's choice over a 30 s wait); it
  is called in both modes and changes nothing (16.2, section 6).
- Built: `newServer(pingIntervalMs = 0)`, `pingIntervalMs(server)`,
  `ConnObj.lastActivity`, `processPings` (after `processDeadlines`), the
  ping term in `selectTimeout`, the Windows exclusive bind; `neel.nim`'s
  private `PingIntervalMs = 30_000` passed only when `serve`. Doc comments
  of `server.nim` (header, `newServer`, `listen`, `openListener`) and
  `runApp` updated; the guide is step 7.
- Tests: `t_server` gains the "server: keep-alive pings" suite (fixture:
  300 ms interval, 1.2 s close timeout): no pings with the default 0 (and a
  negative value stored as 0); an idle connection is pinged (empty,
  unmasked, final, not before the interval) and a pong restarts the idle
  time (the next ping comes at least 300 ms after the pong); a connection
  kept busy by the peer, then by the server alone, gets no ping for over
  three intervals and is pinged once left alone; plain HTTP connections
  (served and silent) get nothing while an upgraded one is pinged; no
  ping once the server starts closing (1.2 s of silence until EOF) nor
  after a peer-initiated close; shutdown sends 1001 and EOF. The lifecycle
  suite gains: a second server on a listening port raises `OSError`; a
  port is rebound right after shutdown with server-side TIME_WAIT entries.
  `t_neel`: local runs 1, 2, and 3 record interval 0; the main serve run
  records 30 000; the three parameter refusals create no server.
  `occupyPort` no longer needs `SO_EXCLUSIVEADDRUSE`.
- Mutations checked in the session (each reverted): reads not counted
  (the pong test fails), writes not counted (the busy test fails), closing
  connections pinged (the closing test fails, only after the fixture's
  close timeout was raised above the interval, see 16.3), Windows back to
  `SO_REUSEADDR` (the second-server test fails).
- Not covered automatically: the "queued ping restarts the idle time" rule
  on a backed-up socket (needs a peer that stops reading with the kernel
  buffers full); its effect is only that output does not pile up.
- Timing: the unmutated ping suite passed 17 times out of 17 in the
  session (one direct run, three `nimble test` runs, ten back-to-back runs,
  and three copies in parallel to load the machine); no flakes seen. The bounds are exact by construction (a ping cannot come before
  the interval measured from the server's own timestamps) except "first
  ping after at least 250 ms" (50 ms slack for the 101's delivery).

Manual checks:
- macOS: `nimble test` (first run of the ping timer on kqueue). Expect all
  green, the "server: keep-alive pings" suite included. Run it twice; report
  any ping-suite failure verbatim instead of retrying it away.
- Windows: `nimble test` on your machine. Same expectation.
- Windows: two serve apps on the same port. Start the step 4 test app
  (`startApp(webDir = "web", serve = true, port = 8080)`), then a second copy
  in another console. Expect the second to fail at once with an `OSError`
  ("Only one usage of each socket address ...") and no startup line; the
  first keeps serving. Stop the first with Ctrl-C and start it again
  straight away: it must start (no "address in use").
- macOS (optional, same app): the same two-instance check; the second fails
  with "Address already in use". This was already the behavior.
- Any OS, serve mode (optional now; 13.8 "idle behind a proxy" is the real
  check): open `http://127.0.0.1:8080` in Firefox, whose WebSocket inspector
  (Network > the `/ws` request) can list control frames once they are
  enabled in its message filter, and leave the page alone. Expect an empty
  ping and the browser's pong about every 30 s. Chrome's Messages tab may
  not list control frames at all. Local mode's "no pings" is covered by
  `t_neel` (interval 0) and `t_server` (0 sends none).
- Linux, final pass: `nimble test` (first run on epoll) and the proxy check
  in 13.8.

Results (2026-10-15, user-run):
- macOS: `nimble test`, several runs back to back: passed (no ping-suite
  flakes).
- Windows 11: `nimble test`, several runs back to back: passed.
- Two instances on port 8080, then a restart right after Ctrl-C (with a
  page connected), on Windows 11 and macOS: passed. The second copy failed
  at start with `OSError` and printed no startup line while the first kept
  serving; the restart bound the port at once.
- Linux (Ubuntu in VirtualBox): `nimble test` and the two-instance and
  restart check: passed (the second copy fails with "Address already in
  use"). One `t_neel` check needed a test-only fix first (16.1).

### 13.6 Step 6: shim serve behavior

- **Status:** done (2026-10-15; `nimble test` and `nim c src/neel.nim` green
  on **Windows 11** (win32 10.0.26200) with Nim 2.2.12. `nim` on PATH is
  `~/.nimble/bin/nim.exe` (choosenim toolchain 2.2.12, `nim -v`: 2.2.12);
  Nimble compiled with `~/.nimble/pkgs2/nim-2.2.12-1ce02ec.../bin/nim.exe`,
  also 2.2.12.
  `node` v24.20.0 was on PATH, so the shim behavior test ran (not skipped).
  **User-confirmed (2026-10-15): Linux** (Ubuntu in VirtualBox; `nimble
  test` passed, with "frontend: shim behavior under node" `[OK]`, the first
  POSIX run of the harness) **and macOS** (`nimble test` passed, the node
  test `[OK]` as well, nothing skipped). Step 6 is
  green on all three OSes. The browser checks below are still open.)
- **Depends on:** steps 2 and 3
- **Touches:** `neel.js`, `frontend.nim`; `neel.nim` (passes `a.serve` at the
  `renderNeelJs` call site, and one header line); tests `t_frontend`,
  `t_neel`, new `tests/fixtures/shim_reference.js` and
  `tests/fixtures/shim_harness.js`
- **Spec:** sections 10.2–10.4
- **Cross-OS:** safe to defer (confirmed). Browser-side JS and one more
  literal in a pure renderer: no platform branches, no OS APIs, no new state
  shared between threads. The only OS-touching code is test-only (the node
  test finds `node` with `findExe` and runs it with `startProcess` under the
  temp dir). Under the every-step plan (13.0): `nimble test` on macOS (with
  `node` installed, the first POSIX run of the behavior test) and on Windows.
  The browser checks below go to the final pass; running the first one early
  on any OS is cheap and is the only real-browser check of the new state.

Tests: rendering with the serve flag and the updated `static:` checks
(`t_frontend`). Manual: dormant and wake behavior with the DevTools offline
toggle, then on a phone.

**Notes:**
- Wake details agreed with the user (events only matter while dormant, one
  wake per round, first attempt immediate, failed wake goes dormant again
  with `onclose(code, false)`, dormant calls reject without waking, a new
  rejection message, `onreconnect` after a wake even if the shim never
  connected, `neel.close()` while dormant terminates, listeners only in
  serve mode). Section 10.3 "As built" records them (16.2).
- Behavior is tested with an opt-in node harness, at the user's choice:
  run when `node` is on PATH, skipped with a printed reason otherwise. No
  runtime dependency; `tests/fixtures/` gains the harness and a frozen copy
  of the pre-serve shim (16.2).
- `renderNeelJs` takes `serve` with no default (my choice, so no caller can
  forget it); the doc comments of `frontend.nim`, `renderNeelJs`, the
  `neel.nim` route list, and the shim header describe the flag and the
  dormant state. The guide is step 7 (section 14 updated with what it needs).
- Built: `const SERVE`, `DORMANT_REASON`, the `dormant` flag, `giveUp` /
  `terminate` / `goDormant`, the `SERVE` branch in `scheduleReconnect`,
  `wake()`, the two listeners behind `if (SERVE)`, `readySettled` (was
  `everOpened`). `ws.onclose` and its single terminating branch are
  untouched.
- Tests, always run (`t_frontend`): both renderings against an independent
  rendering; the serve and local renderings identical apart from the
  literal; four placeholders, each once in the source and none left after
  rendering in either mode; a single-pass case with `__NEEL_SERVE__` inside
  the token and an exposed name (misuse); a non-positive window id in both
  modes; `Object.keys(neel)` read from `Object.defineProperties(neel, ...)`
  in both renderings and the frozen reference, with no other property set on
  `neel`; in `ws.onclose` the 1000/1001/4000 branch is first, terminates and
  returns, and nothing there mentions dormant or wake; `SERVE` read only in
  the give-up branch and the listener block; `goDormant` called once, behind
  `SERVE`; only `goDormant` sets `dormant`; listeners and `wake()` calls only
  inside the `SERVE` block. `t_neel`: the local run's served shim equals
  `renderNeelJs(..., serve = false)` and the serve run's equals
  `renderNeelJs(..., serve = true)`.
- Tests, when `node` is on PATH (`t_frontend` "frontend: shim behavior
  under node", 84 checks in `shim_harness.js`): the frozen reference, the
  local rendering, and the serve rendering play 12 shared scenarios (first
  open and queue flush, replies, a JS function called from Nim, a drop and
  reconnect with `onreconnect`, a first connect that fails then succeeds,
  1000/1001/4000 each final with wake events after them, `neel.close()` open,
  during a backoff, and before the first open) with identical traces; local
  and the reference also give up identically, after an open and before any,
  with wake events ignored afterwards; serve gives up identically to local up
  to that point. Serve-only scenarios cover every item of 10.3 "As built".
  Local mode adds no listeners; serve adds one of each.
- Mutations checked in the session (each reverted): the local shim rendered
  as serve, the serve shim rendered as local, `wake` without the attempts
  reset, a timer-delayed first wake attempt, `wake` ignoring the dormant flag,
  dormant calls queued instead of rejected, `readySettled` not set on giving
  up, the visibility check dropped, `terminate` not clearing `dormant`: each
  fails the node test. A second `__NEEL_SERVE__` in the shim fails the build.
  The node test reports the harness output on failure and is `[SKIPPED]` with
  a printed reason when `node` is not on PATH (both checked).
- `node --check` passes on both renderings (written under `$env:TEMP`).

Manual checks. Any serve app works (the step 4 test app:
`startApp(webDir = "web", serve = true, port = 8080)`), opened at
`http://127.0.0.1:8080` in Chrome or Edge. In the DevTools console, first
run:

```js
neel.onclose((c, r) => console.log("onclose", c, r));
neel.onreconnect(() => console.log("onreconnect"));
const probe = () => neel.call("x").then(
  (v) => console.log("ok", v), (e) => console.log(e.name, e.message));
```

- `nimble test` on macOS and Windows (every-step plan). Expect all green,
  and `[OK]` (not `[SKIPPED]`) for "serve, local, and the frozen reference
  shim in a scripted browser" where `node` is installed. On a failure, the
  harness report is printed under the failed check; send it verbatim.
- Dormant and wake (final pass; can be run early): Network panel, set
  throttling to "Offline". Expect `onclose 1006 true` five times over about
  8 s, then `onclose 1006 false`, and no further `/ws` requests in the
  Network panel. `probe()` prints `NeelDisconnectedError neel: not connected;
  reconnects when the page becomes visible or goes online` at once. Set
  throttling back to "No throttling": expect one new `/ws` request at once,
  `onreconnect`, and `probe()` answered by the server again
  (`NeelUnknownProcError no exposed proc named 'x'`, not the dormant
  message). Repeat, but wake by switching to
  another tab and back (still offline: expect one round of six failed
  attempts and dormant again; then go online). If going offline does not
  close the open WebSocket (DevTools versions differ), record it in 16.1 and
  use Firefox's "Offline" throttling instead.
- Server restart while dormant (final pass): get the page dormant as above,
  stop the server with Ctrl-C (the page is not connected, so it gets no
  1001), start it again, then go back online. Expect six failed `/ws`
  attempts answered 403 (the token changed), `onclose 1006 false`, and the
  page dormant again (`probe()` gives the dormant message). A reload
  recovers it. A Ctrl-C while the page is connected sends 1001, which
  terminates it instead: that is the 1001 case of the reload recipe.
- Local mode give-up still terminal (final pass): in a local-mode example's
  app window (`examples/roundtrip`), open DevTools, register the listeners,
  go "Offline". Expect five `onclose 1006 true`, one `onclose 1006 false`,
  `probe()` giving `neel: connection is closed`, and nothing on going back
  online or switching tabs (no `/ws` request, no `onreconnect`). The app
  then exits after its grace period, as before.
- Phone (final pass, 13.8): open the serve app through the tunnel, lock the
  phone for 5 minutes, unlock: the page reconnects by itself (`onreconnect`)
  without a reload.

### 13.7 Step 7: documentation and example

- **Status:** done (2026-10-16; `nimble test` and `nim c src/neel.nim` green
  on **Windows 11** (win32 10.0.26200) with Nim 2.2.12. `nim` on PATH is
  `~/.nimble/bin/nim.exe` (`nim -v`: 2.2.12); Nimble compiled with
  `~/.nimble/pkgs2/nim-2.2.12-1ce02ec.../bin/nim.exe`, also 2.2.12. `node`
  is on PATH, so "serve, local, and the frozen reference shim in a scripted
  browser" ran: `[OK]`. macOS and Linux not run for this step; the final
  pass (13.8) covers them.)
- **Depends on:** steps 1–6
- **Touches:** `README.md`, `docs/GUIDE.md`, the headers of `neel.nim`,
  `frontend.nim`, and `window.nim` (comments only), new `examples/serve`,
  `examples/stresstest/web/index.html`; `SPEC.md` 10.1 (wording) and 14
- **Spec:** sections 12, 14
- **Cross-OS:** safe to defer (confirmed): documentation, comments, and an
  example; no platform branches, OS APIs, or new state shared between
  threads in Neel (the example's note is app state under its own `Lock`).
  It is the step that **triggers the final pass**: the full 13.8 checklist
  on macOS, Windows, and Linux, using `examples/serve` and the existing
  examples.

Scope: everything in section 14, plus an `examples/serve` app with run
instructions for an SSH forward and `cloudflared`. Proxy configs are
published only once verified on a real setup.

**Notes:**
- Reload recipe (decided with the user before this session): triggers as in
  10.4 (1001, or a give-up right after a wake event; never 4000), but the
  page does not reload at once: it waits 2 s, then polls
  `fetch(location.href, {cache: "no-store", redirect: "manual"})` every
  2 s and reloads on `ok` or `type === "opaqueredirect"`; network errors and
  5xx keep polling, and a successful reconnect stops the poll.
- The cloudflared quick tunnel is documented (guide and example) and marked
  "not yet verified": `cloudflared` is not installed on the session machine.
  Tailscale Serve, nginx, Caddy, and Cloudflare Tunnel with Access are only
  drafts in 13.8; section 14 updated (16.2). The section 12 note about
  nginx's `Upgrade` / `Connection` headers is generic in the guide (no
  proxy named).
- Section 10.1 described the rejection texts of a final close wrongly; the
  code (pinned by the harness and the frozen reference) is unchanged, 10.1
  is corrected, and the guide documents what the shim does (16.1).
- Gap documented, not changed: a restart first noticed by an ordinary
  reconnect round (not a wake) ends dormant, so the page reloads only after
  the next wake event (16.1; guide, "Reloading after a server restart").
- Beyond section 14 (all agreed before the session): the Lifecycle,
  Multiple windows, Assets, `startApp` parameters, Security, and `neel.js`
  rejection-list updates; README Features bullet, security line, Examples
  entry; guide Contents, "Running the examples", "The examples". Also,
  my additions: `erLastWindowClosed` / `erStartupTimeout` marked local-only,
  the `startPath`, `port`, and hook rows of the parameter table, a warning
  that a quick tunnel is public, and the stresstest page's "any code but
  1000/1001" (now with 4000) and its quoted close message (now the status
  text the page shows).
- `examples/serve` choices of mine: the page also shows when it was loaded
  and a reconnect counter (so the manual checks can tell a reload from a
  reconnect), keeps unsaved edits when a reconnect reloads the note, asks
  for confirmation before "Stop server", and stops with
  `neel.stopServer.send()` (no reply to lose to the shutdown race). The
  Nim side quits with the message on a `ValueError` or `OSError` from
  `startApp` (`ValueError: neel: allowedOrigins entry ...`), exit code 1.
- Module headers: the three "Task N" leftovers (`frontend.nim`,
  `window.nim` twice) are gone; `neel.nim`'s route-list sentence now covers
  serve mode's hosts, origins, and cross-site navigations, and its
  `testhooks` sentence the ping observer. `server.nim` needed nothing.
- Checked in the session: all four examples compile (debug; `serve` also
  release), binaries and nimcache under `$env:TEMP`. `serve` ran in debug
  and release, driven by an ad-hoc raw-socket Node script (not in the
  repo): the startup line, `GET /` 200 (index.html), `/neel/no-browser`
  404, `Host: localhost:5359` 403, the shim rendered with `SERVE = true`,
  the `/ws` upgrade (101), `serverInfo` / `saveNote` / `getNote`, then
  `stopServer` gave a 1001 close and `serve exited: erQuit` (release: exit
  code 0). Also: `--port=abc`, an unknown option, `https://x.com/`, and a
  taken port each exit 1 with a one-line message (`OSError: Only one usage
  of each socket address ...`); `--port=5360 https://Notes.Example.com:443
  http://localhost:5360` prints `(allowed origins: https://notes.example.com,
  http://localhost:5360)` and accepts `Host: localhost:5360`. `node --check`
  passes on `web/main.js`.
- Not checked in the session: the page in a real browser (no browser
  automation here). Its connection states and the reload recipe are the
  13.8 serve rows.

Manual checks: the whole of 13.8 (final pass), in particular the
`examples/serve` rows on all three OSes, the browser checks from 13.6, and
the proxy and phone rows.

### 13.8 Manual verification

Run by the user on each OS in the final pass after step 7 (13.0). Earlier
checkpoints fill some rows in early, marked with the step they were run
after; the final pass re-runs them. Record results here (`pass`, `fail` with
a section 16 entry, or `n/a`). Each row's name matches a procedure below.

**Setup, once per OS.** From the repository root, in a terminal:

```
nim c examples/serve/serve.nim
nim c examples/filepicker/filepicker.nim
nim c examples/roundtrip/roundtrip.nim
nim c examples/stresstest/stresstest.nim
```

These are debug builds; each binary lands next to its source. The
procedures write `./examples/serve/serve`; on Windows that is
`.\examples\serve\serve.exe` (likewise for the others). Exit status:
`echo $?` on macOS and Linux, `$LASTEXITCODE` in PowerShell. A kill is
`kill -9 <pid>` on macOS and Linux and `Stop-Process -Id <pid> -Force` on
Windows. DevTools: F12 or Ctrl+Shift+I (Cmd+Opt+I on macOS), also in an
app-mode window. Browser: Chrome or Edge unless a row says otherwise.

The `examples/serve` page shows a status line (`connected`,
`connection lost (close code N), reconnecting`, `not connected; reconnects
when ...` = dormant, `opened on another device` with a "Use it here"
button, `... Waiting for the server; this page reloads when it answers.`),
the line `page loaded <time>, reconnects: <n>` (a reload resets both, a
reconnect only increments the counter), and the server's pid and start
time (they change only when the server restarts). The note lives in memory
only, so a restart empties it.

Console probe, pasted into the DevTools console of a page under test (from
13.6):

```js
neel.onclose((c, r) => console.log("onclose", c, r));
neel.onreconnect(() => console.log("onreconnect"));
const probe = () => neel.call("x").then(
  (v) => console.log("ok", v), (e) => console.log(e.name, e.message));
```

`probe()` answers `NeelUnknownProcError no exposed proc named 'x'` while
connected, `NeelDisconnectedError neel: not connected; reconnects when the
page becomes visible or goes online` while dormant, and
`NeelDisconnectedError neel: connection is closed` once terminated.

| Check | macOS | Windows | Linux |
|---|---|---|---|
| `nimble test` passes (node test `[OK]`, not `[SKIPPED]`) | pass | pass | pass (after step 6) |
| Local: the three examples behave as before | pass (window 2 closed with X gives `NeelDisconnectedError`, 16.1) | pass | |
| Local: fixed port, a browser tab displaces the app window (4000) | pass | pass | |
| Local: Ctrl-C ends a local-mode app the old way | pass (debug build, exit status 130) | pass (release; debug crashes in Nim's handler, 16.1) | |
| Local: the shim's give-up is still terminal | pass | pass | |
| Serve: starts without a browser, prints the startup line | pass (stopped with `kill -INT`) | pass | |
| Serve: page loads at `http://127.0.0.1:<port>`, the note round-trips | pass | pass | |
| Serve: a second tab displaces the first (4000, no reconnect, no loop) | pass | pass | |
| Serve: Ctrl-C exits cleanly | pass (`kill -INT`) | pass | pass (after step 5) |
| Serve: `kill -TERM` exits cleanly | pass | n/a | pass (after step 5) |
| Serve: a second signal exits at once (130 / 143) | pass (`kill -INT` / `kill -TERM` twice) | n/a | pass (after step 5) |
| Serve: Ctrl-Break exits cleanly | n/a | pass (`GenerateConsoleCtrlEvent`, 211 ms) | n/a |
| Serve: closing the console window exits cleanly | n/a | pass | n/a |
| Serve: a second app on the same fixed port fails at start; a restart right after Ctrl-C binds | pass (restart after `kill -INT`) | pass | pass (after step 5) |
| Serve: "Stop server", then a restart: the page reloads by itself | pass (and with `kill -INT`) | pass | |
| Serve: dormant shim wakes (DevTools offline toggle) | pass (outage via a TCP relay, 16.1) | pass (outage via a TCP relay, 16.1) | |
| Serve: server restart while dormant: the failed wake reloads the page | pass (outage via a TCP relay, 16.1) | pass (outage via a TCP relay, 16.1) | |
| Serve: SSH forward from another machine; `localhost` refused | pass (Mac server, Windows client; `ssh` killed and restarted woke the page) | n/a (no OpenSSH Server) | |
| Serve: an `--app:gui` build starts and serves | n/a | pass | n/a |
| Serve: idle behind a proxy for 5 minutes without a reconnect | pass (cloudflared quick tunnel, Chrome, about 10 min) | pass (cloudflared quick tunnel, Edge, about 10 min) | |

Once, on Linux (the realistic deployment target; the server runs on Linux,
the browsers anywhere):

| Check | Result |
|---|---|
| cloudflared quick tunnel: the page works over `https` / `wss` | |
| Behind Cloudflare Tunnel with Access: first load after login works (confirms 2.1) | |
| Phone: open, lock for 5 minutes, unlock: the page reconnects by itself | |
| Phone and laptop share the note; "Use it here" takes the session back | |
| Server restart: the documented reload recipe recovers the page | |
| Draft: Tailscale Serve | |
| Draft: nginx (with the `Upgrade` / `Connection` headers) | |
| Draft: Caddy | |

#### Procedures

**`nimble test` passes.** `nimble test` in the repository root, with `node`
on PATH. Expect `Success: All tests passed` and `[OK]` for "serve, local,
and the frozen reference shim in a scripted browser". Report any failure
verbatim (the harness report is printed under the failed check).

**Local: the three examples behave as before.**
- `./examples/filepicker/filepicker`: an app window opens. "Pick a random
  entry" with `Desktop` shows a name; `nosuchdir` shows
  `MissingDirectoryError: no such directory: ...`. Close the window: the
  process ends about 3 s later.
- `./examples/roundtrip/roundtrip`: `neel.sum(...)` shows `15`;
  `neel.askPage(...)` shows `the page answered: what now? -> forty-two`.
  "openSecond" opens window 2 and the terminal prints `window 2 opened`.
  "askSecond": answer the prompt (the value comes back), Cancel
  (`PromptCancelled`), wait 5 s (`NeelTimeoutError`), end window 2 while
  the prompt is up (`NeelDisconnectedError`; kill its browser process,
  since closing it with X lets Chrome dismiss the prompt first, which gives
  `PromptCancelled`, 16.1), ask again
  (`NeelNoWindowError`). "listWindows" lists the open windows. Close
  window 1: `window 1 closed` and the process ends about 3 s later.
- `./examples/stresstest/stresstest`: press every section's buttons; no
  log line reads `FAIL` or `UNEXPECTED`. Then the page's own manual checks
  "Refresh", "Close this browser window", and "Quit button" (each in a new
  run); "Reconnect and give up" and "Refresh after a restart" belong to the
  rows below.

**Local: fixed port, a browser tab displaces the app window (4000).**
`./examples/stresstest/stresstest 8765`. In a normal browser tab open
`http://127.0.0.1:8765/?window=1`. Expect the app window's status
`closed (close code 4000, neel.connected = false)` and no further `/ws`
requests from it (its DevTools Network panel); the tab works ("whoAmI()"
gives 1). Then the page's "Refresh after a restart" check: kill the app
(the pid is in asJson()), wait for the status "closed (close code 1006
...)", start `./examples/stresstest/stresstest 8765` again, refresh the old
window: it works again, and the window the restart opened reads
`closed (close code 4000, ...)`.

**Local: Ctrl-C ends a local-mode app the old way.**
`./examples/roundtrip/roundtrip`, then Ctrl-C in its terminal. Expect Nim's
`SIGINT: Interrupted by Ctrl-C.` and the process gone at once, with no
`window 1 closed` line (no Neel shutdown). On Windows run this with a
release build (`nim c -d:release ...`): a debug build crashes in Nim's own
handler (exit `-1073741819`, no message; documented in the guide, 16.1).

**Local: the shim's give-up is still terminal.** The stresstest page's
"Reconnect and give up" check: `./examples/stresstest/stresstest`, note the
pid from asJson(), paste the console probe into the app window's DevTools,
kill the process (the browser window stays). Expect `onclose 1006 true`
five times over about 8 s, then `onclose 1006 false`; `probe()` gives
`neel: connection is closed`. Then toggle DevTools Network throttling to
"Offline" and back, and minimize and restore the window: no new `/ws`
request, no `onreconnect`, no status change. (Going offline instead of
killing does not work for this row: the server sees the close and exits
after its 3 s grace period, which closes the window before the 7.75 s
give-up.)

**Serve: starts without a browser, prints the startup line.**
- `./examples/serve/serve`: no browser opens; stdout shows exactly
  `neel: serving http://127.0.0.1:5359 (allowed origins: none)`. Ctrl-C.
- `./examples/serve/serve --port=8080 HTTPS://Notes.Example.com:443
  http://localhost:8080`: `neel: serving http://127.0.0.1:8080 (allowed
  origins: https://notes.example.com, http://localhost:8080)`. Ctrl-C.
- `./examples/serve/serve https://x.com/`: one line, `ValueError: neel:
  allowedOrigins entry "https://x.com/" has a path (a trailing / counts as
  one); expected http://host[:port] or https://host[:port]`, exit status 1,
  no startup line.

**Serve: page loads at `http://127.0.0.1:<port>`, the note round-trips.**
`./examples/serve/serve`, open `http://127.0.0.1:5359`. Expect the status
`connected`, the pid and start time, `never saved`. Type a note and press
Save: `saved <time>`. Reload: the note is still there. Also:
`http://127.0.0.1:5359/neel/no-browser` is a 404, and
`http://localhost:5359` is a 403 reading `neel: refused: the Host header
must be 127.0.0.1:5359`. Leave the tab closed for longer than 30 s: the app
keeps running (no grace period).

**Serve: a second tab displaces the first (4000, no reconnect, no loop).**
With the app running and tab A connected (console probe pasted), open the
same URL in tab B. B shows `connected` and A's note. A shows `opened on
another device` and "Use it here"; its console shows `onclose 4000 false`;
its Network panel shows no further `/ws` request; `probe()` gives `neel:
connection is closed`. Edit and save in B, then press "Use it here" in A:
A reloads, shows B's edit, and B now reads `opened on another device`.
Wait 30 s: neither tab reloads or reconnects by itself.

**Serve: Ctrl-C exits cleanly.** `./examples/serve/serve`, open the page,
Ctrl-C in the terminal. Expect `serve exited: erQuit`, exit status 0, and
the page's `The server stopped. Waiting for the server; ...` (it received
the 1001). (The step-4 test app checks `onWindowClose` as well; see 13.4.)

**Serve: `kill -TERM` exits cleanly** (macOS, Linux). As the previous row,
but `kill -TERM <pid>` from another terminal (the pid is on the page).
Same result.

**Serve: a second signal exits at once (130 / 143)** (macOS, Linux). Needs
a hanging shutdown, so it uses the step-4 test app with `NEEL_HANG=1`
(13.4, manual checks): Ctrl-C, wait for `closed.txt`, Ctrl-C again. Expect
an immediate exit with status 130 and no `returned` line; with
`kill -TERM` twice, 143.

**Serve: Ctrl-Break exits cleanly** (Windows). In a console, start
`.\examples\serve\serve.exe`, open the page, press Ctrl-Break (on a machine
without a Break key, use the `GenerateConsoleCtrlEvent` recipe of 16.1).
Expect `serve exited: erQuit`, exit status 0, the page waiting for the
server.

**Serve: closing the console window exits cleanly** (Windows). From
PowerShell, `Start-Process .\examples\serve\serve.exe` (a new console),
open the page, close that console with its X button. Expect the process
gone within about 2 s (`Get-Process serve` finds nothing) and the page's
`The server stopped. ...` (the 1001 went out before Windows ended the
process). The `serve exited` line may not appear.

**Serve: a second app on the same fixed port fails at start; a restart
right after Ctrl-C binds.** With `./examples/serve/serve` running and its
page connected, start a second `./examples/serve/serve` in another
terminal. Expect one `OSError: ...` line (Windows: `Only one usage of each
socket address ...`; macOS and Linux: `Address already in use`), exit
status 1, no startup line; the first keeps serving (the page still saves).
Ctrl-C the first and start it again at once: it prints the startup line.

**Serve: "Stop server", then a restart: the page reloads by itself.**
`./examples/serve/serve`, open the page, paste the console probe, note the
pid. Press "Stop server" and confirm. Expect `serve exited: erQuit` and exit
status 0 in the terminal; in the page `onclose 1001 false` and `The server
stopped. Waiting for the server; this page reloads when it answers.`; in
the Network panel a failing request for `/` every 2 s, and no reload. Wait
10 s, then start `./examples/serve/serve` again. Expect the page to reload
within about 2 s: a new `page loaded` time, `reconnects: 0`, a new pid and
start time, an empty note. Repeat with Ctrl-C instead of the button: same
result.

**Serve: dormant shim wakes (DevTools offline toggle).** The 13.6 check,
with `examples/serve`. Open the page, paste the console probe. In the
Network panel set throttling to "Offline". Expect `onclose 1006 true` five
times over about 8 s, then `onclose 1006 false`, the status `not connected;
reconnects when ...`, and no further `/ws` request. `probe()` gives the
dormant message at once. Set throttling back to "No throttling": one new
`/ws` request at once, `onreconnect`, status `connected`, `reconnects: 1`,
the `page loaded` time unchanged, and `probe()` answered by the server
again. Repeat, but wake by switching to another tab and back while still
offline: one round of six failed attempts (five `true`, one `false`), the
shim dormant again (`probe()` gives the dormant message), and the page
showing `The server refused the reconnect (it may have restarted). Waiting
for the server; ...` (a failed wake). Go back online: expect `onreconnect`
and the status `connected` without a reload (`page loaded` unchanged); a
reload instead is also correct if the page's poll answered first. If going
offline does not close the open WebSocket (DevTools versions differ),
record it in 16.1 and use Firefox's "Offline" throttling, or an SSH forward
(next rows) killed and restarted as the outage.

**Serve: server restart while dormant: the failed wake reloads the page.**
Get the page dormant as in the previous row. Ctrl-C the server (the page is
not connected, so it gets no 1001) and start it again (new pid). Set
throttling back to "No throttling". Expect six `/ws` attempts answered 403
in the Network panel, `onclose 1006 false`, the page's `The server refused
the reconnect ...`, and within about 2 s a reload: new `page loaded` time,
new pid and start time, status `connected`. (Without the example's recipe,
13.6 expected the page to stay dormant until a manual reload.)

**Serve: SSH forward from another machine; `localhost` refused.** The
server runs `./examples/serve/serve` on machine A (an SSH server: macOS
with Remote Login on, Linux with `sshd`, Windows only with OpenSSH Server
installed, otherwise `n/a`). On machine B: `ssh -N -L 5359:127.0.0.1:5359
<user>@<A>`, then open `http://127.0.0.1:5359` there. Expect the page to
work (note round-trips). On B, `http://localhost:5359` is a 403 (`neel:
refused: the Host header must be 127.0.0.1:5359`). Restart the app on A as
`./examples/serve/serve http://localhost:5359`: now `http://localhost:5359`
on B works too. Killing the `ssh` process and starting it again is an
outage with the same token: the page goes dormant and wakes on a tab switch
(an alternative for the dormant row).

**Serve: an `--app:gui` build starts and serves** (Windows; the 13.2
check). `nim c -d:release --app:gui -o:$env:TEMP\serve-gui.exe
examples/serve/serve.nim`, then `& $env:TEMP\serve-gui.exe`. Expect no
console window, the page working at `http://127.0.0.1:5359`, and "Stop
server" ending the process (`Get-Process serve-gui` finds nothing).

**Serve: idle behind a proxy for 5 minutes without a reconnect.** Through
the cloudflared quick tunnel (below) or any of the drafts. Open the page at
the public URL, paste the console probe, leave the tab in the foreground
untouched for 5 minutes. Expect no `onclose` line, the status `connected`,
`reconnects: 0`. Optional: Firefox's WebSocket inspector (Network, the
`/ws` request, with control frames enabled in its filter) shows a ping and
its pong about every 30 s. Without pings Cloudflare would close the
connection after about 100 s and nginx after 60 s.

**cloudflared quick tunnel: the page works over `https` / `wss`.** On the
Linux server: `cloudflared tunnel --url http://127.0.0.1:5359` and note the
`https://<name>.trycloudflare.com` URL it prints. Opening it now gives a
502 (no app yet). Start `./examples/serve/serve
https://<name>.trycloudflare.com`; the startup line lists that origin. Open
the URL on a laptop: the page works; in the Network panel `/ws` is
`wss://<name>.trycloudflare.com/ws?...` with status 101. Restart the app
without the argument: the page is a 403 reading `neel: refused: the Host
header must be 127.0.0.1:5359`, since cloudflared forwards the public `Host`
(confirms 2.3 for cloudflared). If this all passes, drop "not yet verified"
from the guide's and the example's cloudflared text.

**Behind Cloudflare Tunnel with Access: first load after login works
(confirms 2.1).** Needs a Cloudflare account with a domain and Zero Trust.
Draft, not yet verified:

```
cloudflared tunnel login
cloudflared tunnel create neel-serve
cloudflared tunnel route dns neel-serve notes.<domain>
```

`~/.cloudflared/config.yml`:

```yaml
tunnel: neel-serve
credentials-file: /home/<user>/.cloudflared/<tunnel-id>.json
ingress:
  - hostname: notes.<domain>
    service: http://127.0.0.1:5359
  - service: http_status:404
```

Then `cloudflared tunnel run neel-serve`. In the Zero Trust dashboard add an
Access application (self-hosted, domain `notes.<domain>`) with a policy
that allows your e-mail address. Start `./examples/serve/serve
https://notes.<domain>`. In a private browser window, with DevTools'
"Preserve log" on, open `https://notes.<domain>`: log in on the Access page
(one-time PIN). Expect the redirect back to load the app (no 403); the
document request to `notes.<domain>` after the redirect from
`<team>.cloudflareaccess.com` shows `Sec-Fetch-Site: cross-site` and status
200; `/ws` is 101. Then the idle row through this setup. Optional
(`opaqueredirect`): in a fresh private window, log in, let the page connect,
then revoke the session in the dashboard (or wait out a short session
duration set on the application), stop the server with Ctrl-C and start it
again: the page's poll gets the Access redirect and reloads into the login
page instead of waiting forever.

**Phone: open, lock for 5 minutes, unlock: the page reconnects by itself.**
Through the quick tunnel or the Access setup. Open the page on the phone,
lock it for 5 minutes, unlock. Expect the status back to `connected` within
a few seconds, `reconnects` at least 1, and the `page loaded` time
unchanged (no reload). If the browser reloaded the tab instead (the
`page loaded` time changed), record it in 16.1; the page still works.

**Phone and laptop share the note; "Use it here" takes the session back.**
Save a note on the laptop; open the app on the phone: it shows the note and
the laptop reads `opened on another device`. Edit and save on the phone;
press "Use it here" on the laptop: it shows the phone's edit, and the phone
reads `opened on another device`.

**Server restart: the documented reload recipe recovers the page.** Through
the tunnel, on the laptop and on the phone:
- Connected page: Ctrl-C the server. The page shows `The server stopped.
  Waiting ...`; while the app is down the poll gets 502 from cloudflared and
  keeps waiting. Start the app again (same origin, same cloudflared): the
  page reloads by itself within about 2 s (new pid).
- Dormant page: make the page dormant (on the phone, lock it until the
  connection is gone; on the laptop, the DevTools offline toggle), restart
  the server, then wake the page (unlock, or go online). Expect the failed
  wake, then a reload (new pid). If the page shows `not connected; reconnects
  when ...` instead (its connection died unnoticed and the restart was
  first seen by an ordinary reconnect round, 16.1), switch away and back
  once: it then reloads.

**Draft: Tailscale Serve.** Not yet verified. On the server, with Tailscale
up:

```
tailscale serve --bg http://127.0.0.1:5359
tailscale serve status        # shows https://<machine>.<tailnet>.ts.net
./examples/serve/serve https://<machine>.<tailnet>.ts.net
```

Open the URL from another device on the tailnet: the page works, `/ws` is
101; then the idle row. `tailscale serve reset` turns it off. Record
whether Tailscale forwards the public `Host` or rewrites it (both are
accepted).

**Draft: nginx (with the `Upgrade` / `Connection` headers).** Not yet
verified. A site, with a certificate for the name:

```nginx
server {
    listen 443 ssl;
    server_name notes.example.com;
    ssl_certificate     /etc/ssl/notes/fullchain.pem;
    ssl_certificate_key /etc/ssl/notes/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:5359;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

Start `./examples/serve/serve https://notes.example.com`. Expect the page
to work (nginx sends `Host: 127.0.0.1:5359` by default, which passes; with
`proxy_set_header Host $host;` the public host passes too), then the idle
row (nginx's `proxy_read_timeout` is 60 s, so this is the real test of the
pings). Remove the two `proxy_set_header` lines and reload nginx: the page
loads but `/ws` fails (Neel answers a plain `GET /ws` with 403) and the
shim goes dormant, which is why the guide asks for the headers. For a
quick test without a certificate: `listen 8081;` and the origin
`http://<server name>:8081`.

**Draft: Caddy.** Not yet verified. `Caddyfile`:

```
notes.example.com {
    reverse_proxy 127.0.0.1:5359
}
```

Caddy obtains the certificate, proxies WebSockets without extra
configuration, and forwards the public `Host`. Start
`./examples/serve/serve https://notes.example.com`; expect the page to
work, then the idle row. For a quick test without a domain: `caddy
reverse-proxy --from :8082 --to 127.0.0.1:5359` and the origin
`http://<server name>:8082`.

---

## 14. Documentation

- **README:** a short "Serve mode" section after "Compilation" with the
  minimal example and a link to the guide.
- **Guide:** a "Serve mode" section covering: when to use it; `serve`,
  `allowedOrigins`, and the validation rules; the virtual window and
  displacement (code 4000); hooks; the security model (section 12); the
  reconnect behavior and the reload recipe; known-good proxy setups
  (cloudflared, Tailscale Serve, nginx, Caddy, SSH forward), each verified on
  a real setup before publishing. As shipped in step 7 (agreed with the
  user): the SSH forward and the cloudflared quick tunnel, the latter marked
  "not yet verified"; Tailscale Serve, nginx, Caddy, and Cloudflare Tunnel
  with Access exist only as drafts in 13.8 and move into the guide once
  verified. The guide names no proxy in the section 12 header note; it says
  generically that some proxies need the `Upgrade` / `Connection` headers.
- **Guide updates elsewhere:** `startApp` parameter table (two rows); the
  `neel.onclose` row (code 4000); the Caveats entry "Neither side closes an
  idle connection on its own" (true locally, not behind proxies; serve mode
  pings after 30 s of silence); the fixed-port caveat (1000 becomes 4000,
  and a second app on a taken fixed port now fails at start on Windows too).
- **Guide, the shim (from step 6):** the dormant state and when it wakes
  (section 10.3 "As built"), including that a call while dormant rejects
  with `neel: not connected; reconnects when the page becomes visible or goes
  online` and does not wake the shim, and that a page dormant while visible
  and online waits for a tab switch, a network change, or a reload. The
  `neel.onreconnect` row becomes "every successful connection except the one
  that resolves `neel.ready`" (a wake after a shim that never connected
  fires it). The `neel.ready` row: in serve mode a rejected `ready` does not
  mean the shim has stopped. The "gave up" text and the reconnect paragraph
  (around "reconnects up to 5 times") need the serve-mode exception. For the
  reload recipe (10.4): in serve mode an `onclose(code, false)` with a code
  other than 1000, 1001, or 4000 means the shim went dormant; a page can
  reload when that happens right after a wake event (a failed wake), never
  on 4000.
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
  but matters for serve mode, which always uses a fixed port. Fixed in step
  5: Windows now binds with `SO_EXCLUSIVEADDRUSE` (section 8, 16.2), and
  `t_neel`'s `occupyPort` is a plain listener again.
- 2026-10-15, step 4, Windows: console apps that load `user32.dll` or
  `gdi32.dll` never receive `CTRL_LOGOFF_EVENT` / `CTRL_SHUTDOWN_EVENT`
  (Microsoft `SetConsoleCtrlHandler` docs). A Neel serve binary imports only
  `KERNEL32`, `msvcrt`, and `WS2_32`, and loads `Advapi32`, `Bcrypt`,
  `kernel32`, and `Ws2_32` at runtime (checked with `objdump -p` and the
  generated C), so it does receive them. Section 7 updated; for the step 7
  guide.
- 2026-10-15, step 4, macOS and Windows: the user ran `nimble test` and the
  step 4 manual checks on both; everything passed (13.4 "Results", 13.8).
  This was the first real compile and run of the POSIX signal code. Windows
  Ctrl-Break was sent with `GenerateConsoleCtrlEvent` (no Break key). Linux
  is deferred to the final pass because Ubuntu runs in VirtualBox on the
  Windows machine; 13.0 updated (the step-5 checkpoint is macOS and Windows
  only, so epoll is first exercised at the end). Steps 1–3 have not run on
  Linux either.
- 2026-10-15, step 5, Windows: Windows bind options, probed on Windows 11
  loopback (ad-hoc program, not in the repo). Two listeners on one port
  succeed only when both set `SO_REUSEADDR`; every other pairing fails (a
  plain or exclusive socket after a `SO_REUSEADDR` one, or a `SO_REUSEADDR`
  one after a plain or exclusive one, which fails with "access forbidden").
  After the server closed an accepted connection first (one TIME_WAIT entry
  on the port, seen in `netstat`) and closed its listener, an immediate
  rebind succeeded with `SO_REUSEADDR`, with no option, and with
  `SO_EXCLUSIVEADDRUSE`. Microsoft's documentation warns about exclusive
  ports and TIME_WAIT; this did not occur here. Basis for the exclusive
  bind (section 8); `t_server` pins both halves.
- 2026-10-15, step 5, Windows: the session ran on Windows 11 again; `nimble
  test` passed three times (109, 93, and 91 s) and the ping suite 17 times
  (including three copies in parallel), without a flake. Only the `select` backend ran;
  kqueue and epoll were type-checked (`nim check --os:macosx` /
  `--os:linux`). `std/selectors` picks the backend; `server.nim` has no
  backend-specific code, so the ping timer is the same on all three.
- 2026-10-15, step 5, macOS and Windows: the user ran `nimble test` several
  times back to back on both; all passed, the ping suite included (its
  first run on kqueue). The step-5 checkpoint is therefore green on macOS
  and Windows; epoll (Linux) is first run in the final pass (13.0). The
  two-instance and restart check also passed on both, so the exclusive
  bind holds between real processes on Windows, and a restart with a
  connected page still binds.
- 2026-10-15, step 5, all: the IO loop wakes at most every `IoTickMs`
  (250 ms) or at the earliest deadline, and only `csWebSocket` connections
  shorten the timeout for pings. A test that looks for a ping during a
  close therefore needs a close timeout well above the interval: with the
  default fixture (500 ms close, 300 ms interval) the loop's next wake-up
  after the ping fell due was the close deadline itself, so a mutation that
  pinged closing connections passed unnoticed.
- 2026-10-15, step 5, Linux: the first Linux `nimble test` failed one check
  in `t_neel` ("a port that is taken..."): after the first serve run that
  installed and removed the stop handlers, `SIGTERM` read back as
  `{SIG_DFL, SA_RESTORER}` instead of `{SIG_DFL, 0}`. glibc's x86-64
  `sigaction` always ORs `SA_RESTORER` into the flags it passes to the
  kernel, and a never-touched `SIGTERM` starts with a true 0, so the restore
  is correct but not bit-identical. Fixed in the test: `actionOf` masks
  `SA_RESTORER` on Linux. Every other `t_neel` test passed on that run,
  including the epoll path and both signal tests.
- 2026-10-15, after step 5, Linux: with that fix, `nimble test` passed on
  Ubuntu (VirtualBox), as did the step 4 POSIX manual checks (Ctrl-C,
  `kill -TERM`, second signal exiting 130 / 143) and the step 5
  two-instance and restart check. This is the first Linux run of steps
  1–5, so all five are green on macOS, Windows, and Linux. Not yet run on
  any OS: the examples (13.8 local-mode rows), which the final pass covers.
- 2026-10-15, step 6, Windows: the session ran on Windows 11; `nimble test`
  passed with `node` v24.20.0 on PATH, so the new shim behavior test ran
  (84 harness checks, about a second). The harness needs only Node built-ins
  (`vm`, `fs`) and ES2020; no npm. The user will install `node` on macOS and
  Linux so the test runs there too; without it the test is `[SKIPPED]`.
- 2026-10-15, after step 6, Linux and macOS: the user ran `nimble test` on
  both; both passed, with the node test `[OK]` on each (nothing skipped; on
  Linux the first run of the harness on POSIX, with the LF working copy of
  `neel.js`), so the
  CRLF/LF difference does not affect the text checks. Steps 1–6 are green on
  macOS, Windows, and Linux; still not run on any OS: the examples and the
  browser checks (13.6, 13.8), which the final pass covers.
- 2026-10-15, step 6, Windows: the Windows working copy of `neel.js` has
  CRLF line endings (`git ls-files --eol`: `i/lf w/crlf`), so
  `NeelJsSource` (`staticRead`) holds CRLF on Windows and LF on POSIX. Text
  checks on the shim must split with `splitLines` and never look for `"\n"`;
  ad-hoc replacements on a Windows copy must match `"\r\n"`. The rendered
  shim works either way.
- 2026-10-15, step 6, all: in the DevTools console, `neel.call("x")` is a
  convenient probe of the shim's state: answered by the server with
  `NeelUnknownProcError` while connected, rejected at once with the dormant
  message while dormant and with `neel: connection is closed` once
  terminated. Used by the 13.6 manual checks.
- 2026-10-16, step 7, Windows: the session ran on Windows 11; `nimble test`
  passed with the node shim test `[OK]`, and `nim c src/neel.nim` passed.
  All four examples compiled; `examples/serve` ran in debug and release.
  `cloudflared` is not installed on this machine, so the quick tunnel stays
  "not yet verified".
- 2026-10-16, step 7, all: section 10.1 (and the step 3 notes) said a final
  close rejects pending and later calls with `neel: server closed the
  connection (close code N)`. The shim never did that: `ws.onclose` calls
  `failPending("neel: connection lost (close code N)")` before the
  terminating branch, and later calls get `neel: connection is closed`.
  `terminate`'s reason only reaches queued calls and an unsettled
  `neel.ready`, and neither exists when the close arrives on an open socket.
  The harness and the frozen reference agree with the code. Docs only: 10.1
  corrected, the guide documents the real texts, and the stresstest page no
  longer quotes the message (it quotes its own status line).
- 2026-10-16, step 7, all: the reload recipe misses one case. When the
  connection died unnoticed (a phone locked while the server restarted, so
  the 1001 never arrived), the page's first reconnect round after unlocking
  is an ordinary one, not a wake; its 403s end it dormant, and the page
  reloads only after the next wake event (a tab switch or another unlock),
  which then fails as a wake. Documented in the guide and in 13.8, not
  changed (the triggers are the agreed ones of 10.4).
- 2026-10-16, step 7, all: the 13.6 check "local mode give-up still
  terminal" cannot be run with the DevTools offline toggle: the server sees
  the close, a debug build's 3 s grace period ends the app, and teardown
  closes the browser window before the shim's 7.75 s of attempts are over.
  13.8 uses a killed server instead (the stresstest page's "Reconnect and
  give up"); a killed app leaves its browser window open.
- 2026-10-16, step 7, all: `examples/serve`'s note is a module-level string
  written by whichever worker saved it, so it outlives that worker once the
  pool shuts down. That is the cross-thread free Nim >= 2.2.12 handles (and
  Neel requires); no Neel state is involved. The example also keeps pid and
  start time in plain `int` / `int64` globals written before `startApp`, so
  only the note needs `{.cast(gcsafe).}`.
- 2026-10-16, step 7, all: `std/parseopt` with default settings takes an
  option's value only after `=` or `:`, so `serve --port 8080` reads an
  empty value and the example exits with `serve: --port expects a number,
  got ""`. The docs write `--port=N`.
- 2026-10-16, step 7, Windows: ad-hoc HTTP checks from Node: `fetch` (undici)
  drops a `Host` header silently, so a wrong-`Host` request needs
  `node:http`. The `/ws` upgrade with a chosen `Origin`, and the calls over
  it, were done on a raw `net` socket (hand-written handshake and masked
  frames), which controls every header.
- 2026-10-16, final pass, Windows (Chrome): in `examples/roundtrip`,
  closing window 2 with its X while the "askSecond" prompt is up gives
  `PromptCancelled`, not `NeelDisconnectedError` (twice). Chrome dismisses
  the dialog first, so `prompt` returns `null`, `second.js` throws, and
  the shim sends that reply before the socket closes. Not a Neel issue
  (local mode, unchanged since 2.0). Force-killing window 2's browser
  process during the prompt gives `NeelDisconnectedError: connection 11
  closed while waiting for id 1`, which is the path the check is after.
  The 13.8 procedure now says so.
- 2026-10-16, final pass, Windows: **fail**, row "Local: Ctrl-C ends a
  local-mode app the old way". Debug build of `examples/roundtrip` (built
  this session from `5a4fb0d`, Nim 2.2.12), run in the user's PowerShell,
  Ctrl-C once after `window 1 opened`. Verbatim:

  ```
  PS C:\Users\leonl\OneDrive\Desktop\deleteme\Neel> .\examples\roundtrip\roundtrip.exe
  window 1 opened
  PS C:\Users\leonl\OneDrive\Desktop\deleteme\Neel> $LASTEXITCODE
  -1073741819
  ```

  No `SIGINT: Interrupted by Ctrl-C.` and exit code `0xC0000005`
  (`STATUS_ACCESS_VIOLATION`) instead of 1: the process crashed. The same
  check passed after step 4 (13.4 "Results").
  Diagnosis the same day (no code changed; binaries under `$env:TEMP`,
  gcc MinGW-W64 x86_64-posix-seh 11.1.0 from `~/.nimble/bin`): debug
  `roundtrip` crashed the same way 3 more times out of 3, after a pause of
  about a second; a release `roundtrip` printed `SIGINT: Interrupted by
  Ctrl-C.` and exited 1; a bare Nim program with no Neel
  (`while true: sleep(100)`) crashed identically as a debug build
  (`-1073741819`, no message) and was correct as a release build (message,
  exit 1). Verbatim (partial, the terminal was cleared):

  ```
  PS C:\...\Neel> & $env:TEMP\neel-ctrlc\roundtrip-release.exe
  window 1 opened
  SIGINT: Interrupted by Ctrl-C.
  PS C:\...\Neel> & $env:TEMP\neel-ctrlc\bare-debug.exe
  bare: running, press Ctrl-C
  PS C:\...\Neel> $LASTEXITCODE
  -1073741819
  PS C:\...\Neel> & $env:TEMP\neel-ctrlc\roundtrip-release.exe
  window 1 opened
  SIGINT: Interrupted by Ctrl-C.
  PS C:\...\Neel> $LASTEXITCODE
  1
  PS C:\...\Neel>  & $env:TEMP\neel-ctrlc\bare-release.exe
  bare: running, press Ctrl-C
  SIGINT: Interrupted by Ctrl-C.
  PS C:\...\Neel> $LASTEXITCODE
  1
  ```

  So it is Nim's own debug-build `SIGINT` handler, not Neel: local mode
  installs no handler, and the crash needs no Neel code. Likely cause
  (unverified): on Windows the C runtime runs that handler on a console
  thread Windows creates, and the debug handler writes a stack trace
  through thread-local state (`framePtr`, MinGW emulated TLS), the hazard
  noted for step 4 above; Nim's `excpt.nim` says as much ("the signal
  handler is called from a non-Nim thread and any allocation will
  (likely) cause a crash"). Why it passed after step 4 is not known.
  Not fixed, by the user's decision: documented in the guide (Caveats,
  and a pointer from "Stopping a server"); the 13.8 row is a pass on
  release builds.
- 2026-10-16, final pass, Windows (Chrome): DevTools Network throttling
  "Offline" does not close an open WebSocket: no `onclose`, the page stays
  `connected`. The dormant row was run with an outage instead: a Node TCP
  relay on `127.0.0.1:5360` to the server (started with that origin
  allowed), stopped and restarted (ad hoc, under `$env:TEMP`).
- 2026-10-16, final pass, Windows: cloudflared 2026.10.1 (winget) quick
  tunnel to `examples/serve`: 502 before the app was up; with the tunnel
  URL as the allowed origin the page worked in Edge and stayed connected
  about 10 min untouched (no `onclose`, so the 30 s pings hold Cloudflare
  open); restarted without the argument, the tunnel got `403` `neel:
  refused: the Host header must be 127.0.0.1:5359`, so cloudflared forwards
  the public `Host` (2.3). Not yet run on Linux, where the quick-tunnel row
  of 13.8 belongs; the guide still says "not yet verified".
- 2026-10-16, final pass, macOS 13.7.8 (Intel, Chrome 155): every 13.8 row
  passed on `69ff8a1`; nothing failed. Debug builds of all four examples
  with Nim 2.2.12 (`~/.nimble/bin/nim`). Notes for the record:
  - Unlike Windows, closing `roundtrip`'s window 2 with its close button
    while the "askSecond" prompt is up gives `NeelDisconnectedError`, not
    `PromptCancelled` (Chrome on macOS does not dismiss the dialog first),
    so no process kill is needed there. Either path is local-mode behavior
    unchanged since 2.0.
  - Local Ctrl-C on a **debug** `roundtrip` printed `SIGINT: Interrupted by
    Ctrl-C.` and exited 130: the Windows debug-build crash (above) does not
    occur on macOS.
  - The serve signal rows were driven with `kill -INT` / `kill -TERM` from
    another shell instead of Ctrl-C (same signal; a page connected each
    time received the 1001). Second signal: 130 and 143 at once, with
    `closed.txt` written and no `returned` line.
  - The two dormant rows used the Windows relay outage (a Node TCP relay on
    `127.0.0.1:5360`, server started with that origin). Stopping the relay
    must also destroy the connections it carries, or the open WebSocket
    survives. With no `online` event in that setup, every wake was a tab
    switch.
  - SSH forward: Mac as server (Remote Login on), Windows as client;
    `http://localhost:5359` got the 403 until the app allowed that origin,
    and killing and restarting `ssh` was an outage the page woke from.
  - The Homebrew `cloudflared` formula has bottles only for Apple Silicon
    (and Linux), so on Intel macOS it builds from source. Cloudflare's
    release binary `cloudflared-darwin-amd64.tgz` (2026.10.1), unpacked
    under `/tmp`, was used instead. Quick tunnel: 502 before the app, 200
    after; the page stayed connected about 10 min untouched, and the
    server held one WebSocket from `cloudflared` throughout (checked with
    `lsof`), so the pings hold Cloudflare open on kqueue too.
  - Running the examples from an agent shell: a plain `&` job is killed
    when the agent's command ends (the app window then shows "connection
    refused"); run them as a backgrounded tool command. Chrome inherits the
    app's stdout, so a pipe on it stays open until the app's windows close.

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
- 2026-10-15, step 5: "last read or write" made precise (agreed with the
  user): successful reads and writes of more than 0 bytes, the upgrade, and
  queueing a ping restart the idle time. Without the last one, a peer whose
  socket is backed up would get a new ping on every loop pass. A ping is
  also skipped when `closing` is already set. Section 8 "As built" added.
- 2026-10-15, step 5: the Windows `SO_REUSEADDR` finding of step 4 (16.1) is
  fixed in this step at the user's request: `openListener` uses
  `SO_EXCLUSIVEADDRUSE` on Windows. This adds a second local-mode
  difference (on Windows, a second app on a taken fixed port fails at
  start). Sections 1, 8, 11, and 14 updated; the 13.8 matrix gained a row.
  The `neel-project` rule's "only accepted difference" wording now points
  at section 11's list.
- 2026-10-15, step 5: proving `runApp`'s interval needed a test hook (the
  user chose a recording hook over 30 s waits): `testhooks` gained
  `PingObserver`, `setTestPingObserver`, and `testPingObserver`, so step 5
  also touches `testhooks.nim`. `server.nim` gained the read-only
  `pingIntervalMs(server)`. Sections 6 and 13.5 updated.
- 2026-10-15, step 6: section 10.3 made precise (agreed with the user):
  wake events matter only while dormant (so a burst starts one wake); a wake
  connects at once, then backs off as usual; a failed wake ends like the
  first give-up and goes dormant again; a dormant call rejects with a new
  message and does not wake; `onreconnect` fires after a successful wake even
  if the shim never connected, so its rule becomes "every open except the
  one that resolves `neel.ready`"; `neel.close()` while dormant terminates
  with `onclose(1000, false)`; listeners only in serve mode. Sections 10.3
  ("As built") and 14 updated.
- 2026-10-15, step 6: the shim's behavior is tested with an opt-in node
  harness (`tests/fixtures/shim_harness.js`, run by `t_frontend` when `node`
  is on PATH, skipped otherwise), and local mode is proven unchanged by
  comparing traces against a frozen copy of the pre-serve shim
  (`tests/fixtures/shim_reference.js`). Agreed with the user; test-only, no
  runtime or Nimble dependency. Step 6 also touches `neel.nim` (the call
  site and one header line) and `t_neel`. The 13.6 Touches line updated.
- 2026-10-16, step 7: proxy setups in the shipped docs are the SSH forward
  and the cloudflared quick tunnel, the latter marked "not yet verified";
  Tailscale Serve, nginx, Caddy, and Cloudflare Tunnel with Access are
  drafts in 13.8 only, to move into the guide once the user verifies them.
  Section 12's nginx header note appears in the guide without naming a
  proxy. Agreed with the user. Section 14 updated.
- 2026-10-16, step 7: the reload recipe waits for the server before
  reloading (poll every 2 s, reload on `ok` or `opaqueredirect`; errors and
  5xx keep polling) instead of reloading at once. Agreed with the user.
  Section 10.4 updated.
- 2026-10-16, step 7: section 10.1's description of the final-close
  rejection texts corrected to what the shim has always done (16.1). No
  code change; the guide follows the code.

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
  it ahead of any dormant or reconnect path. (Kept in step 6: `ws.onclose`
  is unchanged, and `t_frontend` checks the branch in both renderings.)
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
- **`lastActivity` belongs to the IO thread.** It is written in `readFrom`,
  `flush`, the upgrade, and `processPings`, never under the lock and never
  from a worker. Anything new that sends or receives on a connection goes
  through `flush` / `readFrom` (or sets it there), or it will not count as
  activity.
- **A ping is a write on the wire, not a message.** It goes into `outbound`
  under the lock and out through `flush`, never with a direct `rawSend`, and
  never once `closing` is set (a close frame may already be queued).
- **Ping tests: the echo fixture hides read-only activity.** `t_server`'s
  fixture echoes every message, so a message is always also a write. Test
  that reads count with a pong (read, never answered), and that writes count
  with `srv.send` alone.
- **Ping tests during a close need a long close timeout.** The loop wakes
  every `IoTickMs` or at the earliest deadline, so with a close timeout near
  the interval a stray ping on a closing connection may never get its turn
  (16.1). The ping fixture uses `PingCloseTimeout` = 4 intervals.
- **Two servers on one port fail on every OS.** Windows binds with
  `SO_EXCLUSIVEADDRUSE`, POSIX with `SO_REUSEADDR`; in both cases `listen` on
  a port that is already listening raises `OSError`, and a port is rebindable
  right after shutdown. A test that needs a taken port can use a plain
  listener (`t_neel`'s `occupyPort`).
- **Compare signal actions without `SA_RESTORER`.** On Linux glibc sets it
  on every action it installs, so a restored action can differ from the
  original in that bit alone. `t_neel`'s `actionOf` masks it; any new check
  of `sigaction` flags must do the same.
- **Local shim behavior has an oracle.** `tests/fixtures/shim_reference.js`
  is the shim as it was before serve mode, frozen. The node harness requires
  the local rendering (and, where serve mode must not differ, the serve
  rendering) to leave exactly its trace in every shared scenario. Changing
  local shim behavior on purpose means updating the reference and the
  harness in the same step and saying so in 16.2; comments and refactors
  need nothing.
- **The node test can be skipped.** Without `node` on PATH, "frontend: shim
  behavior under node" is `[SKIPPED]` and `nimble test` is still green. When
  reporting a run, say whether it ran (`[OK]`) or was skipped.
- **The harness duplicates the shim's messages.** `shim_harness.js` checks
  the exact rejection texts (`GAVE_UP`, `DORMANT`, `CLOSED`) and the backoff
  delays; changing them in `neel.js` means changing them there too. Call
  labels in a scenario must be unique (`result` finds the first one).
- **The serve-only lines of the shim are pinned by text.** `t_frontend`
  "serve-only code is reachable only through the flag" compares exact lines:
  every `SERVE` read, the `goDormant` call, the give-up block in
  `scheduleReconnect`, and the listener block. Rewording those lines means
  updating that test; adding a new `SERVE` read means adding it there, on
  purpose.
- **`renderNeelJs` takes `serve` explicitly.** It has no default; a new
  caller (or test) states the mode. The served shim's mode comes from
  `AppState.serve`.
- **The docs quote texts verbatim.** `README.md`, `docs/GUIDE.md`, the
  `examples/serve` header, and 13.8 quote the startup line, the
  `checkServeParams` and `normalizeOrigin` `ValueError`s, the
  `NeelServeModeError` from `openWindow`, the 403 texts, and the shim's
  rejection messages (`connection lost`, `connection is closed`, `gave up
  reconnecting`, the dormant one). Changing any of them means updating
  those places too (and `shim_harness.js` for the shim's).
- **The shim's wake listeners run before the page's.** The shim adds its
  `visibilitychange` and `online` listeners when `/neel.js` runs, before the
  page's scripts, so a page listener on the same event finds the shim
  already reconnecting: a call it makes is queued, not rejected as dormant.
  The guide states this. The recipe's flag does not depend on it (it reads
  the page's own state, which changes only in `onclose`), but moving the
  shim's listeners later (to `DOMContentLoaded`, say) changes what such
  calls do.
