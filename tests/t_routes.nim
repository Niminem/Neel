## t_routes.nim - custom routes without a server: pattern syntax, matching
## against raw request paths (decoding, parameters, the tail wildcard, paths
## no route may match), method handling and `Allow`, validation of a route
## list, and the helpers a handler uses.

import std/[unittest, strutils, json]
import neel/[routes, http]

proc ok(req: HttpRequest): HttpResponse {.gcsafe.} =
  textResponse("ok")

proc other(req: HttpRequest): HttpResponse {.gcsafe.} =
  textResponse("other")

proc inferred(req: HttpRequest): HttpResponse =
  ## No `{.gcsafe.}`: the compiler infers it, as for an application's procs.
  htmlResponse("<p>" & req.param("id") & "</p>")

proc errorOf(body: proc()): string =
  ## The message of the `ValueError` `body` raises, or `""` if it returns.
  try:
    body()
  except ValueError as e:
    return e.msg
  ""

proc find(routes: openArray[Route]; path: string; httpMethod = hmGet): RouteMatch =
  findRoute(routes, httpMethod, path)

proc paramsOf(pattern, path: string): string =
  ## `"name=value,..."` when `pattern` matches `path`, else `"<no match>"`.
  let m = find([get(pattern, ok)], path)
  if m.kind != rmFound:
    return "<no match>"
  var parts: seq[string]
  for (k, v) in m.params:
    parts.add k & "=" & v
  parts.join(",")

suite "routes: building":
  test "the shorthands list their method; GET also answers HEAD":
    check get("/a", ok).methods == {hmGet, hmHead}
    check post("/a", ok).methods == {hmPost}
    check put("/a", ok).methods == {hmPut}
    check patch("/a", ok).methods == {hmPatch}
    check delete("/a", ok).methods == {hmDelete}
    check route({hmGet, hmPost}, "/a", ok).methods == {hmGet, hmHead, hmPost}
    check route({hmHead}, "/a", ok).methods == {hmHead}
    check route({hmOptions}, "/a", ok).methods == {hmOptions}
    let r = post("/hooks/@name", other)
    check r.pattern == "/hooks/@name"
    check r.handler == RouteHandler(other)
    check Route().handler.isNil

  test "a top-level proc converts with its gcsafety inferred; a closure does not":
    check get("/x/@id", inferred).handler == RouteHandler(inferred)
    var captured = "state"
    let closure = proc(req: HttpRequest): HttpResponse =
      textResponse(captured)
    check not compiles(get("/x", closure))
    check compiles(get("/x", proc(req: HttpRequest): HttpResponse = textResponse("lit")))

  test "what a route cannot be built from":
    check errorOf(proc() = discard route({}, "/a", ok)) ==
      "neel: route \"/a\" lists no method"
    check errorOf(proc() = discard route({hmGet, hmOther}, "/a", ok)).contains("hmOther")
    check errorOf(proc() = discard get("/a", nil)) == "neel: route \"/a\" has a nil handler"

  test "malformed patterns say what is wrong":
    for (pattern, why) in [
        ("", "must start with '/'"),
        ("a/b", "must start with '/'"),
        ("@id", "must start with '/'"),
        ("/a b", "must not contain"),
        ("/a?x=1", "must not contain"),
        ("/a#top", "must not contain"),
        ("/a\\b", "must not contain"),
        ("/a\tb", "must not contain"),
        ("/@", "'@' without a parameter name"),
        ("/a/@/b", "'@' without a parameter name"),
        ("/@na-me", "characters other than letters"),
        ("/@a.b", "characters other than letters"),
        ("/*rest/more", "'*' before its last segment"),
        ("/*/more", "'*' before its last segment"),
        ("/*re.st", "characters other than letters"),
        ("/@id/@id", "names the parameter \"id\" twice"),
        ("/@x/*x", "names the parameter \"x\" twice"),
        ("/a/../b", "no request path can match"),
        ("/./a", "no request path can match"),
        ("/a%2Fb", "no request path can match"),
        ("/%2E%2E/a", "no request path can match")]:
      let msg = errorOf(proc() = discard get(pattern, ok))
      check msg.startsWith("neel: route " & escape(pattern) & " ")
      check why in msg

  test "well-formed patterns":
    for pattern in ["/", "/a", "/a/", "/a/b.html", "/@id", "/a/@id/b/@other_2",
                    "/*", "/*rest", "/files/*path", "/a-b_c~d", "/a%20b",
                    "/%40handle", "/a@b", "/a*b", "/x/@_"]:
      check errorOf(proc() = discard get(pattern, ok)) == ""

