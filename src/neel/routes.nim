## routes.nim - custom HTTP routes: patterns, matching, and the helpers a
## route handler uses. No socket IO and no global state here.
##
## An application hands `startApp` a list of routes (`routes = @[get("/",
## home), post("/hooks/slack", slackHook)]`). `neel.nim` validates the list
## with `checkRoutes` before anything is bound, stores it, and asks
## `findRoute` about every request that is neither one of Neel's reserved
## paths nor answered by a file of the web directory (files come first, so
## a wildcard route cannot hide them). The list never changes while the app
## runs, so the workers read it without a lock.
##
## Surface:
## - `RouteHandler = proc(req: HttpRequest): HttpResponse {.nimcall, gcsafe.}`:
##   a plain top-level proc (a closure does not convert, so no captured
##   environment is ever shared between workers). It runs on a pool worker
##   like an exposed proc: it may block, and shared state needs a lock.
## - `route(methods, pattern, handler)` and the shorthands `get`, `post`,
##   `put`, `patch`, `delete`: build a `Route`; a malformed pattern, an
##   empty method set, or a `nil` handler raises `ValueError` at once.
##   A route that lists `GET` also answers `HEAD` (the server strips the
##   body).
## - Patterns start with `/` and are compared segment by segment against
##   the percent-decoded request path, case-sensitively, with no trailing
##   slash folding (`/a` and `/a/` are different routes). A segment is
##   literal text, `@name` (exactly one non-empty segment, captured), or,
##   as the last segment only, `*name` / `*` (the rest of the path, zero or
##   more segments joined with `/`, captured as `name` / `"*"`).
## - `findRoute(routes, httpMethod, rawPath)`: the first route, in list
##   order, whose pattern matches the path and whose methods include the
##   request's (`rmFound`, with its index and the captured parameters);
##   `rmMethodNotAllowed` with the `Allow` value when patterns match but no
##   method does; `rmNone` otherwise. A request path with a `.` or `..`
##   segment, or whose decoded form holds a backslash, an encoded `/`, or a
##   NUL, matches no route at all, so a captured value is always a clean
##   relative path that cannot climb out of a directory it is joined to.
## - `checkRoutes(routes, reserved)`: `ValueError` for an uninitialized
##   `Route`, a pattern that is one of the `reserved` paths, or a route
##   that can never run because an earlier one with the same shape already
##   takes all of its methods.
## - For handlers: `param(req, name)` (a captured path parameter),
##   `queryParam(req, name)` (a decoded query-string value), and
##   `htmlResponse`, `textResponse`, `jsonResponse`, `redirectResponse` on
##   top of `http.initResponse` / `addHeader` / `setHeader`.
## - `finishRouteResponse(r)`: what `neel.nim` applies to a handler's
##   result before it is sent: a status of `0` becomes 200; any other
##   status outside 200..599 and any header that would break the framing
##   (an invalid name, CR / LF / NUL in a value) is reported so the caller
##   can answer 500 instead.

import std/[strutils, uri, json]
import ./http

type
  RouteHandler* = proc(req: HttpRequest): HttpResponse {.nimcall, gcsafe.}
    ## Answers one request. Runs on a pool worker; a `CatchableError` it
    ## raises becomes a 500. `req.params` holds the captured path
    ## parameters (see `param`), `req.body` the request body.

  SegmentKind = enum
    skLiteral  # must equal the request segment
    skParam    # `@name`: one non-empty segment
    skTail     # `*name`: the rest of the path

  Segment = object
    kind: SegmentKind
    text: string  # the literal (percent-decoded), or the parameter name

  Route* = object
    ## One entry of `startApp`'s `routes`. Build with `route`, `get`,
    ## `post`, `put`, `patch`, or `delete`.
    methods: set[HttpMethod]  # as registered, plus HEAD when GET is listed
    pattern: string
    segments: seq[Segment]
    handler: RouteHandler

  RouteMatchKind* = enum
    ## Outcome of `findRoute`.
    rmNone              ## No pattern matches the path.
    rmFound             ## `index` names the route to run with `params`.
    rmMethodNotAllowed  ## Patterns match, but not for this method: 405 with `allow`.

  RouteMatch* = object
    ## What `findRoute` returns; which fields are meaningful depends on `kind`.
    kind*: RouteMatchKind
    index*: int  ## Position of the matching route in the list (`rmFound`).
    params*: seq[tuple[name, value: string]]
      ## Captured path parameters, decoded, in pattern order (`rmFound`).
    allow*: string
      ## `Allow` header value: every method some matching pattern accepts
      ## (`rmMethodNotAllowed`).

const
  HtmlType = "text/html; charset=utf-8"
  TextType = "text/plain; charset=utf-8"
  JsonType = "application/json"
  HeaderNameChars = {'a'..'z', 'A'..'Z', '0'..'9', '!', '#', '$', '%', '&', '\'',
                     '*', '+', '-', '.', '^', '_', '`', '|', '~'}
    # RFC 7230 section 3.2.6 `tchar`.

# --- building routes -------------------------------------------------------------

