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
## is served at (`NeelJsPath`) lives here too, and so does `CloseDisplaced`,
## the close code the shim must treat as final; the `static:` block checks
## that `neel.js` defines the same number.
##
## `requestRefusal` is the other side of the same contract: every page Neel
## opens lives at `http://127.0.0.1:<port>`, so a request that does not look
## like it came from such a page (another `Host`, a cross-site fetch, a `/ws`
## upgrade from another `Origin`) is refused before routing. Its
## `RequestFilter` (built once by `initRequestFilter`, immutable afterwards)
## widens this in serve mode only: the hosts of the allowed origins
## (`normalizeOrigin`) are accepted as `Host`, the origins themselves on
## `/ws`, and cross-site top-level document navigations pass.

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
  CloseDisplaced* = 4000
    ## Close code a connection receives when another connection binds to its
    ## window (a second tab or device). `neel.js` treats it as final, like
    ## 1000 and 1001: a displaced page that reconnected would displace the
    ## new one in turn, forever. `neel.onclose` reports it, so a page can
    ## say it was opened elsewhere.
  ShimCloseDisplaced = "const CLOSE_DISPLACED = " & $CloseDisplaced & ";"

type
  RequestFilter* = object
    ## What `requestRefusal` accepts beyond Neel's own `127.0.0.1:<port>`.
    ## Built once by `initRequestFilter` before the server listens and only
    ## read afterwards, so workers share it without a lock. The zero value is
    ## local mode.
    serve*: bool
      ## Serve mode: `origins` and `hosts` are accepted, and cross-site
      ## top-level document navigations pass. Both seqs are ignored when
      ## `false`.
    origins*: seq[string]
      ## Normalized allowed origins (`normalizeOrigin`), without duplicates.
    hosts*: seq[string]
      ## The `host[:port]` part of each entry of `origins`, without
      ## duplicates: the `Host` a proxy forwarding the public host sends.

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

proc normalizeOrigin*(origin: string): string =
  ## `origin` as browsers serialize it in an `Origin` header: scheme and host
  ## lowercased, the port written as a plain integer and dropped when it is
  ## the scheme's default (`:80` for `http`, `:443` for `https`). Accepts
  ## only `http://host[:port]` and `https://host[:port]`, where `host` is
  ## ASCII letters, digits, `-`, `.`, `_`, or a bracketed IPv6 literal, and
  ## `port` is 1-65535. Raises `ValueError` naming `allowedOrigins` for
  ## anything else: a path (a trailing `/` included), a query, a fragment,
  ## user info, a wildcard, another scheme, an empty host or port,
  ## surrounding whitespace, or non-ASCII (browsers send the punycode form).
  ## Pure.
  proc invalid(why: string) {.noreturn.} =
    raise newException(ValueError, "neel: allowedOrigins entry " & escape(origin) &
      " " & why & "; expected http://host[:port] or https://host[:port]")
  if origin.len == 0:
    invalid("is empty")
  for c in origin:
    if c <= ' ' or c >= '\x7F':
      invalid("contains whitespace, a control character, or non-ASCII " &
              "(write an internationalized host in its punycode form)")
  let sep = origin.find("://")
  if sep < 0:
    invalid("has no scheme")
  let scheme = origin[0 ..< sep].toLowerAscii
  if scheme notin ["http", "https"]:
    invalid("has an unsupported scheme")
  let rest = origin[sep + 3 .. ^1]
  if '/' in rest:
    invalid("has a path (a trailing / counts as one)")
  if '?' in rest:
    invalid("has a query")
  if '#' in rest:
    invalid("has a fragment")
  if '@' in rest:
    invalid("has user info")
  if '*' in rest:
    invalid("has a wildcard")
  var host, portText: string
  var hasPort = false
  if rest.startsWith('['):
    let close = rest.find(']')
    if close < 2 or not rest[1 ..< close].allCharsInSet(HexDigits + {':', '.'}):
      invalid("has an invalid IPv6 host")
    host = rest[0 .. close]
    let after = rest[close + 1 .. ^1]
    if after.len > 0:
      if after[0] != ':':
        invalid("has an invalid IPv6 host")
      hasPort = true
      portText = after[1 .. ^1]
  else:
    let colon = rest.find(':')
    if colon < 0:
      host = rest
    else:
      host = rest[0 ..< colon]
      hasPort = true
      portText = rest[colon + 1 .. ^1]
    if host.len == 0:
      invalid("has no host")
    if not host.allCharsInSet(Letters + Digits + {'-', '.', '_'}):
      invalid("has an invalid host")
  result = scheme & "://" & host.toLowerAscii
  if hasPort:
    if portText.len notin 1 .. 5 or not portText.allCharsInSet(Digits):
      invalid("has an invalid port")
    let port = parseInt(portText)
    if port notin 1 .. 65535:
      invalid("has a port outside 1-65535")
    if not ((scheme == "http" and port == 80) or (scheme == "https" and port == 443)):
      result.add ":" & $port

