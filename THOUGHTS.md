# Review of DISCUSSION.md (headless mode)

Reviewed against `README.md`, `docs/GUIDE.md`, and the source in `src/`
(`neel.nim`, `neel/frontend.nim`, `neel/window.nim`, `neel/server.nim`,
`neel/neel.js`, `neel/browser.nim`, `neel/assets.nim`, `neel/http.nim`,
`neel/testhooks.nim`). Nothing was run.

## Verdict

The direction is sound and most of the factual description of the current code
is accurate: the line references are right, the quoted snippets match the
source, and the "what already works" section is correct. But the **request
filtering design (`allowedHosts`) would not work as specified** behind a real
tunnel, there is an **unmentioned blocker in the `Sec-Fetch-Site` check**, and
the doc underestimates how much of the client-side connection behavior (the
reconnect policy and the lack of keep-alives) matters once the browser is on a
phone and behind a proxy. The "~50 lines, no changes to `server.nim` or
`neel.js`" estimate is optimistic.

Not one of these problems is a reason to drop the feature. They are reasons to
revise the spec before writing code.

---

## 1. What the doc gets right

These claims check out against the source:

- **`requestRefusal` blocks remote access** (`frontend.nim` 90–113). The quoted
  code is exact.
- **Lifecycle is browser-centric**: `runApp` calls `findBrowser`, then
  `openWindow(startPath)` (`neel.nim` 351, 369), then `waitForAppExit`.
- **Exit on zero connections / startup timeout** (`window.nim` 645–656).
- **Token is per-launch** (`neel.nim` 122–129, 352).
- **`wsUrl()` derives scheme and host from `location`** (`neel.js` 262–266), so
  the shim already produces `wss://myapp.example.com/ws?...` behind TLS.
- **Displacement already exists**: `bindConnection` closes the previous
  connection of the same window with 1000 (`window.nim` 311–321), and the shim
  treats 1000 as final (`neel.js` 315–318), so the displaced device does not
  fight back. One device at a time really is already implemented.
- **Single-window fallback in `neelJsWindowId`** (`neel.nim` 237–239): a page
  with no `?window=` gets the only open window's shim. So visiting
  `https://myapp.example.com/` would work.
- **The `127.0.0.1` bind is fine for tunnels** (`server.nim` 294).
- **Single-user, not a web framework.** This is the right scope and the
  reasoning in "Design Decisions" is good.
- **"Keep state in Nim, hydrate on load"** is the right pattern, and it matches
  what the guide already recommends for `onWindowOpen` (GUIDE "Multiple
  windows": ask for initial data with a `neel.<name>()` call).

---

## 2. Errors in the doc

### 2.1 `allowedHosts` as specified would refuse every tunneled request

The doc says the Host check would accept "`<host>:<port>` for each host in the
list", where `<port>` is Neel's bound port. Behind a tunnel or proxy the
browser's view of the port is **not** Neel's port:

- Cloudflare Tunnel / any HTTPS proxy on 443: the browser sends
  `Host: myapp.example.com` and `Origin: https://myapp.example.com`, with no
  port at all. Neel is listening on, say, 8080. `myapp.example.com:8080` never
  matches.
- `isOwnHost` only special-cases port 80 (`frontend.nim` 84–88). Port 443
  is never omitted-and-matched.
- Some proxies rewrite `Host` and others preserve it. nginx's default
  `proxy_pass http://127.0.0.1:8080` sends `Host: 127.0.0.1:8080`, which
  already passes. Caddy, cloudflared, and (as far as I know) `tailscale serve`
  preserve the public host. **`Origin` is never rewritten**, so it is the check
  that actually has to change.

**Suggestion:** make the parameter a list of full origins, e.g.
`allowedOrigins = @["https://myapp.example.com"]`, compared as exact strings
(scheme + host + optional port, as the browser sends them). Then:

- `/ws` `Origin` must be `http://127.0.0.1:<port>` **or** one of the entries.
- `Host` must be `127.0.0.1:<port>` **or** the host[:port] part of an entry.

This handles the scheme, the omitted default port, and non-standard public
ports (`https://box.tailnet.ts.net:8443`) correctly. It also drops the
doc's "accept both `http://` and `https://` for each host" rule, which loosens
things for no reason.

### 2.2 The `Sec-Fetch-Site` analysis contradicts itself, and misses the real problem

Under "What Blocks Remote Access" the doc says `Sec-Fetch-Site` "may be
`cross-site`" and cause a 403. Later it correctly says that a page on
`myapp.example.com` loading its own resources is same-origin. The second
statement is right **for subresources and the WebSocket**.

But it misses a real blocker: **top-level navigations that arrive from another
site carry `Sec-Fetch-Site: cross-site`**, and `requestRefusal` refuses
*every* request with that header (`frontend.nim` 105–106), including the HTML
page itself. In local mode this never happens, because Neel launches the
browser straight at the URL (`Sec-Fetch-Site: none`). In headless mode it
happens all the time:

- clicking a link to your app from chat, email, a notes app, or a start page;
- **the redirect back from an auth proxy login** (Cloudflare Access, Authelia,
  oauth2-proxy). The navigation chain started on the auth domain, so the
  browser marks the final request to your app as cross-site. I'm fairly
  confident of this from how Fetch Metadata works, but it should be checked
  against a real Access setup.

The doc's recommended deployment (Cloudflare Access) could therefore 403 on the
first page load after login.

**Suggestion:** the cross-site check only has to protect `/neel.js`, which is
the only response that carries the token. `/ws` is already protected by the
`Origin` check, and static assets are public anyway. Either restrict the
cross-site refusal to `/neel.js` (simplest), or skip it for
`Sec-Fetch-Mode: navigate`. Doing this in both modes is harmless locally,
because the `Host` check still guards everything there.

### 2.3 "The virtual window is never retired" understates the `window.nim` change

The doc frames the lifecycle change as "`waitForAppExit` ignores
`erLastWindowClosed` and `erStartupTimeout`." That is only half of it.
`waitForAppExit` also **retires individual windows** (`window.nim` 606–640):

- a window that never connected within `startupTimeoutMs` (30 s by default) is
  retired;
- a window whose connection has been gone for `gracePeriodMs` is retired.

Either rule would delete window 1 in headless mode. A server started with
nobody connecting for 30 s would lose its only window, and after that
`windows()` is empty, so every `/neel.js` request returns 404. The app stays up
but nobody can use it. The doc does say "never retired" in the implementation
plan, which is right. The point is that this is the retirement loop, not just
the two exit returns, and it should be spelled out and tested.

### 2.4 `onWindowClose` does fire in headless mode

The table says `onWindowClose` "Does not fire (the virtual window is never
closed)". `teardownWindows` fires it for every window still open at shutdown
(`window.nim` 270–279), so it fires once after `quitApp()`. That is probably
the behavior you want; the table should just say so.

