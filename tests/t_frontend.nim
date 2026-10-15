## t_frontend.nim - placeholder substitution for the served `neel.js`, and
## request filtering (`requestRefusal`, `RequestFilter`, `normalizeOrigin`).
##
## No JS runtime is a dependency. The shim's text is checked here in plain
## Nim; its connection behavior is checked by `fixtures/shim_harness.js`
## when `node` is on PATH (the test is skipped otherwise), and by hand in a
## browser against the server by running the examples (`docs/GUIDE.md`
## "Running the examples").

import std/[unittest, json, strutils, sequtils, os, osproc, streams, monotimes, times]
import neel/[frontend, http]
from neel/websocket import isValidCloseCode

const
  Tricky = "a\"b\\c</script><script>alert(1)</script>\n\t\u00e9"
    ## Quotes, backslashes, a script terminator, control chars, non-ASCII.
  ReferenceSource = staticRead("fixtures/shim_reference.js")
    ## The shim as it was before serve mode (three placeholders, no serve
    ## flag), frozen: local mode must still behave exactly like it.
  HarnessPath = currentSourcePath().parentDir / "fixtures" / "shim_harness.js"
  NeelKeys = @["call", "send", "expose", "close", "ready", "windowId", "connected",
               "onclose", "onreconnect"]
    ## `Object.keys(neel)` before the exposed proc names.

proc expected(token: string; windowId: int; exposed: seq[string]; serve: bool): string =
  ## Independent rendering: the source with each placeholder replaced once.
  NeelJsSource.multiReplace(
    (TokenPlaceholder, jsStringLiteral(token)),
    (WindowIdPlaceholder, $windowId),
    (ExposedPlaceholder, jsStringArrayLiteral(exposed)),
    (ServePlaceholder, if serve: "true" else: "false"))

proc reference(token: string; windowId: int; exposed: seq[string]): string =
  ## The frozen pre-serve shim, rendered as it was served then.
  ReferenceSource.multiReplace(
    (TokenPlaceholder, jsStringLiteral(token)),
    (WindowIdPlaceholder, $windowId),
    (ExposedPlaceholder, jsStringArrayLiteral(exposed)))

proc codeLines(js: string): seq[string] =
  ## The non-empty lines of `js` without comments (whole-line `//` comments
  ## and trailing `  // ...` ones), so counts see only what the code does.
  for line in js.splitLines:
    var l = line
    let c = l.find("  // ")
    if c >= 0:
      l = l[0 ..< c]
    if l.strip.len > 0 and not l.strip.startsWith("//"):
      result.add l

proc hasWord(s, word: string): bool =
  ## `word` occurs in `s` as a whole identifier (`SERVE`, not `RESERVED`).
  const Ident = IdentChars + {'$'}
  var at = s.find(word)
  while at >= 0:
    let after = at + word.len
    if (at == 0 or s[at - 1] notin Ident) and (after >= s.len or s[after] notin Ident):
      return true
    at = s.find(word, at + 1)
  false

proc neelKeys(js: string): seq[string] =
  ## The names `Object.defineProperties(neel, {...})` defines, in order.
  let start = js.find("Object.defineProperties(neel, {")
  doAssert start >= 0, "no Object.defineProperties(neel, ...) in the shim"
  let stop = js.find("});", start)
  for line in js[start ..< stop].splitLines[1 .. ^1]:
    let t = line.strip
    if t.len > 0:
      result.add t[0 ..< t.find(':')]

