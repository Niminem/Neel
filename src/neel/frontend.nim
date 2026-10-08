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
## block verifies that the shim really uses them.

import std/[json, strutils]

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
  WsPath* = "/ws"
    ## Path the shim upgrades on. Task 13 routes it to `upgrade()`.
  TokenQueryParam* = "token"
    ## `/ws` query parameter carrying the launch token (`/ws?token=...`).
  WindowQueryParam* = "window"
    ## `/ws` query parameter carrying the window id (`&window=N`).

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
