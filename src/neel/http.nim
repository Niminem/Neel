## http.nim - HTTP/1.1 request parsing and response writing. No socket IO here.
##
## Pure byte-level logic so it can be unit tested with split reads and
## pipelined input. `server.nim` owns a growing receive buffer per connection,
## hands it to `parseRequest` after every read, drops `consumed` bytes on a
## complete request, and sends whatever `encodeResponse` returns.
##
## Surface:
## - `HttpParser` + `parseRequest`: incremental parser (request line, headers,
##   body skipped via `Content-Length`). Reports `psIncomplete`, `psComplete`
##   with the number of bytes consumed (so pipelined requests work), or
##   `psMalformed`. The scan position is kept between calls so a growing
##   buffer is never re-scanned from the start.
## - `HttpRequest`: method, raw method token, path and query (split from the
##   target), version, headers with case-insensitive lookup, and the keep-alive
##   decision. Enough for the WebSocket upgrade check without re-parsing.
## - `HttpResponse` + `encodeResponse`: status line, headers, automatic
##   `Content-Length` and `Connection`, HEAD support (same headers, no body).
##   Status helpers for 200, 400, 404, 405 (`Allow: GET, HEAD`), 206, and 416.
## - `parseRange`: single byte range (`bytes=a-b`, `bytes=a-`, `bytes=-n`).
##   Multi-range and malformed headers are ignored (serve 200).
## - `contentTypeFor`: MIME lookup through `std/mimetypes` with overrides for
##   `.js`/`.mjs` (`application/javascript`) and `.map` (`application/json`),
##   falling back to `application/octet-stream`.

import std/[strutils, mimetypes]

const
  MaxHeaderBlock* = 16 * 1024
    ## Maximum size in bytes of the request line plus headers, including the
    ## terminating empty line. Larger header blocks are malformed.
  MaxRequestBody* = 1024 * 1024
    ## Maximum `Content-Length` the parser is willing to skip. Neel only
    ## serves `GET`/`HEAD`, so bodies are never used; this bound keeps a
    ## client from making the server buffer an unbounded body before it can
    ## answer 405. Larger values are malformed.
  OctetStream* = "application/octet-stream"
    ## MIME type returned for unknown extensions.

type
  HttpMethod* = enum
    ## Request method. Anything other than `GET`/`HEAD` is `hmOther`; the
    ## original token is kept in `HttpRequest.rawMethod` and the server answers
    ## 405.
    hmGet = "GET"
    hmHead = "HEAD"
    hmOther = "OTHER"

  HttpVersion* = enum
    ## Protocol version of a request. Anything else is malformed.
    hv10 = "HTTP/1.0"
    hv11 = "HTTP/1.1"

  HttpHeader* = tuple[name, value: string]
    ## One header field. `name` is as sent (compare case-insensitively),
    ## `value` has leading and trailing SP/HTAB removed.

  HttpRequest* = object
    ## A fully parsed request head. The body (if any) has been skipped.
    httpMethod*: HttpMethod
    rawMethod*: string      ## Method token as sent, e.g. `"POST"`.
    target*: string         ## Request target as sent, e.g. `"/a?b=1"`.
    path*: string           ## `target` up to the first `?` (not percent-decoded).
    query*: string          ## Part of `target` after the first `?`, or `""`.
    version*: HttpVersion
    headers*: seq[HttpHeader]
    contentLength*: int     ## Declared body length, 0 when absent.

  ParseStatus* = enum
    psIncomplete  ## More bytes are needed; keep the buffer and call again.
    psComplete    ## `request` is valid and `consumed` bytes can be dropped.
    psMalformed   ## Answer 400 and close; `error` says why.

  ParseResult* = object
    status*: ParseStatus
    consumed*: int      ## Bytes of the buffer that made up the request (psComplete).
    error*: string      ## Human-readable reason (psMalformed).
    request*: HttpRequest

  HttpParser* = object
    ## Incremental state for one connection. Between `psIncomplete` results
    ## the caller must only append to the buffer; after `psComplete` or
    ## `psMalformed` the parser has reset itself and the caller drops
    ## `consumed` bytes (or closes the connection).
    start: int          # offset of the request line after skipped empty lines
    scanPos: int        # next index to inspect for the CRLFCRLF terminator
    headerEnd: int      # 0 until the header block has been parsed
    request: HttpRequest

  HttpResponse* = object
    ## A response ready for `encodeResponse`. `Content-Length` and
    ## `Connection` are added automatically unless already present.
    status*: int
    headers*: seq[HttpHeader]
    body*: string

  ByteRange* = object
    ## Inclusive byte range `[first, last]` within a representation.
    first*, last*: int

  RangeStatus* = enum
    rsIgnored        ## No usable single range: serve the whole body with 200.
    rsSatisfiable    ## Serve `range` with 206.
    rsUnsatisfiable  ## Answer 416.

  RangeResult* = object
    status*: RangeStatus
    range*: ByteRange  ## Valid when `status == rsSatisfiable`.