proc blockAfter(lines: seq[string]; header: string): seq[string] =
  ## The lines of the block opened by the code line equal to `header`
  ## (stripped), up to the line that closes it at the header's indentation.
  let at = lines.find(header)
  doAssert at >= 0, "no line " & header.strip
  let indent = lines[at].len - lines[at].strip(trailing = false).len
  for line in lines[at + 1 .. ^1]:
    if line.strip.startsWith("}") and line.len - line.strip(trailing = false).len == indent:
      break
    result.add line

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
  test "all four placeholders are substituted with the exact literals":
    for serve in [false, true]:
      let js = renderNeelJs("abc123", 7, @["add", "fail"], serve)
      check js == expected("abc123", 7, @["add", "fail"], serve)
      check js.count("\"abc123\"") == 1
      check "= 7;" in js
      check js.count("[\"add\",\"fail\"]") == 1
      check js.count("const SERVE = " & $serve & ";") == 1
      check TokenPlaceholder notin js
      check WindowIdPlaceholder notin js
      check ExposedPlaceholder notin js
      check ServePlaceholder notin js

  test "the serve and local renderings differ only in the serve literal":
    let serve = renderNeelJs("abc123", 7, @["add"], serve = true)
    let local = renderNeelJs("abc123", 7, @["add"], serve = false)
    check serve != local
    check local.replace("const SERVE = false;", "const SERVE = true;") == serve
    check serve.len == local.len - 1
    check "const SERVE = __NEEL_SERVE__;" in NeelJsSource

  test "a hostile token is escaped and parses back to itself":
    let js = renderNeelJs(Tricky, 1, @[], false)
    check js == expected(Tricky, 1, @[], false)
    check "</script>" notin js
    # Locate the literal: it is the only place where the escaped token appears.
    let lit = jsStringLiteral(Tricky)
    let at = js.find(lit)
    check at >= 0
    check parseJson(js[at ..< at + lit.len]).getStr == Tricky

  test "exposed list: empty and multi-name":
    # The source itself contains `[]` (an empty array literal), so compare counts.
    let base = NeelJsSource.count("[]")
    check renderNeelJs("t", 1, @[], false).count("[]") == base + 1
    let js = renderNeelJs("t", 1, @["alpha", "beta", "gamma"], false)
    check js.count("[\"alpha\",\"beta\",\"gamma\"]") == 1
    check js.count("[]") == base

  test "no __NEEL_ remains in the output; the source has exactly four, each once":
    check NeelJsSource.count("__NEEL_") == 4
    for placeholder in [TokenPlaceholder, WindowIdPlaceholder, ExposedPlaceholder,
                        ServePlaceholder]:
      check NeelJsSource.count(placeholder) == 1
    for serve in [false, true]:
      check "__NEEL_" notin renderNeelJs("token", 1, @["a"], serve)
      check "__NEEL_" notin renderNeelJs("", 42, @[], serve)

  test "substitution is a single pass: a placeholder name inside the token survives":
    let token = "x" & WindowIdPlaceholder & ServePlaceholder & "y"
    let js = renderNeelJs(token, 3, @[ExposedPlaceholder, ServePlaceholder], true)
    check jsStringLiteral(token) in js
    check jsStringArrayLiteral(@[ExposedPlaceholder, ServePlaceholder]) in js
    # The real placeholders were still replaced exactly once each.
    check js.count(WindowIdPlaceholder) == 1 # the one inside the token literal
    check js.count(ExposedPlaceholder) == 1  # the one inside the array literal
    check js.count(ServePlaceholder) == 2    # one in the token, one in the array
    check js.count("const SERVE = true;") == 1

  test "rendering is pure: byte-identical for equal arguments":
    let a = renderNeelJs("same", 5, @["p", "q"], false)
    let b = renderNeelJs("same", 5, @["p", "q"], false)
    check a == b
    check a.len == b.len
    check renderNeelJs("same", 6, @["p", "q"], false) != a
    check renderNeelJs("other", 5, @["p", "q"], false) != a
    check renderNeelJs("same", 5, @["p"], false) != a
    check renderNeelJs("same", 5, @["p", "q"], true) != a

  test "window id must be positive":
    for serve in [false, true]:
      expect AssertionDefect:
        discard renderNeelJs("t", 0, @[], serve)
      expect AssertionDefect:
        discard renderNeelJs("t", -1, @[], serve)