suite "routes: matching a path":
  test "literal segments, exactly":
    check paramsOf("/", "/") == ""
    check paramsOf("/about", "/about") == ""
    check paramsOf("/a/b/c.html", "/a/b/c.html") == ""
    for (pattern, path) in [("/", "/index.html"), ("/about", "/"),
                            ("/about", "/About"), ("/about", "/about/"),
                            ("/about/", "/about"), ("/about", "/about/x"),
                            ("/a/b", "/a"), ("/a", "/a//"), ("/a/b", "/a//b"),
                            ("/about", "about"), ("/about", "")]:
      check paramsOf(pattern, path) == "<no match>"
    check paramsOf("/about/", "/about/") == ""

  test "the query string is not part of the path":
    # `HttpRequest.path` never holds one; a literal '?' is just a character.
    check paramsOf("/a", "/a?x=1") == "<no match>"

  test "@name captures exactly one non-empty segment":
    check paramsOf("/users/@id", "/users/42") == "id=42"
    check paramsOf("/@a/@b", "/x/y") == "a=x,b=y"
    check paramsOf("/users/@id/posts/@post", "/users/7/posts/first") == "id=7,post=first"
    check paramsOf("/users/@id", "/users/") == "<no match>"
    check paramsOf("/users/@id", "/users") == "<no match>"
    check paramsOf("/users/@id", "/users/1/2") == "<no match>"
    check paramsOf("/@id", "/") == "<no match>"

  test "*name captures the rest, zero or more segments":
    check paramsOf("/files/*path", "/files/a/b/c.txt") == "path=a/b/c.txt"
    check paramsOf("/files/*path", "/files/a") == "path=a"
    check paramsOf("/files/*path", "/files/") == "path="
    check paramsOf("/files/*path", "/files") == "path="
    check paramsOf("/files/*path", "/files/a/") == "path=a/"
    check paramsOf("/files/*path", "/other/a") == "<no match>"
    check paramsOf("/*", "/") == "*="
    check paramsOf("/*", "/anything/at/all") == "*=anything/at/all"
    check paramsOf("/c/@name/f/*rest", "/c/acme/f/2024/q1.pdf") == "name=acme,rest=2024/q1.pdf"

  test "segments are percent-decoded; '+' is not a space":
    check paramsOf("/users/@id", "/users/J%C3%BCrgen") == "id=J\xC3\xBCrgen"
    check paramsOf("/users/@id", "/users/a%20b") == "id=a b"
    check paramsOf("/users/@id", "/users/a+b") == "id=a+b"
    check paramsOf("/users/@id", "/users/100%") == "id=100%"   # bad escape kept
    check paramsOf("/a%20b", "/a%20b") == ""
    check paramsOf("/a%20b", "/a b") == ""
    check paramsOf("/about", "/%61bout") == ""
    check paramsOf("/%40handle", "/@handle") == ""
    check paramsOf("/%40handle", "/x") == "<no match>"
    check paramsOf("/a@b", "/a@b") == ""

  test "paths that no route may match: dot segments, backslash, encoded slash, NUL":
    for path in ["/files/../secret", "/files/..", "/files/./a", "/files/%2E%2E/secret",
                 "/files/%2e%2e/secret", "/files/a/%2E", "/files/..%2Fsecret",
                 "/files/a%2Fb", "/files/a%2fb", "/files/..%5C..%5Csecret",
                 "/files/a\\b", "/files/a%5Cb", "/files/a%00b", "/../files/a"]:
      check paramsOf("/files/*path", path) == "<no match>"
      check paramsOf("/*", path) == "<no match>"
    check paramsOf("/@a/@b", "/x/..") == "<no match>"
    # Dots inside a name are ordinary characters.
    check paramsOf("/files/*path", "/files/a..b/.hidden/c...") == "path=a..b/.hidden/c..."