const
  TokenChars = {'a'..'z', 'A'..'Z', '0'..'9', '!', '#', '$', '%', '&', '\'',
                '*', '+', '-', '.', '^', '_', '`', '|', '~'}
    # RFC 7230 section 3.2.6 `tchar`.
  Crlf = "\r\n"

# --- request: header access ----------------------------------------------

proc getHeader*(req: HttpRequest; name: string): string =
  ## Value of the first header named `name` (case-insensitive), or `""`.
  for h in req.headers:
    if cmpIgnoreCase(h.name, name) == 0:
      return h.value
  ""

proc hasHeader*(req: HttpRequest; name: string): bool =
  ## Whether at least one header named `name` (case-insensitive) is present.
  for h in req.headers:
    if cmpIgnoreCase(h.name, name) == 0:
      return true
  false

proc headerHasToken*(req: HttpRequest; name, token: string): bool =
  ## Whether any header named `name` lists `token` in its comma-separated
  ## value (both compared case-insensitively). Use this for list-valued
  ## headers such as `Connection: keep-alive, Upgrade`.
  for h in req.headers:
    if cmpIgnoreCase(h.name, name) == 0:
      for part in h.value.split(','):
        if cmpIgnoreCase(part.strip(chars = {' ', '\t'}), token) == 0:
          return true
  false

proc keepAlive*(req: HttpRequest): bool =
  ## Whether the connection should stay open after the response. HTTP/1.1
  ## defaults to keep-alive unless `Connection: close` is sent; HTTP/1.0
  ## defaults to close unless `Connection: keep-alive` is sent.
  case req.version
  of hv11: not req.headerHasToken("Connection", "close")
  of hv10: req.headerHasToken("Connection", "keep-alive")

# --- request: incremental parser -----------------------------------------

proc reset*(p: var HttpParser) =
  ## Forgets all state. Call after discarding a connection's buffer.
  p = HttpParser()

proc isToken(s: string): bool =
  s.len > 0 and s.allCharsInSet(TokenChars)

proc isDigits(s: string): bool =
  s.len > 0 and s.allCharsInSet(Digits)

proc sliceToString(buf: openArray[char]; a, b: int): string =
  ## `buf[a ..< b]` as a string.
  result = newString(b - a)
  for i in 0 ..< result.len:
    result[i] = buf[a + i]

proc parseRequestLine(line: string; req: var HttpRequest): string =
  ## Fills method, target, path, query, and version. Returns an error or `""`.
  let parts = line.split(' ')
  if parts.len != 3:
    return "malformed request line"
  if not isToken(parts[0]):
    return "invalid method token"
  if parts[1].len == 0:
    return "empty request target"
  for c in parts[1]:
    if c <= ' ' or c == '\x7F':
      return "invalid character in request target"
  case parts[2]
  of "HTTP/1.1": req.version = hv11
  of "HTTP/1.0": req.version = hv10
  else: return "unsupported HTTP version"
  req.rawMethod = parts[0]
  req.httpMethod =
    case parts[0]
    of "GET": hmGet
    of "HEAD": hmHead
    else: hmOther
  req.target = parts[1]
  let q = parts[1].find('?')
  if q >= 0:
    req.path = parts[1][0 ..< q]
    req.query = parts[1][q + 1 .. ^1]
  else:
    req.path = parts[1]
    req.query = ""
  ""