suite "frontend: shared constants":
  test "the shim uses the exported /ws query parameter names":
    check WsPath == "/ws"
    check TokenQueryParam == "token"
    check WindowQueryParam == "window"
    let js = renderNeelJs("tok", 1, @[], false)
    check (WsPath & "?" & TokenQueryParam & "=") in js
    check ("&" & WindowQueryParam & "=") in js

  test "the shim defines CloseDisplaced and treats it as final, like 1000 and 1001":
    check CloseDisplaced == 4000
    check isValidCloseCode(CloseDisplaced)
    let def = "const CLOSE_DISPLACED = " & $CloseDisplaced & ";"
    check NeelJsSource.count(def) == 1
    let finalBranch = "if (event.code === 1000 || event.code === 1001 || " &
                      "event.code === CLOSE_DISPLACED) {"
    for serve in [false, true]:
      let js = renderNeelJs("tok", 1, @[], serve)
      check js.count(def) == 1
      # The one branch that terminates instead of reconnecting.
      check js.count(finalBranch) == 1
      let branch = js.find(finalBranch)
      check js.find("terminate(", branch) < js.find("scheduleReconnect(", branch)
      # Nothing else in the shim compares close codes.
      check js.count("event.code ===") == 3
      # In ws.onclose the terminating branch comes first, and nothing there
      # reaches the dormant state except through scheduleReconnect.
      let onclose = codeLines(js).blockAfter("    ws.onclose = (event) => {")
      let at = onclose.find("      " & finalBranch)
      check at >= 0
      check onclose[at + 1].strip.startsWith("terminate(")
      check onclose[at + 2].strip == "return;"
      check onclose[^1].strip == "scheduleReconnect(event.code);"
      for line in onclose:
        check "ormant" notin line
        check "wake" notin line

  test "the rendered shim is a classic script that sets globalThis.neel":
    for serve in [false, true]:
      let js = renderNeelJs("tok", 1, @[], serve)
      check "globalThis.neel = neel;" in js
      for line in js.splitLines:
        check not line.startsWith("import ")
        check not line.startsWith("export ")

suite "frontend: the serve flag in the shim":
  test "Object.keys(neel) is unchanged: the flag is not exposed":
    let before = reference("tok", 1, @["add"])
    check neelKeys(before) == NeelKeys
    for serve in [false, true]:
      let js = renderNeelJs("tok", 1, @["add"], serve)
      check neelKeys(js) == NeelKeys
      # The only other property defined on `neel` is each exposed proc.
      check js.count("Object.defineProperty(neel, ") == 1
      check before.count("Object.defineProperty(neel, ") == 1
      for line in codeLines(js):
        check not (line.contains("neel.") and line.hasWord("SERVE"))
        check not line.strip.startsWith("neel.")

  test "the frozen reference is the pre-serve shim":
    check ReferenceSource.count("__NEEL_") == 3
    check ServePlaceholder notin ReferenceSource
    check not ReferenceSource.hasWord("SERVE")
    check "ormant" notin ReferenceSource
    check reference("tok", 1, @[]) != renderNeelJs("tok", 1, @[], false)

  test "serve-only code is reachable only through the flag":
    for serve in [false, true]:
      let lines = codeLines(renderNeelJs("tok", 1, @["add"], serve))
      proc having(needle: string): seq[string] =
        for l in lines:
          if (if needle.allCharsInSet(IdentChars): l.hasWord(needle) else: needle in l):
            result.add l.strip
      # The flag is defined once and read in exactly two places.
      check having("SERVE") == @["const SERVE = " & $serve & ";",
                                 "if (SERVE) goDormant(reason, code);",
                                 "if (SERVE) {"]
      # goDormant is called only behind the flag, and only goDormant sets dormant.
      check having("goDormant(") == @["function goDormant(reason, code) {",
                                      "if (SERVE) goDormant(reason, code);"]
      check having("dormant = true;") == @["dormant = true;"]
      check lines.blockAfter("  function goDormant(reason, code) {")[0].strip ==
        "dormant = true;"
      # Running out of attempts still terminates when the flag is off.
      let giveUp = lines.blockAfter("    if (attempts >= MAX_RECONNECT_ATTEMPTS) {")
      check giveUp.mapIt(it.strip) == @[
        "const reason = \"neel: gave up reconnecting after \" + MAX_RECONNECT_ATTEMPTS + \" attempts\";",
        "if (SERVE) goDormant(reason, code);",
        "else terminate(reason, code);",
        "return;"]
      # The wake listeners exist only inside the flag's block, and wake() is
      # called nowhere else.
      let serveBlock = lines.blockAfter("  if (SERVE) {")
      check having("addEventListener(").len == 2
      check having("wake()").len == 3 # its definition and the two listeners
      for l in lines:
        if "addEventListener(" in l or ("wake()" in l and "function wake()" notin l):
          check l in serveBlock
      check serveBlock.mapIt(it.strip) == @[
        "document.addEventListener(\"visibilitychange\", () => {",
        "if (document.visibilityState === \"visible\") wake();",
        "});",
        "globalThis.addEventListener(\"online\", () => wake());"]