### 2.5 The `allowedHosts` local-mode use case doesn't hold up

Open question 5 and the `allowedHosts` section justify using it without
`headless` "for a LAN hostname like `mypc.local:8080`". A LAN device cannot
reach a server bound to `127.0.0.1` (the doc even says this two sections
earlier). The only way it works is through a local reverse proxy, and then the
port in the URL is the proxy's, not Neel's (see 2.1). In local mode the browser
is launched at `127.0.0.1` anyway. **Recommendation: don't support it outside
headless mode.** It adds a security knob with no real use case.

### 2.6 Smaller inaccuracies

- **"`startApp` macro forwards `headless` and `allowedHosts`"**: the macro
  already forwards every unknown keyword argument verbatim to `runApp`
  (`neel.nim` 443–444, 458–459). Only `runApp`'s signature changes.
- **"Only `quitApp()` or process signal" as the exit trigger**: Neel installs
  no signal handlers (nothing in `src/` does). Ctrl-C and SIGTERM kill the
  process without `shutdown`. In headless mode there is no browser or profile
  directory to clean up, so this is mostly harmless, but it isn't a *clean*
  exit. See open question 6 below.
- **The token is described as what keeps other sites out.** In practice the
  `Origin` check on `/ws` does that; the token is defense in depth. This
  matters for how the security section is worded: in headless mode the
  security rests on `allowedOrigins` being exact.
- **"Files that need no changes"** includes `neel.js` and `server.nim`. They
  don't *have* to change for a minimal version, but see section 3: the
  experience on phones and behind proxies is noticeably worse without changes
  there.
- **"No existing code paths are modified, only branched around"**:
  `requestRefusal`'s logic does change, and the cross-site change from 2.2
  should apply in both modes.

---

## 3. Gaps the doc doesn't cover

### 3.1 Idle connections behind proxies get closed

The guide says "Neither side closes an idle connection on its own, so there is
no need for a keep-alive" (GUIDE Caveats). That is true on loopback and false
behind proxies. Cloudflare closes idle WebSockets after about 100 s, and
nginx's default `proxy_read_timeout` is 60 s. The server never sends pings (it
only answers them, `server.nim` 514–516) and the shim doesn't send any either.

What happens then: the proxy drops the socket, the shim sees an abnormal close
and reconnects, which usually works. But every in-flight `neel.foo()` and
`js.wait` on that connection fails with `NeelDisconnectedError`, and the app
sees `onclose` / `onreconnect` churn every minute or two.