proc parsePattern(pattern: string): seq[Segment] =
  ## The segments of `pattern`, or `ValueError` saying what is wrong with it.
  template bad(why: string) =
    raise newException(ValueError, "neel: route " & escape(pattern) & " " & why)
  if pattern.len == 0 or pattern[0] != '/':
    bad("must start with '/'")
  for c in pattern:
    if c <= ' ' or c == '\x7F' or c in {'?', '#', '\\'}:
      bad("must not contain whitespace, control characters, '?', '#', or '\\'")
  let parts = pattern[1 .. ^1].split('/')
  var names: seq[string]
  for i, part in parts:
    if part.len > 0 and part[0] in {'@', '*'}:
      let tail = part[0] == '*'
      var name = part[1 .. ^1]
      if not name.allCharsInSet(IdentChars):
        bad("has a parameter name with characters other than letters, " &
            "digits, and '_': " & escape(part))
      if tail:
        if i != parts.high:
          bad("has '*' before its last segment")
        if name.len == 0:
          name = "*"
      elif name.len == 0:
        bad("has a '@' without a parameter name")
      if name in names:
        bad("names the parameter " & escape(name) & " twice")
      names.add name
      result.add Segment(kind: (if tail: skTail else: skParam), text: name)
    else:
      # `decodeUrl` never raises: a `%` not followed by two hex digits is kept.
      let literal = decodeUrl(part, decodePlus = false)
      if literal in [".", ".."] or '/' in literal or '\0' in literal:
        bad("has a segment that no request path can match: " & escape(part))
      result.add Segment(kind: skLiteral, text: literal)

proc route*(methods: set[HttpMethod]; pattern: string; handler: RouteHandler): Route =
  ## A route answering `methods` on `pattern` with `handler`. `GET` implies
  ## `HEAD`. Raises `ValueError` for an empty method set, `hmOther` (not a
  ## routable method), a `nil` handler, or a malformed pattern (see the
  ## module header for the syntax).
  if handler.isNil:
    raise newException(ValueError, "neel: route " & escape(pattern) & " has a nil handler")
  if methods == {}:
    raise newException(ValueError, "neel: route " & escape(pattern) & " lists no method")
  if hmOther in methods:
    raise newException(ValueError, "neel: route " & escape(pattern) &
      " lists hmOther, which stands for every method Neel does not route")
  result = Route(methods: methods, pattern: pattern,
                 segments: parsePattern(pattern), handler: handler)
  if hmGet in methods:
    result.methods.incl hmHead

proc get*(pattern: string; handler: RouteHandler): Route =
  ## `route({hmGet}, pattern, handler)`: `GET` and `HEAD`.
  route({hmGet}, pattern, handler)

proc post*(pattern: string; handler: RouteHandler): Route =
  ## `route({hmPost}, pattern, handler)`.
  route({hmPost}, pattern, handler)

proc put*(pattern: string; handler: RouteHandler): Route =
  ## `route({hmPut}, pattern, handler)`.
  route({hmPut}, pattern, handler)

proc patch*(pattern: string; handler: RouteHandler): Route =
  ## `route({hmPatch}, pattern, handler)`.
  route({hmPatch}, pattern, handler)

proc delete*(pattern: string; handler: RouteHandler): Route =
  ## `route({hmDelete}, pattern, handler)`.
  route({hmDelete}, pattern, handler)

proc pattern*(r: Route): string =
  ## The pattern `r` was built with.
  r.pattern

proc methods*(r: Route): set[HttpMethod] =
  ## The methods `r` answers: the ones it was built with, plus `hmHead`
  ## when they include `hmGet`.
  r.methods

proc handler*(r: Route): RouteHandler =
  ## The handler `r` was built with (`nil` for a default `Route()`).
  r.handler

# --- validation of a route list --------------------------------------------------

proc methodList(methods: set[HttpMethod]): string =
  ## `"GET, HEAD, POST"`: the `Allow` value for `methods`, in enum order.
  for m in methods:
    if result.len > 0:
      result.add ", "
    result.add $m

proc sameShape(a, b: Route): bool =
  ## Whether `a` and `b` match exactly the same paths: equal literals in
  ## equal places; parameter names do not matter.
  if a.segments.len != b.segments.len:
    return false
  for i in 0 ..< a.segments.len:
    if a.segments[i].kind != b.segments[i].kind:
      return false
    if a.segments[i].kind == skLiteral and a.segments[i].text != b.segments[i].text:
      return false
  true

proc literalPath(r: Route): string =
  ## The one path `r` matches when it has no parameters, else `""`.
  for s in r.segments:
    if s.kind != skLiteral:
      return ""
    result.add "/" & s.text