suite "frontend: shim behavior under node":
  test "serve, local, and the frozen reference shim in a scripted browser":
    let node = findExe("node")
    if node.len == 0:
      echo "    skipped: node is not on PATH; the shim's behavior is then checked " &
        "by hand in a browser"
      skip()
    else:
      let dir = getTempDir() / ("neel-shim-" & $getCurrentProcessId())
      createDir(dir)
      try:
        const exposed = @["add", "echo"]
        writeFile(dir / "serve.js", renderNeelJs("tok", 3, exposed, serve = true))
        writeFile(dir / "local.js", renderNeelJs("tok", 3, exposed, serve = false))
        writeFile(dir / "reference.js", reference("tok", 3, exposed))
        let p = startProcess(node, args = [HarnessPath, dir / "serve.js", dir / "local.js",
                                           dir / "reference.js", dir / "report.txt"],
                             options = {poStdErrToStdOut})
        let deadline = getMonoTime() + initDuration(seconds = 60)
        while p.running and getMonoTime() < deadline:
          sleep(20)
        let finished = not p.running
        if not finished:
          p.kill()
        let exitCode = p.waitForExit()
        let output = p.outputStream.readAll()
        p.close()
        let report =
          if fileExists(dir / "report.txt"): readFile(dir / "report.txt") else: ""
        if not finished or exitCode != 0 or not report.startsWith("ok "):
          checkpoint "node harness report:\n" & report & output
        check finished
        check exitCode == 0
        check report.startsWith("ok ")
      finally:
        removeDir(dir)

proc req(path: string; headers: varargs[(string, string)]): HttpRequest =
  HttpRequest(httpMethod: hmGet, path: path, headers: @headers)

const
  Own = ("Host", "127.0.0.1:8000")
  OwnOrigin = ("Origin", "http://127.0.0.1:8000")

let Local = initRequestFilter(serve = false)

suite "frontend: requestRefusal":
  test "requests from Neel's own pages pass":
    check requestRefusal(req("/", Own), 8000, Local) == ""
    check requestRefusal(req("/", Own, ("Sec-Fetch-Site", "none")), 8000, Local) == ""
    check requestRefusal(req(NeelJsPath, Own, ("Sec-Fetch-Site", "same-origin")), 8000, Local) == ""
    check requestRefusal(req(WsPath, Own, OwnOrigin), 8000, Local) == ""
    check requestRefusal(req(WsPath, ("host", "127.0.0.1:8000"),
                             ("origin", "http://127.0.0.1:8000")), 8000, Local) == ""

  test "Host must be 127.0.0.1:<port>":
    check requestRefusal(req("/"), 8000, Local) != ""
    for host in ["", "localhost:8000", "127.0.0.1", "127.0.0.1:8001",
                 "attacker.example:8000", "127.0.0.1:8000.attacker.example",
                 "[::1]:8000"]:
      check requestRefusal(req("/", ("Host", host)), 8000, Local) ==
        "neel: refused: the Host header must be 127.0.0.1:8000"
    check requestRefusal(req(WsPath, ("Host", "attacker.example:8000"), OwnOrigin),
                         8000, Local) != ""

  test "port 80: browsers omit the default port":
    check requestRefusal(req("/", ("Host", "127.0.0.1")), 80, Local) == ""
    check requestRefusal(req("/", ("Host", "127.0.0.1:80")), 80, Local) == ""
    check requestRefusal(req(WsPath, ("Host", "127.0.0.1"),
                             ("Origin", "http://127.0.0.1")), 80, Local) == ""

  test "cross-site requests are refused, whatever the route":
    for path in ["/", NeelJsPath, WsPath]:
      check requestRefusal(req(path, Own, OwnOrigin, ("Sec-Fetch-Site", "cross-site")),
                           8000, Local) == "neel: refused: cross-site request"
    check requestRefusal(req(NeelJsPath, Own, ("Sec-Fetch-Site", "Cross-Site")), 8000, Local) != ""
    check requestRefusal(req(NeelJsPath, Own, ("Sec-Fetch-Site", "same-site")), 8000, Local) == ""

  test "/ws needs this server's Origin":
    check requestRefusal(req(WsPath, Own), 8000, Local) ==
      "neel: refused: the Origin header must be http://127.0.0.1:8000"
    for origin in ["", "null", "http://attacker.example", "http://127.0.0.1:8001",
                   "https://127.0.0.1:8000", "http://localhost:8000",
                   "http://127.0.0.1:8000/", "127.0.0.1:8000"]:
      check requestRefusal(req(WsPath, Own, ("Origin", origin)), 8000, Local) != ""
    # Origin is a WebSocket requirement only.
    check requestRefusal(req("/", Own), 8000, Local) == ""

  test "local mode: cross-site navigations and frames are refused":
    for dest in ["document", "iframe", "frame"]:
      check requestRefusal(req("/", Own, ("Sec-Fetch-Site", "cross-site"),
                               ("Sec-Fetch-Mode", "navigate"), ("Sec-Fetch-Dest", dest)),
                           8000, Local) == "neel: refused: cross-site request"

