## frontend.nim - serve-time rendering of the browser-side shim.
##
## `neel.js` (same directory) is read with `staticRead` into `NeelJsSource`.
## It contains three placeholders - `__NEEL_TOKEN__`, `__NEEL_WINDOW_ID__`,
## and `__NEEL_EXPOSED__` - that `renderNeelJs` replaces with JS literals
## when `/neel.js` is served: the token is random per launch and the window
## id differs per window, so the substitution cannot happen at compile time.
## Do not rename the placeholders without updating `neel.js`.
##
## Every substituted value is a JS literal, never raw text: the token becomes
## a JSON string literal, the window id an integer literal, the exposed names
## a JSON array of string literals. `std/json` does the escaping, and `</` is
## additionally written as `<\/` so the output stays safe even when inlined in
## an HTML `<script>` element. A `static:` block checks that each placeholder
## occurs exactly once and that rendering leaves no `__NEEL_` behind.
##
## This module also owns the names of the `/ws` query parameters the shim
## sends (`TokenQueryParam`, `WindowQueryParam`) and the `/ws` path, so that
## Task 13's upgrade handler and `neel.js` share one definition; the `static:`
## block verifies that the shim really uses them. The route the shim itself
## is served at (`NeelJsPath`) lives here too.
##
## `requestRefusal` is the other side of the same contract: every page Neel
## opens lives at `http://127.0.0.1:<port>`, so a request that does not look
## like it came from such a page (another `Host`, a cross-site fetch, a `/ws`
## upgrade from another `Origin`) is refused before routing.

import std/[json, strutils]
import ./http

const
  NeelJsSource* = staticRead("neel.js")
    ## The unrendered shim exactly as shipped, placeholders included.
  TokenPlaceholder* = "__NEEL_TOKEN__"
    ## Replaced by a JSON string literal holding the launch token.
  WindowIdPlaceholder* = "__NEEL_WINDOW_ID__"
    ## Replaced by a positive integer literal.
  ExposedPlaceholder* = "__NEEL_EXPOSED__"
    ## Replaced by a JSON array of string literals (the exposed proc names).
  PlaceholderPrefix = "__NEEL_"
  NeelJsPath* = "/neel.js"
    ## Route of the rendered shim. `index.html` must load it with
    ## `<script src="/neel.js"></script>` before the app's own scripts.
  WsPath* = "/ws"
    ## Path the shim upgrades on. Task 13 routes it to `upgrade()`.
  TokenQueryParam* = "token"
    ## `/ws` query parameter carrying the launch token (`/ws?token=...`).
  WindowQueryParam* = "window"
    ## `/ws` query parameter carrying the window id (`&window=N`).
  LoopbackHost* = "127.0.0.1"
    ## The only host Neel serves and opens pages at.

proc jsStringLiteral*(s: string): string {.gcsafe.} =
  ## `s` as a double-quoted JSON (hence JS) string literal. Quotes,
  ## backslashes, and control characters are escaped by `std/json`; `</` is
  ## written as `<\/` so `</script>` inside a value cannot end an inline
  ## script element. Parsing the result as JSON yields `s` again.
  result = escapeJson(s)
  result = result.replace("</", "<\\/")

proc jsStringArrayLiteral*(items: seq[string]): string {.gcsafe.} =
  ## `items` as a compact JSON array of string literals (`[]` when empty),
  ## each element escaped like `jsStringLiteral`.
  result = "["
  for i, item in items:
    if i > 0:
      result.add ','
    result.add jsStringLiteral(item)
  result.add ']'

proc renderNeelJs*(token: string; windowId: int; exposed: seq[string]): string
    {.gcsafe.} =
  ## The shim for one window: `NeelJsSource` with the three placeholders
  ## replaced in a single pass (`multiReplace`), so a token that happens to
  ## contain a placeholder name is emitted verbatim inside its string literal.
  ## Pure in its arguments; safe to call from a pool worker per request.
  ## `windowId` must be positive (0 is Task 9's "no window" sentinel).
  doAssert windowId > 0, "renderNeelJs: window id must be positive"
  NeelJsSource.multiReplace(
    (TokenPlaceholder, jsStringLiteral(token)),
    (WindowIdPlaceholder, $windowId),
    (ExposedPlaceholder, jsStringArrayLiteral(exposed)))

proc isOwnHost(host: string; port: int): bool =
  ## `host` (a `Host` value, or an `Origin` without its scheme) names this
  ## server: `127.0.0.1:<port>`, or bare `127.0.0.1` on port 80, where
  ## browsers omit the default port.
  host == LoopbackHost & ":" & $port or (port == 80 and host == LoopbackHost)

proc requestRefusal*(req: HttpRequest; port: int): string {.gcsafe.} =
  ## Why `req` must be refused before routing, or `""` to serve it. `port`
  ## is the server's bound port. Refused, in this order:
  ## - a `Host` other than `127.0.0.1:<port>`, including none (DNS
  ##   rebinding: the browser sends the attacker's host name);
  ## - `Sec-Fetch-Site: cross-site` (another site's page loading `/neel.js`,
  ##   which carries the token, through a `<script>` tag); a request without
  ##   the header (older browsers) passes;
  ## - a `WsPath` request whose `Origin` is not `http://127.0.0.1:<port>`,
  ##   including none: browsers always send `Origin` on a WebSocket
  ##   handshake and a page cannot forge it, so a token captured by another
  ##   site is useless to it.
  ## Pure.
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

static:
  doAssert NeelJsSource.count(TokenPlaceholder) == 1,
    "neel.js must contain " & TokenPlaceholder & " exactly once"
  doAssert NeelJsSource.count(WindowIdPlaceholder) == 1,
    "neel.js must contain " & WindowIdPlaceholder & " exactly once"
  doAssert NeelJsSource.count(ExposedPlaceholder) == 1,
    "neel.js must contain " & ExposedPlaceholder & " exactly once"
  doAssert NeelJsSource.count(PlaceholderPrefix) == 3,
    "neel.js mentions an unknown " & PlaceholderPrefix & " placeholder"
  doAssert (WsPath & "?" & TokenQueryParam & "=") in NeelJsSource,
    "neel.js must build its URL from " & WsPath & "?" & TokenQueryParam & "="
  doAssert ("&" & WindowQueryParam & "=") in NeelJsSource,
    "neel.js must append &" & WindowQueryParam & "= to its URL"
  doAssert PlaceholderPrefix notin renderNeelJs("token", 1, @["a", "b"]),
    "renderNeelJs left a placeholder behind"