**Suggestion:** have the IO thread send a WebSocket ping every ~30 s on idle
upgraded connections (headless only, or always; it's cheap). Browsers answer
pings automatically, so `neel.js` needs no change for this. This is a
`server.nim` change.

### 3.2 Phones will often end up with a dead page

The shim reconnects at most 5 times over 7.75 s, then terminates permanently
until the page is reloaded (`neel.js` 269–277; GUIDE "Reconnect"). Mobile
browsers routinely kill sockets of backgrounded tabs and throttle timers. The
common "from my phone" flow (open the app, lock the phone, come back 5 minutes
later) will usually find the shim already terminated and every call rejecting.

The same applies to a server restart: the old token is gone, so reconnects get
a 403 and the shim gives up. The doc says "the client would just reload the
page", but nothing reloads it automatically.

Options, roughly from least to most invasive:

1. **Document an app-level recipe**: in `neel.onclose((code, reconnecting) =>
   ...)`, reload when the shim gives up. **Careful:** the reload must not
   happen on a displacement close. Otherwise two open devices reload, displace
   each other, and loop forever (see 3.3).
2. **Shim change**: in headless mode, also retry on `visibilitychange` (page
   becomes visible) and `online`, and/or retry without a cap with a capped
   backoff.

At least option 1 belongs in the guide section.

### 3.3 A displaced device can't tell it was displaced

Displacement sends close code 1000 (`window.nim` 321), the same code as
`closeWindow`. The old device can't tell "you were opened on another device"
apart from "the app closed this window", and it can't tell either from "give
up" without guessing. For a good UX ("This app is open on another device,
click to take it back") it needs a distinct signal.

A custom close code in the 4000 range is the obvious choice. But the shim
treats any code other than 1000/1001 as abnormal and *reconnects*
(`neel.js` 315–319), which would make two devices displace each other forever.
So this needs a coordinated `neel.js` change: a "displaced" code the shim
treats as final and exposes through `onclose`. Alternatively, use 1000 with a
reason string the shim passes through. It's worth deciding this before the
first release, because a close code is part of the wire contract.

### 3.4 A displaced device's in-flight work moves to the new device

`js` targets the *window*, resolved to its current connection at call time
(`resolveWindow`, `window.nim` 393–405). If an exposed proc started by the
desktop is still running when the phone displaces it, the proc's
`js.foo(...)` / `js.wait.foo(...)` calls go to the phone. That's the same as a
page refresh today, so it isn't new, but it is more surprising across devices.
One line in the docs covers it.

### 3.5 `startPath` has no meaning in headless mode

`startPath` only determines the launch URL. In headless mode the user types a
URL, so an app with `startPath = "/app.html"` and no `index.html` gets a 404 at
`/`. The doc's "ignored parameters" list should include `startPath`, or
headless mode should serve `startPath` for `/`.

### 3.6 Exposure of the HTTP server itself

Behind a tunnel this is mostly the tunnel's problem, but for completeness: the
server has sensible parse limits (16 KiB headers, 1 MiB body, no
`Transfer-Encoding`, `http.nim` 29–32, 221–238) and path containment in
`assets.nim`. There is **no idle timeout for plain HTTP connections**, though
(deadlines only exist for closing connections, `server.nim` 376–378 and
641–648). That's fine for loopback and a tunnel, but it's a slowloris vector if
someone points a public proxy at it without timeouts. Worth one sentence in the
security section ("put a real proxy in front"), not engineering work.

### 3.7 Tests are missing from the plan

The repo has thorough tests (`t_frontend`, `t_window`, `t_neel`, ...). The
plan should list the new cases at least:

- `requestRefusal` with `allowedOrigins` (match, port mismatch, scheme
  mismatch, `Host` rewritten to loopback);
- a cross-site navigation passing while a cross-site `/neel.js` is refused;
- window 1 surviving past `startupTimeoutMs` and past `gracePeriodMs` after a
  disconnect;
- `quitApp` returning `erQuit` in headless mode;
- `openWindow` / `closeWindow` behavior in headless mode.

### 3.8 Proxy setup is part of "it works"

The docs plan mentions `cloudflared`. nginx needs explicit WebSocket config
(`proxy_http_version 1.1`, `Upgrade` / `Connection` headers) or `/ws` fails.
Cloudflare quick tunnels (`trycloudflare.com`) get a new hostname every run,
so a fixed `allowedOrigins` doesn't fit them. A short "known-good proxy
configs" block would save users time.

---

## 4. A simpler implementation for the virtual window

The doc proposes pre-allocating a special `WindowRecord` inside `initWindows`.
You don't need a new code path. `initWindows` already takes a **`Launcher`**,
and the tests already inject a fake one through `testhooks` (`window.nim` 102,
248; `testhooks.nim`). A launcher that returns `nil` works:
`finishHandle(nil)` is a no-op (`window.nim` 180) and `rec.handle = nil` is the
normal "not launched" state.

So headless `runApp` can be:

1. skip `findBrowser` (avoids `NeelBrowserError` on a bad `browserPath`, and
   the probing on a box with no browser);
2. call `initWindows(..., launcher = noLaunch, headless = true)`;
3. call `openWindow(startPath)` as usual, which creates window 1 through the
   normal path;
4. `waitForAppExit` with retirement and idle exits disabled when headless.

That keeps the window table and the record lifecycle identical in both modes.
The `clearStaleUserDataDir` call in `openWindow` would run on a directory that
never exists, which is harmless. It also makes multi-window headless nearly
free later: `openWindow` would just create another addressable id. For now,
raising in headless mode is still the right call (see open question 1).

---

## 5. Thoughts on the open questions

1. **`openWindow` in headless**: raise `NeelBrowserError` (or a new error)
   with a clear message. Easy to relax later, and impossible to take back if
   it starts out allowed.
2. **`closeWindow` on window 1**: raise. A no-op hides bugs, and actually
   closing it makes the app unreachable while still running (every
   `/neel.js` would 404).
3. **`onWindowOpen` on every device**: not really implementable as stated.
   The server can't tell "a new device" from "the same device refreshed" or
   "the shim reconnected", since all three are a new connection binding to
   window 1. "Fire on every connection" is implementable, but it's a different
   hook (and the page already has `neel.ready` / `neel.onreconnect`). Keep
   once-per-window semantics; if per-connection is wanted, add a separate hook
   later.
4. **`seq[string]` vs. something richer**: a `seq[string]` of exact origins
   (see 2.1). No wildcards in v1: wildcards on shared domains are a
   foot-gun.
5. **`allowedHosts` without `headless`**: no (see 2.5).
6. **Signals**: Neel installs none today. A signal handler must not call
   `quitApp()` directly, since it takes a lock and signals a condition
   variable, which isn't async-signal-safe. Since `waitForAppExit` already wakes
   at least every `IdleTickMs` (1 s), the handler can set an atomic flag that
   the loop checks. SIGINT can go through `setControlCHook`; SIGTERM, which is
   what systemd and Docker send, needs `std/posix`. On Windows, Ctrl-C/Ctrl-Break
   only. It's worth doing for headless, since it's the normal way such a server
   is stopped.
7. **Startup message**: yes, always (not only in debug builds, unlike
   `debugLog`). Something like `neel: serving on http://127.0.0.1:8080
   (allowed origins: https://myapp.example.com)`. It's the only feedback a
   headless user gets, and it also catches the "forgot `port`, got an
   ephemeral one" mistake. Consider also refusing `port = 0` in headless mode,
   since a tunnel needs a fixed port.
8. **Example**: include one. It doubles as the manual test for the proxy, ping,
   and reconnect behavior.
9. **Naming**: `headless` has a specific problem in Neel: Neel *launches
   Chrome*, and Chrome's `--headless` means "run Chrome without a window". A
   reader can easily take `startApp(headless = true)` to mean "launch the
   browser headless". Alternatives that say what happens: `serve = true`,
   `server = true`, `persistent = true`, or `launchBrowser = false` (plus the
   exit behavior). I'd lean toward `serve`.

---

## 6. Revised scope estimate

Library code, roughly:

| Area | Change |
|---|---|
| `frontend.nim` | `allowedOrigins` matching for `Host` and `Origin`; narrow the cross-site check to `/neel.js` |
| `window.nim` | headless flag; skip per-window retirement and idle exits |
| `neel.nim` | `runApp` params, skip `findBrowser`, nil launcher, startup line, optional signal flag |
| `server.nim` | periodic ping on idle WebSocket connections (recommended) |
| `neel.js` | displacement close code; visibility/online reconnect (recommended) |

That's probably 100–200 lines of library code plus tests and docs, not ~50.
It's still a modest, well-contained feature. The architecture really does
cooperate: displacement, `location`-derived URLs, and the injected launcher do
most of the work.

## 7. Suggested edits to DISCUSSION.md, in priority order

1. Replace `allowedHosts` (host + Neel port) with exact `allowedOrigins`.
2. Add the cross-site navigation problem and narrow the check to `/neel.js`.
3. Spell out that per-window retirement must be disabled, not just the two exit
   reasons.
4. Add a "Connection robustness" section: proxy idle timeouts and pings, mobile
   backgrounding and the 5-attempt cap, server restarts and token loss, and the
   displaced-device signal.
5. Correct the `onWindowClose` table row, the signal-handling claim, the macro
   claim, and the "no changes" list.
6. Drop the local-mode `allowedHosts` use case.
7. Add `startPath` to the headless parameter table.
8. Add a test plan.
9. Reconsider the name.
