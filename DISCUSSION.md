# Headless Mode: Discussion & Design Reference

This document captures the full analysis, design rationale, and implementation
plan for adding a **headless/server mode** to Neel. It serves as a working
reference across sessions until the spec is finalized and the implementation is
complete.

---

## Table of Contents

- [Motivation](#motivation)
- [What Headless Mode Is (and Is Not)](#what-headless-mode-is-and-is-not)
- [Current Architecture: What Blocks Remote Access](#current-architecture-what-blocks-remote-access)
  - [1. Security checks in requestRefusal](#1-security-checks-in-requestrefusal)
  - [2. Browser launch as the application lifecycle](#2-browser-launch-as-the-application-lifecycle)
  - [3. Exit on zero connections](#3-exit-on-zero-connections)
  - [4. Token is random per launch](#4-token-is-random-per-launch)
  - [5. Window id auto-increment and process binding](#5-window-id-auto-increment-and-process-binding)
- [What Already Works for Remote Access](#what-already-works-for-remote-access)
  - [1. WebSocket URL derivation in neel.js](#1-websocket-url-derivation-in-neeljs)
  - [2. Session takeover via bindConnection](#2-session-takeover-via-bindconnection)
  - [3. 127.0.0.1 binding with tunnel access](#3-127001-binding-with-tunnel-access)
  - [4. TLS termination at the tunnel/proxy](#4-tls-termination-at-the-tunnelproxy)
- [Security Analysis](#security-analysis)
  - [Local mode (unchanged)](#local-mode-unchanged)
  - [Headless mode security posture](#headless-mode-security-posture)
  - [The token in headless mode](#the-token-in-headless-mode)
  - [Authentication: what Neel should and should not do](#authentication-what-neel-should-and-should-not-do)
- [Design Decisions](#design-decisions)
  - [Single-user only, not a web framework](#single-user-only-not-a-web-framework)
  - [The window model in headless mode](#the-window-model-in-headless-mode)
  - [openWindow / closeWindow in headless mode](#openwindow--closewindow-in-headless-mode)
  - [UI state and reconnection](#ui-state-and-reconnection)
- [Proposed API Surface](#proposed-api-surface)
- [Implementation Plan](#implementation-plan)
  - [Files to change](#files-to-change)
  - [Files that need no changes](#files-that-need-no-changes)
  - [Estimated scope](#estimated-scope)
- [Documentation Plan](#documentation-plan)
- [Open Questions](#open-questions)

---

## Motivation

Neel is designed around a tight contract: the server, the browser, and the user
are all on the same machine. The server binds `127.0.0.1`, opens Chrome/Edge in
app mode, and exits when the browser window closes. This is perfect for desktop
apps.

But there is a large, well-defined category of applications that want the same
simple programming model — `{.expose.}` procs, `neel.foo()` in JS, no HTTP/WS
plumbing — without the constraint that the browser must be on the same machine:

- **Self-hosted personal tools** — dashboards, file managers, home automation
  panels, personal wikis.
- **Developer tools** — admin panels, monitoring UIs, database browsers.
- **Appliance UIs** — a Raspberry Pi controller, a NAS admin panel, a home
  server dashboard.
- **"My tool, from my phone"** — anything you build for yourself and want to
  access from your phone, tablet, laptop, or any device you own.

The pattern: one user, one active session, accessible from any device through a
tunnel or reverse proxy (Cloudflare Tunnel, Tailscale, WireGuard, nginx, etc.).

Headless mode moves Neel from:

> *"Desktop app: Nim backend + browser window on the same machine"*

to:

> *"Personal app: Nim backend + browser window on any of your devices"*

---

## What Headless Mode Is (and Is Not)

**It is:**

- A mode where Neel runs as a persistent server without launching a browser.
- Single-user: one active session/connection at a time.
- A new connection from another device displaces the old one (the old device's
  WebSocket is closed).
- The app stays alive indefinitely until explicitly stopped (`quitApp()` or a
  signal).
- The same programming model: `{.expose.}`, `neel.foo()`, `js.wait.bar()` —
  everything works the same.

**It is not:**

- A multi-user web framework. No authentication layer, no session isolation, no
  per-user state, no user context in exposed procs.
- A replacement for Jester, Prologue, or other Nim web frameworks.
- An attempt to make Neel serve arbitrary HTTP routes (that's already on the
  roadmap as "Custom routes," which is orthogonal).

The honest pitch:

> *Neel's headless mode runs your app as a persistent server for a single user.
> Access it from any device through a private tunnel or reverse proxy. It is not
> a multi-user web framework — there is one session at a time, and a new
> connection displaces the old one.*

---

## Current Architecture: What Blocks Remote Access

### 1. Security checks in `requestRefusal`

**File:** `src/neel/frontend.nim`, lines 90–113.

Every request passes through `requestRefusal` before routing:

```nim
proc requestRefusal*(req: HttpRequest; port: int): string {.gcsafe.} =
  if not isOwnHost(req.getHeader("Host"), port):
    return "neel: refused: the Host header must be " & LoopbackHost & ":" & $port
  if cmpIgnoreCase(req.getHeader("Sec-Fetch-Site"), "cross-site") == 0:
    return "neel: refused: cross-site request"
  if req.path == WsPath:
    const scheme = "http://"
    let origin = req.getHeader("Origin")
    if not (origin.startsWith(scheme) and isOwnHost(origin[scheme.len .. ^1], port)):
      return "neel: refused: the Origin header must be " & scheme & LoopbackHost &
        ":" & $port
  ""
```

When accessed through a tunnel (e.g., `https://myapp.example.com`):

- `Host` header is `myapp.example.com` → **403 refused**.
- `Origin` on WebSocket upgrade is `https://myapp.example.com` → **403 refused**.
- `Sec-Fetch-Site` may be `cross-site` from the browser's perspective → **403
  refused**.

### 2. Browser launch as the application lifecycle

**File:** `src/neel.nim`, `runApp` (line ~369).

`startApp` → `runApp` → `findBrowser` → `openWindow` → launches a browser
process. The entire lifecycle is browser-centric: launch browser, serve until
browser closes, exit. In headless mode there is no browser to launch.

### 3. Exit on zero connections

**File:** `src/neel/window.nim`, `waitForAppExit` (line ~644).

The app exits when the WebSocket connection count stays at zero for the grace
period:

```nim
if m.connCount == 0 and not loading:
  if m.everConnected:
    if not m.graceActive or now >= m.graceDeadline:
      release m.lock
      return erLastWindowClosed
```

For a persistent server, closing your phone's browser must not kill the server.

Also: `erStartupTimeout` fires if no connection ever opens within
`startupTimeoutMs`. In headless mode, the server should wait indefinitely for
the first connection.

### 4. Token is random per launch

**File:** `src/neel.nim`, lines 122–129.

The token is generated fresh on every `startApp` call. This is correct for local
mode (the token is baked into `neel.js` and the browser is launched at a URL
containing the window id). For headless mode, the token needs to survive across
reconnections from different devices, which it already does within a single
launch — but if the server restarts, every client loses its token. This may or
may not matter depending on the deployment model (tunnels reconnect, and the
client would just reload the page to get the new `neel.js` with the new token).

### 5. Window id auto-increment and process binding

**File:** `src/neel/window.nim`, `openWindow`.

Each window is tied to a browser process, a profile directory, and an
auto-incrementing id. In headless mode, there is no browser process, no profile
directory, and ideally a single stable virtual window.

---

## What Already Works for Remote Access

### 1. WebSocket URL derivation in `neel.js`

**File:** `src/neel/neel.js`, lines 262–266.

The shim already derives the WebSocket URL from `location`, not from a hardcoded
address:

```javascript
function wsUrl() {
  const scheme = location.protocol === "https:" ? "wss:" : "ws:";
  return scheme + "//" + location.host +
    "/ws?token=" + encodeURIComponent(TOKEN) + "&window=" + WINDOW_ID;
}
```

This means `neel.js` **already works through a reverse proxy or tunnel**. It
will connect to `wss://myapp.example.com/ws?token=...&window=1` automatically.
No changes needed.

### 2. Session takeover via `bindConnection`

**File:** `src/neel/window.nim`, lines 288–321.

`bindConnection` already displaces an old connection when a new one binds to the
same window id:

```nim
if rec.hasConn:
  m.connToWindow.del(rec.conn)
  if rec.conn != conn:
    displaced = rec.conn
    hasDisplaced = true
# ...
if hasDisplaced:
  discard m.closeConn(displaced, CloseNormal)
```

When the phone connects with `?window=1`, the desktop's WebSocket gets a 1000
close. The shim's `onclose` fires on the old device. **This is the "one device
at a time" behavior, already implemented.**

### 3. `127.0.0.1` binding with tunnel access

**File:** `src/neel/server.nim`, line 293.

The server binds to `127.0.0.1` only. A Cloudflare Tunnel (or any tunnel)
connects *outbound* to Cloudflare's edge, then proxies inbound requests to
`127.0.0.1`. The server doesn't need to bind a public interface. **No change
needed.**

### 4. TLS termination at the tunnel/proxy

The guide mentions:

> *The page side already switches to `wss:` when served over `https:`*

Confirmed by the `wsUrl()` function above. The tunnel terminates TLS at its
edge; Neel sees plain HTTP/WS on localhost. The shim handles the protocol switch
automatically. **No change needed.**

---

## Security Analysis

### Local mode (unchanged)

Default behavior is completely unchanged. Token per launch, Host must be
`127.0.0.1`, Origin must be `http://127.0.0.1`, cross-site refused. Users who
never pass `headless = true` never see different behavior.

### Headless mode security posture

The trust boundary shifts from "only this machine" to "only someone who can
reach the server and load the page." The token still prevents other websites in
the user's browser from connecting (they can't get it without loading `neel.js`
from the server), but anyone who can reach the host can load the page.

This is the correct model for:

- **Private tunnels** (Cloudflare Access / Zero Trust, Tailscale, WireGuard) —
  the tunnel itself is the authentication layer. Only devices on your network
  can reach the server.
- **LAN access** — the server is on your home network, your phone is on the
  same network (though Neel still binds `127.0.0.1`, so a local reverse proxy
  or tunnel is still needed).

### The token in headless mode

The token is embedded in `neel.js`, which is served to anyone who can reach the
host. In local mode, this is fine because only local processes can reach
`127.0.0.1`. In headless mode:

- With a **private tunnel** (Cloudflare Access, Tailscale), only authenticated
  devices can reach the server. The token is an extra layer, not the only one.
- With a **public URL and no auth proxy**, anyone who knows the URL can load the
  page and get the token. The token is not sufficient as an authentication
  mechanism for untrusted networks.

### Authentication: what Neel should and should not do

**Neel should NOT build an authentication system.** That is web framework
territory (sessions, cookies, password hashing, OAuth, etc.) and is orthogonal
to Neel's purpose.

**Neel's docs should clearly state:**

> *In headless mode, Neel trusts whoever can reach the server. Use a private
> tunnel (Cloudflare Access, Tailscale, WireGuard) or place an authentication
> proxy in front. The launch token prevents cross-site attacks from other tabs
> but is not a substitute for user authentication.*

This is the same posture as Jupyter Notebook (which has a token but recommends
running behind a proxy for remote access), Home Assistant (which trusts the
local network by default), and most self-hosted tools.

---

## Design Decisions

### Single-user only, not a web framework

Multi-user would require:

- Authentication and authorization (who is this, what can they see)
- Session isolation (user A's state vs. user B's state)
- Per-user window mapping (which WebSocket belongs to which user)
- Concurrent state management (two users calling the same exposed proc)
- Shared vs. private data (exposed procs need to know *who* is calling)

That is a fundamentally different problem. It distorts the entire Neel
programming model: `{.expose.}` procs would need a user context parameter, the
window model would need a session layer, and Neel would be competing with
Jester/Prologue on their own turf.

Headless mode is **single-user, single-session, one active connection at a
time**. The exposed procs don't need to know who's calling because there's only
one "who."

### The window model in headless mode

In local mode, a `Window` is tied to a browser process, a profile directory, and
a unique id. In headless mode, none of that exists.

**Proposed approach:** In headless mode, `startApp` creates a single **virtual
window** (id 1) but does not launch a browser. When a browser connects from any
device, the existing `neelJsWindowId` logic already handles it — when exactly
one window is open and the page's URL has no `?window=` parameter, that single
window's shim is served:

```nim
# Already in neel.nim, neelJsWindowId:
let open = windows()
if open.len == 1:
  result.id = open[0].id
```

So a user can just visit `https://myapp.example.com/` and get the right shim
automatically. No special URL required.

When a second device connects, `bindConnection` displaces the first (already
implemented). The old device's `neel.onclose` fires with code 1000.

### `openWindow` / `closeWindow` in headless mode

For the initial implementation: **headless mode is single-window only.** The
virtual window (id 1) is created by `startApp` and cannot be closed. Calling
`openWindow` or `closeWindow` in headless mode should either be a no-op or raise
a clear error.

Multi-window headless is a more complex feature that could come later if there
is demand (e.g., multiple named "pages" that different devices can connect to
independently). No need to design for it now.

### UI state and reconnection

Neel does not manage UI state — it's in the browser's DOM/JS. When you
disconnect from your desktop and connect from your phone, the phone gets a
**fresh page load**. Any client-side state (form inputs, scroll position,
dynamic DOM changes) is gone unless the app preserves it.

**This is an application-level concern, not a Neel concern.** The recommended
pattern:

- Keep authoritative state in Nim (backend).
- On page load (or on `neel.ready`), call an exposed proc like
  `neel.getState()` to hydrate the UI from backend state.
- On user actions, update the backend via exposed procs. The UI is a view of
  the backend state, not the source of truth.

This is already the natural pattern for most Neel apps that do anything
non-trivial. Headless mode just makes it explicit.

---

## Proposed API Surface

All new parameters are opt-in with defaults that match current behavior:

```nim
startApp(
  headless = false,             # NEW: no browser launch, persistent server
  allowedHosts = @[],           # NEW: trusted hosts for Host/Origin checks
                                #      (empty = 127.0.0.1 only, the default)
  # Everything else unchanged:
  webDir = "web",
  startPath = "/",
  port = 0,                     # users will want a fixed port in headless mode
  workers = DefaultWorkers,
  queueCapacity = DefaultQueueCapacity,
  callTimeoutMs = DefaultCallTimeoutMs,
  maxMessageSize = DefaultMaxMessageSize,
  gracePeriodMs = DefaultGracePeriodMs,
  startupTimeoutMs = DefaultStartupTimeoutMs,
  browsers = @[Chrome, Chromium, Edge],
  fallback = true,
  browserPath = "",
  size = none(WindowSize),
  position = none(WindowPosition),
  extraFlags = @[],
  onWindowOpen = nil,
  onWindowClose = nil,
)
```

Typical headless usage:

```nim
startApp(
  headless = true,
  allowedHosts = @["myapp.example.com"],
  port = 8080,
)
```

### Behavioral differences in headless mode

| Aspect | Local mode (default) | Headless mode |
|--------|---------------------|---------------|
| Browser launch | Chrome/Chromium/Edge launched in app mode | No browser launched |
| Initial window | Created and opened in the browser | Virtual window (id 1) created, no browser |
| Exit trigger | Connection count at zero for `gracePeriodMs` | Only `quitApp()` or process signal |
| `startupTimeoutMs` | App exits if no connection within timeout | Ignored; server waits indefinitely |
| `gracePeriodMs` | App exits after grace period with no connections | Ignored; server stays alive |
| `browsers`, `fallback`, `browserPath` | Used for browser discovery | Ignored |
| `size`, `position`, `extraFlags` | Applied to browser window | Ignored |
| `allowedHosts` | Can be used (adds to `127.0.0.1`) | Typically required (the tunnel hostname) |
| `onWindowOpen` | Fires when browser's page first connects | Fires when any device first connects |
| `onWindowClose` | Fires when browser window is retired | Does not fire (the virtual window is never closed) |
| `openWindow` | Opens a new browser window | Error or no-op (TBD) |
| `closeWindow` | Closes a browser window | Error or no-op (TBD) |
| Host/Origin check | Must be `127.0.0.1:<port>` | Also accepts `allowedHosts` entries |

### `allowedHosts` behavior

`allowedHosts` applies in **both** local and headless mode (it's independently
useful — e.g., accessing a local Neel app via a LAN hostname). When non-empty:

- `requestRefusal`'s Host check accepts `<host>:<port>` for each host in the
  list, in addition to `127.0.0.1:<port>`.
- The Origin check on `/ws` accepts both `http://` and `https://` schemes for
  each allowed host, in addition to `http://127.0.0.1:<port>`.
- `Sec-Fetch-Site: cross-site` is **still refused** — the request is expected to
  come from a page served by this server, not from another site. A page loaded
  from `https://myapp.example.com` talking to `https://myapp.example.com` is
  same-origin, not cross-site.

---

## Implementation Plan

### Files to change

**`src/neel/frontend.nim`** (~15 lines):

- `requestRefusal` gains an `allowedHosts` parameter (a `seq[string]` or
  `HashSet[string]`).
- `isOwnHost` is generalized: checks `127.0.0.1:<port>` first, then each
  entry in `allowedHosts`.
- The Origin check on `/ws` accepts `https://` schemes for allowed hosts (not
  just `http://`).

**`src/neel/window.nim`** (~10–20 lines):

- `initWindows` accepts a `headless` flag.
- When headless, a virtual `WindowRecord` (id 1) is pre-allocated in the
  window table during `initWindows`, with no browser handle and `everConnected =
  false`. It is never retired by the grace period or startup timeout.
- `waitForAppExit` in headless mode: ignores `erLastWindowClosed` and
  `erStartupTimeout`, returns only on `erQuit`.
- `openWindow` in headless mode: either raises a clear error or is restricted
  (TBD).
- `closeWindow` on the virtual window: either raises or is a no-op (TBD).

**`src/neel.nim`** (~20 lines):

- `startApp` macro forwards `headless` and `allowedHosts` to `runApp`.
- `runApp`:
  - When `headless = true`: skips `findBrowser`, does not call `openWindow`
    (the virtual window is created by `initWindows`), skips the
    `NeelBrowserError` sleep/raise path.
  - Passes `allowedHosts` to the request handler (through `AppState` or
    directly to `requestRefusal` at the call site).
  - Ignores `browsers`, `fallback`, `browserPath`, `size`, `position`,
    `extraFlags` when headless (or asserts they are at defaults — TBD).
- `handleRequest`: passes `allowedHosts` to `requestRefusal`.

### Files that need no changes

- **`src/neel/server.nim`** — the server, IO loop, connection state machine.
  Still binds `127.0.0.1`, still accepts connections, still dispatches to the
  pool. No changes.
- **`src/neel/neel.js`** — the browser shim. Already derives the WebSocket URL
  from `location.host` and `location.protocol`. The token and window id
  substitution works the same way. No changes.
- **`src/neel/protocol.nim`** — the wire format. No changes.
- **`src/neel/expose.nim`** — the `{.expose.}` macro. No changes.
- **`src/neel/jsproxy.nim`** — the `js` proxy. No changes.
- **`src/neel/websocket.nim`** — frame encoding/decoding. No changes.
- **`src/neel/http.nim`** — HTTP parsing. No changes.
- **`src/neel/pool.nim`** — the worker pool. No changes.
- **`src/neel/sha1.nim`** — WebSocket handshake. No changes.
- **`src/neel/assets.nim`** — static file serving. No changes.
- **`src/neel/browser.nim`** — browser discovery and launch. Not called in
  headless mode, but no changes needed to the module itself.

### Estimated scope

Roughly **~50 lines of logic** across 3 files, plus parameter threading. The
changes are additive — no existing code paths are modified, only branched
around. The default behavior (`headless = false`, `allowedHosts = @[]`) is
identical to the current behavior.

---

## Documentation Plan

- **README.md**: A new section after "Compilation" or "Before You Start"
  introducing headless mode with a minimal example.
- **docs/GUIDE.md**: A new section (e.g., "Headless mode") covering:
  - What it is and when to use it.
  - The `headless` and `allowedHosts` parameters.
  - The virtual window model and session displacement.
  - Security posture: the clear statement about trusting whoever can reach the
    server, the recommendation for private tunnels, the note that the token is
    not authentication.
  - A concrete example with Cloudflare Tunnel (`cloudflared`).
  - The "keep state in Nim, hydrate on connect" pattern for UI state.
  - What does and doesn't work: `openWindow`/`closeWindow` are restricted,
    `browsers`/`fallback`/`size`/`position` are ignored.
- **`startApp` parameters table** in the guide: two new rows for `headless`
  and `allowedHosts`.

---

## Open Questions

These need to be resolved before implementation:

1. **`openWindow` in headless mode.** Should it raise an error, be a no-op, or
   be allowed (enabling multi-window headless for future use)? Leaning toward
   raising a clear error for now.

2. **`closeWindow` on the virtual window.** Should it raise, be a no-op, or
   actually close the virtual window (which would then need to be reopened)?
   Leaning toward raising or no-op.

3. **`onWindowOpen` / `onWindowClose` semantics.** `onWindowOpen` fires when
   the first device connects to the virtual window. Should it fire again when a
   new device displaces the old one? (Currently `onWindowOpen` only fires once
   per window — the first time `everConnected` becomes true. This means it fires
   once on the first device and never again. Is that the right behavior, or
   should headless mode fire it on every new device connection?)

4. **`allowedHosts` vs. a more general approach.** Is a `seq[string]` of
   hostnames sufficient, or should it support wildcards, regex, or a callback?
   Leaning toward simple `seq[string]` — keep it minimal.

5. **Should `allowedHosts` be independent of `headless`?** Currently proposed
   as usable in both modes. This is useful for edge cases (e.g., accessing a
   local Neel app via a LAN hostname like `mypc.local:8080`). But it also means
   a user could set `allowedHosts` without `headless`, which relaxes security
   checks while still launching a local browser. Is that a valid use case or a
   footgun?

6. **Signal handling.** In headless mode, the server should respond to SIGTERM /
   SIGINT by calling `quitApp()` and shutting down cleanly. Is this already
   handled (some apps install signal handlers), or does Neel need to install one
   in headless mode?

7. **Logging / status output.** In headless mode, the server runs without a
   visible browser. Should Neel print a startup message to stdout/stderr
   (`Neel headless server listening on 127.0.0.1:8080`)? This is useful for
   confirming the server is running, especially when launching via systemd or a
   tunnel.

8. **Example.** Should a `examples/headless/` example be included in the first
   release, or added later? The example would be a minimal app with a
   `startApp(headless = true, ...)` and instructions for running with
   `cloudflared`.

9. **Naming.** Is `headless` the right name? Alternatives: `serverMode`,
   `remoteMode`, `persistent`, `daemon`. `headless` is the most immediately
   understood (Chromium uses it, Electron uses it) but it technically means
   "no GUI" which is not quite right — there IS a GUI, it's just not on this
   machine.