proc parseHeaderLine(line: string; req: var HttpRequest): string =
  ## Appends one header. Returns an error or `""`.
  if line.len == 0:
    return "empty header line"
  if line[0] in {' ', '\t'}:
    return "obsolete header line folding is not supported"
  let colon = line.find(':')
  if colon <= 0:
    return "header line without a name/colon"
  let name = line[0 ..< colon]
  if not isToken(name):
    return "invalid header name"
  req.headers.add((name, line[colon + 1 .. ^1].strip(chars = {' ', '\t'})))
  ""

proc checkBodyFraming(req: var HttpRequest): string =
  ## Validates `Content-Length` (digits, consistent if repeated, bounded) and
  ## rejects `Transfer-Encoding`, which Neel does not frame.
  var length = -1
  for h in req.headers:
    if cmpIgnoreCase(h.name, "Content-Length") == 0:
      if not isDigits(h.value) or h.value.len > 18:
        return "invalid Content-Length"
      let v = parseInt(h.value)
      if length >= 0 and v != length:
        return "conflicting Content-Length headers"
      length = v
    elif cmpIgnoreCase(h.name, "Transfer-Encoding") == 0:
      return "Transfer-Encoding is not supported"
  if length > MaxRequestBody:
    return "request body too large"
  req.contentLength = max(length, 0)
  ""

proc parseHeaderBlock(buf: openArray[char]; start, stop: int;
                      req: var HttpRequest): string =
  ## Parses the lines in `buf[start ..< stop + 2]`, where `stop` indexes the
  ## first byte of the terminating CRLFCRLF (so every line, including the
  ## last, ends in CRLF). Returns an error or `""`.
  req = HttpRequest()
  var lineStart = start
  var first = true
  while lineStart < stop + 2:
    var j = lineStart
    while not (buf[j] == '\r' and buf[j + 1] == '\n'):
      inc j
    let line = sliceToString(buf, lineStart, j)
    if '\r' in line or '\n' in line:
      return "bare CR or LF in header block"
    let err =
      if first: parseRequestLine(line, req)
      else: parseHeaderLine(line, req)
    if err.len > 0:
      return err
    first = false
    lineStart = j + 2
  checkBodyFraming(req)

proc malformed(p: var HttpParser; why: string): ParseResult =
  p.reset()
  ParseResult(status: psMalformed, error: why)

proc parseRequest*(p: var HttpParser; buf: openArray[char]): ParseResult =
  ## Parses the request at the start of `buf`. Returns `psIncomplete` when
  ## more bytes are needed (append to `buf` and call again), `psComplete`
  ## with `consumed` set to the request's length in bytes (including any
  ## skipped body), or `psMalformed`. Empty lines before the request line are
  ## ignored (RFC 7230 section 3.5). The header block is limited to
  ## `MaxHeaderBlock` bytes and the body to `MaxRequestBody`.
  if p.headerEnd == 0:
    while p.start + 1 < buf.len and buf[p.start] == '\r' and buf[p.start + 1] == '\n':
      p.start += 2
    if p.scanPos < p.start:
      p.scanPos = p.start
    var found = -1
    var i = p.scanPos
    while i + 3 < buf.len:
      if buf[i] == '\r' and buf[i + 1] == '\n' and
         buf[i + 2] == '\r' and buf[i + 3] == '\n':
        found = i
        break
      inc i
    if found < 0:
      if buf.len - p.start >= MaxHeaderBlock:
        return p.malformed("header block exceeds " & $MaxHeaderBlock & " bytes")
      p.scanPos = max(p.start, buf.len - 3)
      return ParseResult(status: psIncomplete)
    let headerEnd = found + 4
    if headerEnd - p.start > MaxHeaderBlock:
      return p.malformed("header block exceeds " & $MaxHeaderBlock & " bytes")
    let err = parseHeaderBlock(buf, p.start, found, p.request)
    if err.len > 0:
      return p.malformed(err)
    p.headerEnd = headerEnd
  let total = p.headerEnd + p.request.contentLength
  if buf.len < total:
    return ParseResult(status: psIncomplete)
  result = ParseResult(status: psComplete, consumed: total, request: p.request)
  p.reset()

# --- range -----------------------------------------------------------------