proc checkRoutes*(routes: openArray[Route]; reserved: openArray[string]) =
  ## Raises `ValueError` when the list cannot work as written: an entry that
  ## was not built with `route` / `get` / ... (a default `Route()`), a route
  ## for one of the `reserved` paths (Neel answers those itself), or a route
  ## an earlier one shadows completely (same shape and every one of its
  ## methods already taken, so it could never run).
  for i in 0 ..< routes.len:
    if routes[i].handler.isNil:
      raise newException(ValueError, "neel: routes[" & $i & "] is empty; build " &
        "routes with get, post, put, patch, delete, or route")
    let fixed = literalPath(routes[i])
    if fixed.len > 0 and fixed in reserved:
      raise newException(ValueError, "neel: route " & escape(routes[i].pattern) &
        " is reserved: Neel serves " & fixed & " itself")
    for j in 0 ..< i:
      if sameShape(routes[j], routes[i]) and routes[i].methods <= routes[j].methods:
        raise newException(ValueError, "neel: route " &
          methodList(routes[i].methods) & " " & escape(routes[i].pattern) &
          " can never run: " & escape(routes[j].pattern) &
          " comes before it and matches the same requests")

# --- matching --------------------------------------------------------------------

proc requestSegments(rawPath: string; segs: var seq[string]): bool =
  ## Splits a raw request path into percent-decoded segments. `false` when
  ## no route may match it: no leading `/`, a `.` or `..` segment, or a
  ## decoded segment holding `/`, a backslash, or NUL.
  if rawPath.len == 0 or rawPath[0] != '/':
    return false
  for raw in rawPath[1 .. ^1].split('/'):
    let seg = decodeUrl(raw, decodePlus = false)
    if seg == "." or seg == ".." or '/' in seg or '\\' in seg or '\0' in seg:
      return false
    segs.add seg
  true

proc matches(r: Route; segs: seq[string];
             params: var seq[tuple[name, value: string]]): bool =
  params.setLen 0
  var i = 0
  for s in r.segments:
    case s.kind
    of skTail:
      var rest = ""
      for k in i ..< segs.len:
        if k > i:
          rest.add '/'
        rest.add segs[k]
      params.add((s.text, rest))
      return true
    of skLiteral:
      if i >= segs.len or segs[i] != s.text:
        return false
    of skParam:
      if i >= segs.len or segs[i].len == 0:
        return false
      params.add((s.text, segs[i]))
    inc i
  i == segs.len

proc findRoute*(routes: openArray[Route]; httpMethod: HttpMethod;
                rawPath: string): RouteMatch {.gcsafe.} =
  ## The route for a request, by list order: see the module header. Pure.
  if routes.len == 0:
    return
  var segs: seq[string]
  if not requestSegments(rawPath, segs):
    return
  var allowed: set[HttpMethod]
  var params: seq[tuple[name, value: string]]
  for i in 0 ..< routes.len:
    if routes[i].matches(segs, params):
      if httpMethod in routes[i].methods:
        return RouteMatch(kind: rmFound, index: i, params: params)
      allowed = allowed + routes[i].methods
  if allowed != {}:
    result = RouteMatch(kind: rmMethodNotAllowed, allow: methodList(allowed))

# --- helpers for handlers --------------------------------------------------------

proc param*(req: HttpRequest; name: string): string =
  ## The path parameter `name` captured by the route's pattern (`@name` or
  ## `*name`; a bare `*` is named `"*"`), percent-decoded, or `""` when the
  ## pattern has no such parameter.
  for (k, v) in req.params:
    if k == name:
      return v
  ""

proc queryParam*(req: HttpRequest; name: string): string =
  ## The first `name=value` of the query string, decoded (`+` is a space),
  ## or `""` when absent or when the query string is malformed.
  try:
    for (k, v) in decodeQuery(req.query):
      if k == name:
        return v
  except UriParseError:
    discard
  ""

proc htmlResponse*(body: string; status = 200): HttpResponse =
  ## `body` as `text/html; charset=utf-8`.
  initResponse(status, body, HtmlType)

proc textResponse*(body: string; status = 200): HttpResponse =
  ## `body` as `text/plain; charset=utf-8`.
  initResponse(status, body, TextType)

proc jsonResponse*(node: JsonNode; status = 200): HttpResponse =
  ## `node` serialized as `application/json` (`null` for a `nil` node).
  initResponse(status, (if node.isNil: "null" else: $node), JsonType)

proc redirectResponse*(location: string; status = 302): HttpResponse =
  ## A redirect to `location` with an empty body. Use 303 to turn a `POST`
  ## into a `GET` of the target, 307 / 308 to keep the method.
  result = initResponse(status)
  result.addHeader("Location", location)

proc finishRouteResponse*(r: var HttpResponse): string =
  ## Prepares a handler's result for the wire. A status of `0` (a default
  ## `HttpResponse()`) becomes 200. Returns why the response cannot be sent,
  ## or `""`: a status outside 200..599 (1xx would break the connection's
  ## framing), an empty or non-token header name, or a header value with
  ## CR, LF, or NUL (which would let the value inject headers of its own).
  if r.status == 0:
    r.status = 200
  if r.status notin 200 .. 599:
    return "status " & $r.status & " is outside 200..599"
  for h in r.headers:
    if h.name.len == 0 or not h.name.allCharsInSet(HeaderNameChars):
      return "invalid header name " & escape(h.name)
    if h.value.contains({'\r', '\n', '\0'}):
      return "header " & h.name & " has a line break or NUL in its value"
  ""