proc initRequestFilter*(serve: bool; allowedOrigins: seq[string] = @[]): RequestFilter =
  ## The filter for one run. Every entry of `allowedOrigins` goes through
  ## `normalizeOrigin` (which raises `ValueError` on a malformed one) and
  ## contributes its `host[:port]` to `hosts`; duplicates after
  ## normalization are kept once. `initRequestFilter(serve = false)` is
  ## local mode.
  result.serve = serve
  for entry in allowedOrigins:
    let origin = normalizeOrigin(entry)
    if origin notin result.origins:
      result.origins.add origin
    let host = origin[origin.find("://") + 3 .. ^1]
    if host notin result.hosts:
      result.hosts.add host

proc isOwnHost(host: string; port: int): bool =
  ## `host` (a `Host` value, or an `Origin` without its scheme) names this
  ## server: `127.0.0.1:<port>`, or bare `127.0.0.1` on port 80, where
  ## browsers omit the default port.
  host == LoopbackHost & ":" & $port or (port == 80 and host == LoopbackHost)

proc isTopLevelNavigation(req: HttpRequest): bool =
  ## `Sec-Fetch-Mode: navigate` with `Sec-Fetch-Dest: document`: the browser
  ## is loading a page into a tab, not a frame, script, or fetch.
  cmpIgnoreCase(req.getHeader("Sec-Fetch-Mode"), "navigate") == 0 and
    cmpIgnoreCase(req.getHeader("Sec-Fetch-Dest"), "document") == 0

proc requestRefusal*(req: HttpRequest; port: int; filter: RequestFilter): string
    {.gcsafe.} =
  ## Why `req` must be refused before routing, or `""` to serve it. `port`
  ## is the server's bound port. Refused, in this order:
  ## - a `Host` other than `127.0.0.1:<port>`, including none (DNS
  ##   rebinding: the browser sends the attacker's host name). In serve mode
  ##   an exact match in `filter.hosts` is accepted too;
  ## - `Sec-Fetch-Site: cross-site` (another site's page loading `/neel.js`,
  ##   which carries the token, through a `<script>` tag); a request without
  ##   the header (older browsers) passes. In serve mode a top-level document
  ##   navigation passes (links and auth-proxy login redirects arrive
  ##   cross-site); frames do not, so another site cannot frame the app;
  ## - a `WsPath` request whose `Origin` is not `http://127.0.0.1:<port>`,
  ##   including none: browsers always send `Origin` on a WebSocket
  ##   handshake and a page cannot forge it, so a token captured by another
  ##   site is useless to it. In serve mode an exact match in
  ##   `filter.origins` is accepted too.
  ## Pure.
  let widened = filter.serve and filter.origins.len > 0
  let host = req.getHeader("Host")
  if not (isOwnHost(host, port) or (filter.serve and host in filter.hosts)):
    return "neel: refused: the Host header must be " & LoopbackHost & ":" & $port &
      (if widened: " or the host of an allowed origin" else: "")
  if cmpIgnoreCase(req.getHeader("Sec-Fetch-Site"), "cross-site") == 0 and
      not (filter.serve and isTopLevelNavigation(req)):
    return "neel: refused: cross-site request"
  if req.path == WsPath:
    const scheme = "http://"
    let origin = req.getHeader("Origin")
    let own = origin.startsWith(scheme) and isOwnHost(origin[scheme.len .. ^1], port)
    if not (own or (filter.serve and origin in filter.origins)):
      return "neel: refused: the Origin header must be " & scheme & LoopbackHost &
        ":" & $port & (if widened: " or an allowed origin" else: "")
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
  doAssert NeelJsSource.count(ShimCloseDisplaced) == 1,
    "neel.js must define " & ShimCloseDisplaced & " exactly once"
  doAssert PlaceholderPrefix notin renderNeelJs("token", 1, @["a", "b"]),
    "renderNeelJs left a placeholder behind"