proc parseClamped(s: string): int =
  ## Parses a digit string, saturating well below `int.high` so that range
  ## arithmetic cannot overflow.
  const limit = int.high div 16
  for c in s:
    if result > limit:
      return limit
    # result <= int.high div 16, so result * 10 + 9 cannot overflow.
    result = result * 10 + (ord(c) - ord('0'))

proc len*(r: ByteRange): int =
  ## Number of bytes covered by `r`.
  r.last - r.first + 1

proc parseRange*(header: string; totalLen: int): RangeResult =
  ## Interprets a `Range` header value against a representation of
  ## `totalLen` bytes (RFC 7233). Only a single `bytes=` range is honored:
  ## `a-b` (end clamped to the last byte), `a-` (to the end), `-n` (last `n`
  ## bytes, the whole body if `n >= totalLen`). A start at or past the end
  ## or a zero-length suffix is `rsUnsatisfiable`. Other units, multiple
  ## ranges, `a > b`, and syntax errors are `rsIgnored`.
  result = RangeResult(status: rsIgnored)
  let h = header.strip(chars = {' ', '\t'})
  if h.len <= 6 or cmpIgnoreCase(h[0 ..< 6], "bytes=") != 0:
    return
  let spec = h[6 .. ^1].strip(chars = {' ', '\t'})
  if spec.len == 0 or ',' in spec:
    return
  let dash = spec.find('-')
  if dash < 0:
    return
  let a = spec[0 ..< dash].strip(chars = {' ', '\t'})
  let b = spec[dash + 1 .. ^1].strip(chars = {' ', '\t'})
  if a.len == 0 and b.len == 0:
    return
  if (a.len > 0 and not isDigits(a)) or (b.len > 0 and not isDigits(b)):
    return
  if totalLen <= 0:
    return RangeResult(status: rsUnsatisfiable)
  if a.len == 0:
    let n = parseClamped(b)
    if n == 0:
      return RangeResult(status: rsUnsatisfiable)
    return RangeResult(status: rsSatisfiable,
                       range: ByteRange(first: max(0, totalLen - n),
                                        last: totalLen - 1))
  let first = parseClamped(a)
  if first >= totalLen:
    return RangeResult(status: rsUnsatisfiable)
  var last = totalLen - 1
  if b.len > 0:
    let e = parseClamped(b)
    if e < first:
      return
    last = min(e, totalLen - 1)
  result = RangeResult(status: rsSatisfiable,
                       range: ByteRange(first: first, last: last))

proc contentRange*(r: ByteRange; totalLen: int): string =
  ## `Content-Range` value for a 206 response: `bytes first-last/total`.
  "bytes " & $r.first & "-" & $r.last & "/" & $totalLen

proc contentRangeUnsatisfied*(totalLen: int): string =
  ## `Content-Range` value for a 416 response: `bytes */total`.
  "bytes */" & $totalLen

# --- response ----------------------------------------------------------------

proc reasonPhrase*(status: int): string =
  ## Standard reason phrase for `status`; a generic class phrase otherwise.
  case status
  of 101: "Switching Protocols"
  of 200: "OK"
  of 204: "No Content"
  of 206: "Partial Content"
  of 304: "Not Modified"
  of 400: "Bad Request"
  of 403: "Forbidden"
  of 404: "Not Found"
  of 405: "Method Not Allowed"
  of 413: "Payload Too Large"
  of 416: "Range Not Satisfiable"
  of 500: "Internal Server Error"
  of 501: "Not Implemented"
  else:
    case status div 100
    of 1: "Informational"
    of 2: "Success"
    of 3: "Redirection"
    of 4: "Client Error"
    else: "Server Error"

proc getHeader*(r: HttpResponse; name: string): string =
  ## Value of the first header named `name` (case-insensitive), or `""`.
  for h in r.headers:
    if cmpIgnoreCase(h.name, name) == 0:
      return h.value
  ""

proc hasHeader*(r: HttpResponse; name: string): bool =
  ## Whether `r` carries a header named `name` (case-insensitive).
  for h in r.headers:
    if cmpIgnoreCase(h.name, name) == 0:
      return true
  false

proc addHeader*(r: var HttpResponse; name, value: string) =
  ## Appends a header, keeping any existing header of the same name.
  r.headers.add((name, value))