proc legacyRefusal(req: HttpRequest; port: int): string =
  ## The local-mode rules exactly as they were before the filter existed,
  ## kept here as the reference the new code must match.
  proc own(host: string): bool =
    host == "127.0.0.1:" & $port or (port == 80 and host == "127.0.0.1")
  if not own(req.getHeader("Host")):
    return "neel: refused: the Host header must be 127.0.0.1:" & $port
  if cmpIgnoreCase(req.getHeader("Sec-Fetch-Site"), "cross-site") == 0:
    return "neel: refused: cross-site request"
  if req.path == WsPath:
    let origin = req.getHeader("Origin")
    if not (origin.startsWith("http://") and own(origin["http://".len .. ^1])):
      return "neel: refused: the Origin header must be http://127.0.0.1:" & $port
  ""

suite "frontend: requestRefusal, local mode unchanged":
  test "every combination of the filtered headers matches the old rules":
    # A non-serve filter ignores its origins, so one that has some must
    # behave exactly like the plain local filter.
    let localWithOrigins = initRequestFilter(serve = false,
                                             @["https://myapp.example.com"])
    var compared, mismatches = 0
    var firstMismatch = ""
    for port in [8000, 80]:
      for path in ["/", "/index.html", NeelJsPath, WsPath]:
        for host in ["-", "127.0.0.1:" & $port, "127.0.0.1", "myapp.example.com",
                     "attacker.example:8000"]:
          for site in ["-", "same-origin", "same-site", "none", "cross-site", "Cross-Site"]:
            for mode in ["-", "navigate", "no-cors", "websocket"]:
              for dest in ["-", "document", "iframe", "script"]:
                for origin in ["-", "http://127.0.0.1:" & $port, "http://127.0.0.1",
                               "https://myapp.example.com", "null"]:
                  var headers: seq[(string, string)]
                  for (name, value) in [("Host", host), ("Sec-Fetch-Site", site),
                                        ("Sec-Fetch-Mode", mode),
                                        ("Sec-Fetch-Dest", dest), ("Origin", origin)]:
                    if value != "-":
                      headers.add((name, value))
                  let r = req(path, headers)
                  let want = legacyRefusal(r, port)
                  for filter in [Local, localWithOrigins]:
                    inc compared
                    let got = requestRefusal(r, port, filter)
                    if got != want:
                      inc mismatches
                      if firstMismatch.len == 0:
                        firstMismatch = $port & " " & path & " " & $headers &
                          ": got " & escape(got) & ", want " & escape(want)
    check compared > 10_000
    check mismatches == 0
    if mismatches > 0:
      checkpoint firstMismatch

  test "the zero value is local mode":
    check RequestFilter() == Local
    check not Local.serve
    check Local.origins.len == 0
    check Local.hosts.len == 0

