## t_frontend.nim - placeholder substitution for the served `neel.js`.
##
## The shim itself cannot be executed here (no JS runtime is a dependency);
## it is verified in a browser against the server, see PLAN.md Task 10.

import std/[unittest, json, strutils]
import neel/frontend

const
  Tricky = "a\"b\\c</script><script>alert(1)</script>\n\t\u00e9"
    ## Quotes, backslashes, a script terminator, control chars, non-ASCII.

proc expected(token: string; windowId: int; exposed: seq[string]): string =
  ## Independent rendering: the source with each placeholder replaced once.
  NeelJsSource.multiReplace(
    (TokenPlaceholder, jsStringLiteral(token)),
    (WindowIdPlaceholder, $windowId),
    (ExposedPlaceholder, jsStringArrayLiteral(exposed)))

suite "frontend: literals":
  test "jsStringLiteral is a quoted JSON string that parses back":
    check jsStringLiteral("abc") == "\"abc\""
    check jsStringLiteral("") == "\"\""
    check parseJson(jsStringLiteral(Tricky)).getStr == Tricky

  test "jsStringLiteral never contains a raw </ sequence":
    let lit = jsStringLiteral(Tricky)
    check "</" notin lit
    check "<\\/script>" in lit
    check "\\\"" in lit     # the quote is escaped
    check "\\\\" in lit     # the backslash is escaped

  test "jsStringArrayLiteral: empty, one, many, escaped":
    check jsStringArrayLiteral(@[]) == "[]"
    check jsStringArrayLiteral(@["add"]) == "[\"add\"]"
    check jsStringArrayLiteral(@["add", "fail", "x"]) == "[\"add\",\"fail\",\"x\"]"
    let parsed = parseJson(jsStringArrayLiteral(@["a\"b", "</script>"]))
    check parsed.kind == JArray
    check parsed[0].getStr == "a\"b"
    check parsed[1].getStr == "</script>"

suite "frontend: renderNeelJs":
  test "all three placeholders are substituted with the exact literals":
    let js = renderNeelJs("abc123", 7, @["add", "fail"])
    check js == expected("abc123", 7, @["add", "fail"])
    check js.count("\"abc123\"") == 1
    check "= 7;" in js
    check js.count("[\"add\",\"fail\"]") == 1
    check TokenPlaceholder notin js
    check WindowIdPlaceholder notin js
    check ExposedPlaceholder notin js

  test "a hostile token is escaped and parses back to itself":
    let js = renderNeelJs(Tricky, 1, @[])
    check js == expected(Tricky, 1, @[])
    check "</script>" notin js
    # Locate the literal: it is the only place where the escaped token appears.
    let lit = jsStringLiteral(Tricky)
    let at = js.find(lit)
    check at >= 0
    check parseJson(js[at ..< at + lit.len]).getStr == Tricky

  test "exposed list: empty and multi-name":
    # The source itself contains `[]` (an empty array literal), so compare counts.
    let base = NeelJsSource.count("[]")
    check renderNeelJs("t", 1, @[]).count("[]") == base + 1
    let js = renderNeelJs("t", 1, @["alpha", "beta", "gamma"])
    check js.count("[\"alpha\",\"beta\",\"gamma\"]") == 1
    check js.count("[]") == base

  test "no __NEEL_ remains in the output; the source has exactly three":
    check NeelJsSource.count("__NEEL_") == 3
    check "__NEEL_" notin renderNeelJs("token", 1, @["a"])
    check "__NEEL_" notin renderNeelJs("", 42, @[])

  test "substitution is a single pass: a placeholder name inside the token survives":
    let token = "x" & WindowIdPlaceholder & "y"
    let js = renderNeelJs(token, 3, @[ExposedPlaceholder])
    check jsStringLiteral(token) in js
    check jsStringArrayLiteral(@[ExposedPlaceholder]) in js
    # The real placeholders were still replaced exactly once each.
    check js.count(WindowIdPlaceholder) == 1 # the one inside the token literal
    check js.count(ExposedPlaceholder) == 1  # the one inside the array literal

  test "rendering is pure: byte-identical for equal arguments":
    let a = renderNeelJs("same", 5, @["p", "q"])
    let b = renderNeelJs("same", 5, @["p", "q"])
    check a == b
    check a.len == b.len
    check renderNeelJs("same", 6, @["p", "q"]) != a
    check renderNeelJs("other", 5, @["p", "q"]) != a
    check renderNeelJs("same", 5, @["p"]) != a

  test "window id must be positive":
    expect AssertionDefect:
      discard renderNeelJs("t", 0, @[])
    expect AssertionDefect:
      discard renderNeelJs("t", -1, @[])

suite "frontend: shared constants":
  test "the shim uses the exported /ws query parameter names":
    check WsPath == "/ws"
    check TokenQueryParam == "token"
    check WindowQueryParam == "window"
    let js = renderNeelJs("tok", 1, @[])
    check (WsPath & "?" & TokenQueryParam & "=") in js
    check ("&" & WindowQueryParam & "=") in js

  test "the rendered shim is a classic script that sets globalThis.neel":
    let js = renderNeelJs("tok", 1, @[])
    check "globalThis.neel = neel;" in js
    for line in js.splitLines:
      check not line.startsWith("import ")
      check not line.startsWith("export ")