suite "routes: findRoute":
  test "an empty list matches nothing":
    check find(newSeq[Route](), "/").kind == rmNone

  test "the first route in list order wins":
    let routes = [get("/users/me", ok), get("/users/@id", other), get("/*", ok)]
    check find(routes, "/users/me").index == 0
    check find(routes, "/users/me").params.len == 0
    let byId = find(routes, "/users/7")
    check byId.kind == rmFound
    check byId.index == 1
    check byId.params == @[(name: "id", value: "7")]
    check find(routes, "/elsewhere").index == 2
    # Reversed, the catch-all takes everything.
    let reversed = [get("/*", ok), get("/users/@id", other)]
    check find(reversed, "/users/7").index == 0

  test "the method picks among routes that share a path":
    let routes = [get("/items", ok), post("/items", other),
                  route({hmPut, hmDelete}, "/items/@id", ok)]
    check find(routes, "/items", hmGet).index == 0
    check find(routes, "/items", hmHead).index == 0
    check find(routes, "/items", hmPost).index == 1
    check find(routes, "/items/3", hmPut).index == 2
    check find(routes, "/items/3", hmDelete).params == @[(name: "id", value: "3")]

  test "a path that matches only for other methods is 405 with every allowed method":
    let routes = [get("/items", ok), post("/items", other),
                  route({hmPut, hmDelete}, "/items/@id", ok), post("/hook", ok)]
    let m = find(routes, "/items", hmDelete)
    check m.kind == rmMethodNotAllowed
    check m.allow == "GET, HEAD, POST"
    check find(routes, "/items/3", hmGet).allow == "PUT, DELETE"
    check find(routes, "/hook", hmGet).kind == rmMethodNotAllowed
    check find(routes, "/hook", hmHead).allow == "POST"
    check find(routes, "/items", hmOptions).allow == "GET, HEAD, POST"
    # A method Neel does not route never matches, but the path is known.
    check find(routes, "/items", hmOther).kind == rmMethodNotAllowed
    # No pattern matches: not this module's business.
    check find(routes, "/nope", hmPost).kind == rmNone
    check find(routes, "/items/../hook", hmPost).kind == rmNone

  test "OPTIONS and HEAD can be routed explicitly":
    let routes = [route({hmOptions}, "/api/*", ok), route({hmHead}, "/ping", other),
                  get("/ping", ok)]
    check find(routes, "/api/x", hmOptions).kind == rmFound
    check find(routes, "/ping", hmHead).index == 1
    check find(routes, "/ping", hmGet).index == 2

suite "routes: checkRoutes":
  const Reserved = ["/ws", "/neel.js", "/neel/no-browser"]

  test "a usable list passes":
    checkRoutes(newSeq[Route](), Reserved)
    checkRoutes([get("/", ok), post("/", other), get("/users/@id", ok),
                 get("/users/@id/posts", ok), route({hmGet, hmPost}, "/both", ok),
                 get("/neel/other", ok), get("/@anything", ok), get("/*", ok)],
                Reserved)

  test "an entry that was never built":
    check errorOf(proc() = checkRoutes([get("/", ok), Route()], Reserved)) ==
      "neel: routes[1] is empty; build routes with get, post, put, patch, delete, or route"

  test "Neel's own paths are reserved, however the literal is spelled":
    for pattern in ["/ws", "/neel.js", "/neel/no-browser", "/neel%2Ejs", "/%77s"]:
      let msg = errorOf(proc() = checkRoutes([post(pattern, ok)], Reserved))
      check msg.startsWith("neel: route " & escape(pattern) & " is reserved")
    # Parameters may overlap a reserved path; Neel answers those first anyway.
    checkRoutes([get("/neel/@page", ok), get("/@top", ok)], Reserved)

  test "a route that an earlier one shadows completely":
    check errorOf(proc() = checkRoutes([get("/a", ok), get("/a", other)], Reserved)) ==
      "neel: route GET, HEAD \"/a\" can never run: \"/a\" comes before it and " &
      "matches the same requests"
    # Parameter names do not make two patterns different.
    check errorOf(proc() = checkRoutes([get("/u/@id", ok), get("/u/@name", other)],
                                       Reserved)).contains("can never run")
    check errorOf(proc() = checkRoutes([get("/f/*a", ok), get("/f/*b", other)],
                                       Reserved)).contains("can never run")
    check errorOf(proc() = checkRoutes([route({hmGet, hmPost}, "/a", ok), post("/a", other)],
                                       Reserved)).contains("can never run")
    check errorOf(proc() = checkRoutes([get("/a", ok), route({hmHead}, "/a", other)],
                                       Reserved)).contains("can never run")
    # Partly shadowed, or shadowed by a different shape, is the app's choice.
    checkRoutes([get("/a", ok), route({hmGet, hmPost}, "/a", other)], Reserved)
    checkRoutes([get("/u/@id", ok), get("/u/me", other)], Reserved)
    checkRoutes([get("/*", ok), get("/a", other)], Reserved)
    checkRoutes([get("/a", ok), get("/a/", other)], Reserved)