suite "frontend: normalizeOrigin":
  test "scheme and host are lowercased":
    check normalizeOrigin("HTTPS://MyApp.Example.COM") == "https://myapp.example.com"
    check normalizeOrigin("Http://LAN.example:8080") == "http://lan.example:8080"

  test "the scheme's default port is dropped, any other port kept":
    check normalizeOrigin("https://a.example:443") == "https://a.example"
    check normalizeOrigin("http://a.example:80") == "http://a.example"
    check normalizeOrigin("http://a.example:443") == "http://a.example:443"
    check normalizeOrigin("https://a.example:80") == "https://a.example:80"
    check normalizeOrigin("https://a.example:8443") == "https://a.example:8443"
    check normalizeOrigin("https://a.example:0443") == "https://a.example"
    check normalizeOrigin("http://a.example:08080") == "http://a.example:8080"
    check normalizeOrigin("http://a.example:1") == "http://a.example:1"
    check normalizeOrigin("http://a.example:65535") == "http://a.example:65535"

  test "IP addresses, underscores, and single-label hosts are accepted":
    check normalizeOrigin("http://127.0.0.1:8080") == "http://127.0.0.1:8080"
    check normalizeOrigin("http://[::1]:8080") == "http://[::1]:8080"
    check normalizeOrigin("HTTPS://[FE80::1]:443") == "https://[fe80::1]"
    check normalizeOrigin("http://[::ffff:127.0.0.1]") == "http://[::ffff:127.0.0.1]"
    check normalizeOrigin("https://my_host.example") == "https://my_host.example"
    check normalizeOrigin("http://devbox:3000") == "http://devbox:3000"
    check normalizeOrigin("https://xn--bcher-kva.example") ==
      "https://xn--bcher-kva.example"

  test "normalizing is idempotent":
    for o in ["HTTPS://A.example:443", "http://[::1]:80", "http://b.example:8080"]:
      let n = normalizeOrigin(o)
      check normalizeOrigin(n) == n

  test "every malformed form raises ValueError naming allowedOrigins":
    for (entry, why) in [
        ("", "is empty"),
        ("https://a.example/", "has a path"),
        ("https://a.example/app", "has a path"),
        ("https://a.example:8443/", "has a path"),
        ("https://a.example?x=1", "has a query"),
        ("https://a.example#top", "has a fragment"),
        ("https://user@a.example", "has user info"),
        ("https://user:pw@a.example", "has user info"),
        ("https://*.example.com", "has a wildcard"),
        ("*", "has no scheme"),
        ("https://a.example:*", "has a wildcard"),
        ("ftp://a.example", "unsupported scheme"),
        ("ws://a.example", "unsupported scheme"),
        ("wss://a.example", "unsupported scheme"),
        ("file://a.example", "unsupported scheme"),
        ("://a.example", "unsupported scheme"),
        ("a.example", "has no scheme"),
        ("a.example:8080", "has no scheme"),
        ("//a.example", "has no scheme"),
        ("null", "has no scheme"),
        ("https:a.example", "has no scheme"),
        ("https://", "has no host"),
        ("https://:8443", "has no host"),
        ("https://a.example:", "invalid port"),
        ("https://a.example:abc", "invalid port"),
        ("https://a.example:+443", "invalid port"),
        ("https://a.example:-1", "invalid port"),
        ("https://a.example:443:443", "invalid port"),
        ("https://a.example:123456", "invalid port"),
        ("https://a.example:99999999999999999999", "invalid port"),
        ("https://a.example:0", "outside 1-65535"),
        ("https://a.example:65536", "outside 1-65535"),
        (" https://a.example", "whitespace"),
        ("https://a.example ", "whitespace"),
        ("https://a .example", "whitespace"),
        ("https://a.example\t", "whitespace"),
        ("https://a.example\r\n", "whitespace"),
        ("https://b\u00FCcher.example", "non-ASCII"),
        ("https://a%2eexample", "invalid host"),
        ("https://a,b.example", "invalid host"),
        ("https://a\\b.example", "invalid host"),
        ("https://[::1", "invalid IPv6 host"),
        ("https://[]", "invalid IPv6 host"),
        ("https://[::1]x", "invalid IPv6 host"),
        ("https://[::1]:", "invalid port"),
        ("https://[g::1]", "invalid IPv6 host"),
        ("https://::1", "has no host")]:
      var raised = false
      try:
        discard normalizeOrigin(entry)
      except ValueError as e:
        raised = true
        check "allowedOrigins" in e.msg
        check escape(entry) in e.msg
        check why in e.msg
        if why notin e.msg:
          checkpoint entry & ": " & e.msg
      if not raised:
        checkpoint "accepted: " & escape(entry)
      check raised