proc setHeader*(r: var HttpResponse; name, value: string) =
  ## Replaces every header named `name` (case-insensitive) with one entry.
  var i = 0
  while i < r.headers.len:
    if cmpIgnoreCase(r.headers[i].name, name) == 0:
      r.headers.delete(i)
    else:
      inc i
  r.headers.add((name, value))

proc initResponse*(status: int; body = ""; contentType = ""): HttpResponse =
  ## A response with `status` and `body`; `Content-Type` is added when
  ## `contentType` is not empty.
  result = HttpResponse(status: status, body: body)
  if contentType.len > 0:
    result.headers.add(("Content-Type", contentType))

proc encodeResponse*(r: HttpResponse; keepAlive: bool; headOnly = false): string =
  ## Serializes `r` as `HTTP/1.1`: status line, `r.headers`, then
  ## `Content-Length: <body length>` (unless already present or the status
  ## forbids a body: 1xx, 204, 304) and `Connection: keep-alive|close`
  ## (unless already present). `headOnly` (for `HEAD`) omits the body but
  ## keeps every header, including `Content-Length`.
  result = "HTTP/1.1 " & $r.status & " " & reasonPhrase(r.status) & Crlf
  for h in r.headers:
    result.add h.name & ": " & h.value & Crlf
  let bodyless = r.status div 100 == 1 or r.status == 204 or r.status == 304
  if not bodyless and not r.hasHeader("Content-Length"):
    result.add "Content-Length: " & $r.body.len & Crlf
  if not r.hasHeader("Connection"):
    result.add "Connection: " & (if keepAlive: "keep-alive" else: "close") & Crlf
  result.add Crlf
  if not headOnly and not bodyless:
    result.add r.body

proc okResponse*(body: string; contentType: string): HttpResponse =
  ## 200 with `body` and `Content-Type: contentType`.
  initResponse(200, body, contentType)

proc badRequest*(): HttpResponse =
  ## 400 with a plain-text body. Send with `keepAlive = false`.
  initResponse(400, "400 Bad Request", "text/plain")

proc notFound*(): HttpResponse =
  ## 404 with a plain-text body.
  initResponse(404, "404 Not Found", "text/plain")

proc methodNotAllowed*(): HttpResponse =
  ## 405 with `Allow: GET, HEAD` and a plain-text body.
  result = initResponse(405, "405 Method Not Allowed", "text/plain")
  result.headers.add(("Allow", "GET, HEAD"))

proc partialContent*(slice: string; contentType: string; r: ByteRange;
                     totalLen: int): HttpResponse =
  ## 206 carrying `slice`, which must already be the bytes `r` selects out of
  ## a `totalLen`-byte representation. Adds `Content-Range` and
  ## `Accept-Ranges: bytes`.
  result = initResponse(206, slice, contentType)
  result.headers.add(("Content-Range", contentRange(r, totalLen)))
  result.headers.add(("Accept-Ranges", "bytes"))

proc rangeNotSatisfiable*(totalLen: int): HttpResponse =
  ## 416 with `Content-Range: bytes */totalLen` and `Accept-Ranges: bytes`.
  result = initResponse(416, "416 Range Not Satisfiable", "text/plain")
  result.headers.add(("Content-Range", contentRangeUnsatisfied(totalLen)))
  result.headers.add(("Accept-Ranges", "bytes"))

# --- MIME ------------------------------------------------------------------

const mimeDb = block:
  # Built at compile time so lookups touch no GC'd global and are gcsafe.
  var db = newMimetypes()
  # std/mimetypes maps .js/.mjs to text/javascript and has no .map entry.
  db.register("js", "application/javascript")
  db.register("mjs", "application/javascript")
  db.register("map", "application/json")
  db

proc contentTypeFor*(path: string): string =
  ## MIME type for `path` from its extension (case-insensitive), or
  ## `OctetStream` when the extension is missing or unknown.
  let dot = path.rfind('.')
  let slash = max(path.rfind('/'), path.rfind('\\'))
  if dot < 0 or dot < slash or dot == path.high:
    return OctetStream
  mimeDb.getMimetype(path[dot + 1 .. ^1], OctetStream)