suite "routes: helpers for handlers":
  test "param reads what the pattern captured":
    let m = find([get("/c/@name/f/*rest", ok)], "/c/acme/f/a/b")
    let req = HttpRequest(params: m.params)
    check req.param("name") == "acme"
    check req.param("rest") == "a/b"
    check req.param("missing") == ""
    check HttpRequest().param("name") == ""
    let star = HttpRequest(params: find([get("/*", ok)], "/x/y").params)
    check star.param("*") == "x/y"

  test "queryParam decodes the first value":
    let req = HttpRequest(query: "q=a+b%26c&n=1&n=2&empty=&flag")
    check req.queryParam("q") == "a b&c"
    check req.queryParam("n") == "1"
    check req.queryParam("empty") == ""
    check req.queryParam("flag") == ""
    check req.queryParam("missing") == ""
    check HttpRequest().queryParam("q") == ""

  test "response helpers set the status, the type, and the body":
    let html = htmlResponse("<p>hi</p>")
    check html.status == 200
    check html.getHeader("Content-Type") == "text/html; charset=utf-8"
    check html.body == "<p>hi</p>"
    let text = textResponse("nope", 404)
    check text.status == 404
    check text.getHeader("Content-Type") == "text/plain; charset=utf-8"
    let js = jsonResponse(%*{"ok": true, "n": [1, 2]}, 201)
    check js.status == 201
    check js.getHeader("Content-Type") == "application/json"
    check parseJson(js.body) == %*{"ok": true, "n": [1, 2]}
    check jsonResponse(nil).body == "null"
    let moved = redirectResponse("/login?next=%2F")
    check moved.status == 302
    check moved.getHeader("Location") == "/login?next=%2F"
    check moved.body == ""
    check redirectResponse("/done", 303).status == 303
    check encodeResponse(moved, true).startsWith("HTTP/1.1 302 Found\r\n")

suite "routes: finishRouteResponse":
  test "a default response is a 200; valid ones are left alone":
    var r = HttpResponse(body: "hi")
    check finishRouteResponse(r) == ""
    check r.status == 200
    check r.body == "hi"
    for status in [200, 204, 302, 404, 500, 599]:
      var s = initResponse(status, "x", "text/plain")
      s.addHeader("X-Custom_1", "a value; with=punctuation \t and a tab")
      check finishRouteResponse(s) == ""
      check s.status == status

  test "statuses that cannot be sent as a route's answer":
    for status in [-1, 1, 99, 100, 101, 199, 600, 1000]:
      var r = initResponse(status)
      check finishRouteResponse(r) == "status " & $status & " is outside 200..599"

  test "headers that would break the response's framing":
    for value in ["a\r\nSet-Cookie: x=1", "a\nb", "a\rb", "a\0b"]:
      var r = redirectResponse(value)
      check finishRouteResponse(r) == "header Location has a line break or NUL in its value"
    for name in ["", "X Y", "X:Y", "X\r\nY", "Na\xC3\xAFve"]:
      var r = initResponse(200)
      r.addHeader(name, "v")
      check finishRouteResponse(r).startsWith("invalid header name ")