suite "frontend: initRequestFilter":
  test "origins are normalized and their hosts derived":
    let f = initRequestFilter(serve = true,
      @["HTTPS://MyApp.Example.com:443", "http://lan.example:8080", "http://[::1]:9000"])
    check f.serve
    check f.origins == @["https://myapp.example.com", "http://lan.example:8080",
                         "http://[::1]:9000"]
    check f.hosts == @["myapp.example.com", "lan.example:8080", "[::1]:9000"]

  test "duplicates after normalization are kept once":
    let f = initRequestFilter(serve = true,
      @["https://a.example", "HTTPS://A.EXAMPLE:443", "http://a.example:443",
        "https://a.example:443"])
    check f.origins == @["https://a.example", "http://a.example:443"]
    check f.hosts == @["a.example", "a.example:443"]
    # Same host under both schemes: two origins, one host.
    let g = initRequestFilter(serve = true, @["http://a.example", "https://a.example"])
    check g.origins == @["http://a.example", "https://a.example"]
    check g.hosts == @["a.example"]

  test "a malformed entry raises, whatever its position":
    expect ValueError:
      discard initRequestFilter(serve = true, @["https://a.example/"])
    expect ValueError:
      discard initRequestFilter(serve = true, @["https://a.example", "https://*.b.example"])

  test "serve mode with no origins":
    let f = initRequestFilter(serve = true)
    check f.serve
    check f.origins.len == 0
    check f.hosts.len == 0

const
  ServePort = 8080
  PublicHost = ("Host", "myapp.example.com")
  PublicOrigin = ("Origin", "https://myapp.example.com")
  LoopHost = ("Host", "127.0.0.1:8080")
  LoopOrigin = ("Origin", "http://127.0.0.1:8080")
  CrossSite = ("Sec-Fetch-Site", "cross-site")
  Navigate = ("Sec-Fetch-Mode", "navigate")

let Serve = initRequestFilter(serve = true,
  @["HTTPS://MyApp.Example.com:443", "http://lan.example:8080"])

proc serveRefusal(path: string; headers: varargs[(string, string)]): string =
  requestRefusal(req(path, headers), ServePort, Serve)

suite "frontend: requestRefusal, serve mode":
  test "an allowed origin is accepted on /ws, with its public Host":
    check serveRefusal(WsPath, PublicHost, PublicOrigin) == ""
    check serveRefusal(WsPath, ("Host", "lan.example:8080"),
                       ("Origin", "http://lan.example:8080")) == ""

  test "Host rewritten to 127.0.0.1:<port> by the proxy, public Origin":
    check serveRefusal(WsPath, LoopHost, PublicOrigin) == ""
    check serveRefusal("/", LoopHost) == ""

  test "Neel's own host and origin still pass (SSH port forward)":
    check serveRefusal(WsPath, LoopHost, LoopOrigin) == ""
    let bare = initRequestFilter(serve = true)
    check requestRefusal(req(WsPath, LoopHost, LoopOrigin), ServePort, bare) == ""
    check requestRefusal(req("/", LoopHost), ServePort, bare) == ""

  test "the Host of an allowed origin passes on every route":
    for path in ["/", "/index.html", NeelJsPath]:
      check serveRefusal(path, PublicHost) == ""
      check serveRefusal(path, ("Host", "lan.example:8080")) == ""

  test "any other Host is refused, matching exactly":
    const want = "neel: refused: the Host header must be 127.0.0.1:8080 " &
                 "or the host of an allowed origin"
    check serveRefusal("/") == want
    for host in ["", "attacker.example", "myapp.example.com:443",
                 "myapp.example.com.attacker.example", "MyApp.example.com",
                 "lan.example", "lan.example:8081", "lan.example:80",
                 "https://myapp.example.com", "127.0.0.1:8081"]:
      check serveRefusal("/", ("Host", host)) == want
    check serveRefusal(WsPath, ("Host", "attacker.example"), PublicOrigin) == want

  test "/ws: port mismatch, scheme mismatch, trailing slash, other sites are refused":
    const want = "neel: refused: the Origin header must be http://127.0.0.1:8080 " &
                 "or an allowed origin"
    check serveRefusal(WsPath, PublicHost) == want
    for origin in ["", "null", "https://myapp.example.com:8443",
                   "https://myapp.example.com:443", "http://lan.example:8081",
                   "http://lan.example", "http://myapp.example.com",
                   "https://lan.example:8080", "https://myapp.example.com/",
                   "https://MyApp.example.com", "myapp.example.com",
                   "https://attacker.example", "https://myapp.example.com.attacker.example",
                   "http://127.0.0.1:8081"]:
      check serveRefusal(WsPath, PublicHost, ("Origin", origin)) == want

  test "with no allowed origins the refusal texts are the local ones":
    let bare = initRequestFilter(serve = true)
    check requestRefusal(req("/", PublicHost), ServePort, bare) ==
      "neel: refused: the Host header must be 127.0.0.1:8080"
    check requestRefusal(req(WsPath, LoopHost, PublicOrigin), ServePort, bare) ==
      "neel: refused: the Origin header must be http://127.0.0.1:8080"

  test "cross-site top-level document navigation passes":
    for path in ["/", "/index.html", "/app?x=1"]:
      check serveRefusal(path, PublicHost, CrossSite, Navigate,
                         ("Sec-Fetch-Dest", "document")) == ""
    check serveRefusal("/", PublicHost, ("Sec-Fetch-Site", "Cross-Site"),
                       ("Sec-Fetch-Mode", "Navigate"), ("Sec-Fetch-Dest", "Document")) == ""
    let bare = initRequestFilter(serve = true)
    check requestRefusal(req("/", LoopHost, CrossSite, Navigate,
                             ("Sec-Fetch-Dest", "document")), ServePort, bare) == ""

  test "cross-site frames and embeds are refused":
    for dest in ["iframe", "frame", "embed", "object", "", "documentx"]:
      check serveRefusal("/", PublicHost, CrossSite, Navigate,
                         ("Sec-Fetch-Dest", dest)) == "neel: refused: cross-site request"
    check serveRefusal("/", PublicHost, CrossSite, Navigate) ==
      "neel: refused: cross-site request"

  test "cross-site subresources and fetches are refused":
    check serveRefusal(NeelJsPath, PublicHost, CrossSite, ("Sec-Fetch-Mode", "no-cors"),
                       ("Sec-Fetch-Dest", "script")) == "neel: refused: cross-site request"
    check serveRefusal(NeelJsPath, PublicHost, CrossSite, ("Sec-Fetch-Mode", "cors"),
                       ("Sec-Fetch-Dest", "empty")) == "neel: refused: cross-site request"
    check serveRefusal(NeelJsPath, PublicHost, CrossSite,
                       ("Sec-Fetch-Dest", "document")) == "neel: refused: cross-site request"
    check serveRefusal(WsPath, PublicHost, PublicOrigin, CrossSite,
                       ("Sec-Fetch-Mode", "websocket"), ("Sec-Fetch-Dest", "websocket")) ==
      "neel: refused: cross-site request"

  test "a cross-site navigation to /ws still needs an allowed Origin":
    check serveRefusal(WsPath, PublicHost, CrossSite, Navigate,
                       ("Sec-Fetch-Dest", "document")) ==
      "neel: refused: the Origin header must be http://127.0.0.1:8080 or an allowed origin"

  test "same-site, same-origin, none, and headerless requests pass":
    for site in ["same-origin", "same-site", "none"]:
      check serveRefusal(NeelJsPath, PublicHost, ("Sec-Fetch-Site", site)) == ""
    check serveRefusal(NeelJsPath, PublicHost) == ""
