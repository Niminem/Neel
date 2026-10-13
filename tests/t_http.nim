## t_http.nim - request parsing (split reads, pipelining, malformed input),
## keep-alive decisions, response formatting, range arithmetic, MIME lookup.

import std/[unittest, strutils]
import neel/http

const
  SimpleGet = "GET /index.html?x=1&y=2 HTTP/1.1\r\nHost: localhost\r\n" &
              "User-Agent:  \tFoo \t\r\n\r\n"

proc parseAll(data: string): ParseResult =
  ## Parses `data` in one shot with a fresh parser.
  var p: HttpParser
  p.parseRequest(data)

proc malformedReason(data: string): string =
  let r = parseAll(data)
  if r.status != psMalformed: "<status " & $r.status & ">" else: r.error

suite "http parser":
  test "complete request in one buffer":
    let r = parseAll(SimpleGet)
    check r.status == psComplete
    check r.consumed == SimpleGet.len
    let req = r.request
    check req.httpMethod == hmGet
    check req.rawMethod == "GET"
    check req.version == hv11
    check req.target == "/index.html?x=1&y=2"
    check req.path == "/index.html"
    check req.query == "x=1&y=2"
    check req.headers.len == 2
    check req.contentLength == 0

  test "header names are case-insensitive and values are trimmed":
    let req = parseAll(SimpleGet).request
    check req.getHeader("host") == "localhost"
    check req.getHeader("HOST") == "localhost"
    check req.getHeader("USER-AGENT") == "Foo"
    check req.headers[1].name == "User-Agent"
    check req.hasHeader("user-agent")
    check not req.hasHeader("Range")
    check req.getHeader("Range") == ""

  test "path without query":
    let req = parseAll("GET /a/b.css HTTP/1.1\r\n\r\n").request
    check req.path == "/a/b.css"
    check req.query == ""
    check req.headers.len == 0

  test "delivered one byte at a time":
    var p: HttpParser
    var buf = ""
    for i in 0 ..< SimpleGet.len - 1:
      buf.add SimpleGet[i]
      let r = p.parseRequest(buf)
      check r.status == psIncomplete
    buf.add SimpleGet[^1]
    let r = p.parseRequest(buf)
    check r.status == psComplete
    check r.consumed == SimpleGet.len
    check r.request.getHeader("User-Agent") == "Foo"
    check r.request.query == "x=1&y=2"

  test "split mid-header and inside the terminator":
    var p: HttpParser
    let cut = SimpleGet.find("Host: loc") + 9
    var buf = SimpleGet[0 ..< cut]
    check p.parseRequest(buf).status == psIncomplete
    buf = SimpleGet[0 ..< SimpleGet.len - 1]  # ends in "\r\n\r"
    check p.parseRequest(buf).status == psIncomplete
    buf = SimpleGet
    let r = p.parseRequest(buf)
    check r.status == psComplete
    check r.consumed == SimpleGet.len
    check r.request.getHeader("Host") == "localhost"

  test "two pipelined requests in one buffer":
    let second = "HEAD /b HTTP/1.1\r\nHost: x\r\n\r\n"
    var buf = SimpleGet & second
    var p: HttpParser
    let r1 = p.parseRequest(buf)
    check r1.status == psComplete
    check r1.consumed == SimpleGet.len
    check r1.request.path == "/index.html"
    buf.delete(0 ..< r1.consumed)
    let r2 = p.parseRequest(buf)
    check r2.status == psComplete
    check r2.consumed == second.len
    check r2.request.httpMethod == hmHead
    check r2.request.path == "/b"
    buf.delete(0 ..< r2.consumed)
    check buf.len == 0
    check p.parseRequest(buf).status == psIncomplete

  test "body is skipped via Content-Length and pipelining continues":
    let first = "POST /a HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello"
    let second = "GET /b HTTP/1.1\r\n\r\n"
    var buf = first & second
    var p: HttpParser
    let r1 = p.parseRequest(buf)
    check r1.status == psComplete
    check r1.consumed == first.len
    check r1.request.httpMethod == hmOther
    check r1.request.contentLength == 5
    buf.delete(0 ..< r1.consumed)
    let r2 = p.parseRequest(buf)
    check r2.status == psComplete
    check r2.request.path == "/b"

  test "incomplete body waits without re-parsing headers":
    var p: HttpParser
    var buf = "POST /a HTTP/1.1\r\nContent-Length: 5\r\n\r\nhel"
    check p.parseRequest(buf).status == psIncomplete
    buf.add "lo"
    let r = p.parseRequest(buf)
    check r.status == psComplete
    check r.consumed == buf.len

  test "Content-Length: 0 is accepted":
    let r = parseAll("GET / HTTP/1.1\r\nContent-Length: 0\r\n\r\n")
    check r.status == psComplete
    check r.request.contentLength == 0

  test "HEAD":
    let req = parseAll("HEAD /x HTTP/1.1\r\n\r\n").request
    check req.httpMethod == hmHead
    check req.rawMethod == "HEAD"

  test "POST parses as hmOther so the server can answer 405":
    let r = parseAll("POST /x HTTP/1.1\r\n\r\n")
    check r.status == psComplete
    check r.request.httpMethod == hmOther
    check r.request.rawMethod == "POST"
    check encodeResponse(methodNotAllowed(), true).contains("Allow: GET, HEAD\r\n")

  test "empty lines before the request line are ignored":
    let data = "\r\n\r\nGET / HTTP/1.1\r\n\r\n"
    let r = parseAll(data)
    check r.status == psComplete
    check r.consumed == data.len
    check r.request.path == "/"

  test "parser is reusable after a complete request":
    var p: HttpParser
    check p.parseRequest(SimpleGet).status == psComplete
    check p.parseRequest("GET /two HTTP/1.0\r\n\r\n").request.path == "/two"

  test "malformed: bad request line":
    check malformedReason("GET\r\n\r\n") == "malformed request line"
    check malformedReason("GET / HTTP/1.1 extra\r\n\r\n") == "malformed request line"
    check malformedReason("G<T / HTTP/1.1\r\n\r\n") == "invalid method token"
    check malformedReason("GET  / HTTP/1.1\r\n\r\n") == "malformed request line"

  test "malformed: missing or unsupported HTTP version":
    check malformedReason("GET /\r\n\r\n") == "malformed request line"
    check malformedReason("GET / HTTP/2.0\r\n\r\n") == "unsupported HTTP version"
    check malformedReason("GET / http/1.1\r\n\r\n") == "unsupported HTTP version"

  test "malformed: header without colon":
    check malformedReason("GET / HTTP/1.1\r\nHost localhost\r\n\r\n") ==
      "header line without a name/colon"
    check malformedReason("GET / HTTP/1.1\r\n: value\r\n\r\n") ==
      "header line without a name/colon"

  test "malformed: whitespace before the colon and obsolete folding":
    check malformedReason("GET / HTTP/1.1\r\nHost : localhost\r\n\r\n") ==
      "invalid header name"
    check malformedReason("GET / HTTP/1.1\r\nHost: a\r\n b\r\n\r\n") ==
      "obsolete header line folding is not supported"

  test "malformed: non-numeric Content-Length":
    check malformedReason("GET / HTTP/1.1\r\nContent-Length: abc\r\n\r\n") ==
      "invalid Content-Length"
    check malformedReason("GET / HTTP/1.1\r\nContent-Length: -1\r\n\r\n") ==
      "invalid Content-Length"
    check malformedReason("GET / HTTP/1.1\r\nContent-Length:\r\n\r\n") ==
      "invalid Content-Length"
    check malformedReason("GET / HTTP/1.1\r\nContent-Length: 1\r\n" &
                          "Content-Length: 2\r\n\r\n") ==
      "conflicting Content-Length headers"
    check malformedReason("GET / HTTP/1.1\r\nContent-Length: " &
                          $(MaxRequestBody + 1) & "\r\n\r\n") ==
      "request body too large"

  test "malformed: Transfer-Encoding is rejected":
    check malformedReason("GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") ==
      "Transfer-Encoding is not supported"

  test "malformed: bare LF inside the header block":
    check malformedReason("GET / HTTP/1.1\r\nA: b\nC: d\r\n\r\n") ==
      "bare CR or LF in header block"

  test "malformed: header block exceeding 16 KiB":
    let prefix = "GET / HTTP/1.1\r\nX-Big: "
    # Terminated block exactly at the limit is accepted.
    let fits = prefix & repeat('a', MaxHeaderBlock - prefix.len - 4) & "\r\n\r\n"
    check fits.len == MaxHeaderBlock
    check parseAll(fits).status == psComplete
    # One byte over, terminated: malformed.
    let over = prefix & repeat('a', MaxHeaderBlock - prefix.len - 3) & "\r\n\r\n"
    check over.len == MaxHeaderBlock + 1
    check parseAll(over).status == psMalformed
    # Unterminated and already at the limit: malformed without waiting.
    let unterminated = prefix & repeat('a', MaxHeaderBlock - prefix.len)
    check parseAll(unterminated).status == psMalformed
    check parseAll(unterminated).error.contains("exceeds")

  test "unterminated headers under the limit need more data":
    var p: HttpParser
    check p.parseRequest("GET / HTTP/1.1\r\nHost: localhost\r\n").status == psIncomplete
    check p.parseRequest("GET / HTTP/1.1\r\nHost: localhost").status == psIncomplete
    check p.parseRequest("GET / HTTP/1.1").status == psIncomplete
    check p.parseRequest("").status == psIncomplete

  test "malformed input resets the parser":
    var p: HttpParser
    check p.parseRequest("GET\r\n\r\n").status == psMalformed
    check p.parseRequest(SimpleGet).status == psComplete

suite "http keep-alive":
  test "HTTP/1.1 defaults to keep-alive":
    check parseAll("GET / HTTP/1.1\r\n\r\n").request.keepAlive

  test "HTTP/1.1 with Connection: close":
    check not parseAll("GET / HTTP/1.1\r\nConnection: close\r\n\r\n").request.keepAlive
    check not parseAll("GET / HTTP/1.1\r\nconnection: Close\r\n\r\n").request.keepAlive

  test "HTTP/1.0 defaults to close":
    check not parseAll("GET / HTTP/1.0\r\n\r\n").request.keepAlive

  test "HTTP/1.0 with Connection: keep-alive":
    check parseAll("GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n").request.keepAlive
    check parseAll("GET / HTTP/1.0\r\nConnection: Keep-Alive\r\n\r\n").request.keepAlive

  test "list-valued Connection header (upgrade shape)":
    let req = parseAll("GET /ws HTTP/1.1\r\nUpgrade: websocket\r\n" &
                       "Connection: keep-alive, Upgrade\r\n" &
                       "Sec-WebSocket-Key:  dGhlIHNhbXBsZSBub25jZQ== \r\n" &
                       "Sec-WebSocket-Version: 13\r\n\r\n").request
    check req.headerHasToken("Connection", "upgrade")
    check req.headerHasToken("connection", "Keep-Alive")
    check not req.headerHasToken("Connection", "close")
    check req.keepAlive
    check req.getHeader("Sec-WebSocket-Key") == "dGhlIHNhbXBsZSBub25jZQ=="
    check req.getHeader("Sec-WebSocket-Version") == "13"
    check req.getHeader("Upgrade") == "websocket"

suite "http response":
  test "200 with exact framing":
    check encodeResponse(okResponse("hello", "text/plain"), keepAlive = true) ==
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n" &
      "Connection: keep-alive\r\n\r\nhello"

  test "HEAD keeps the headers and drops the body":
    let full = encodeResponse(okResponse("hello", "text/plain"), true)
    let head = encodeResponse(okResponse("hello", "text/plain"), true, headOnly = true)
    check head.endsWith("\r\n\r\n")
    check head.contains("Content-Length: 5\r\n")
    check full == head & "hello"

  test "404 with Connection: close":
    check encodeResponse(notFound(), keepAlive = false) ==
      "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n" &
      "Connection: close\r\n\r\n404 Not Found"

  test "405 carries Allow: GET, HEAD":
    let s = encodeResponse(methodNotAllowed(), true)
    check s.startsWith("HTTP/1.1 405 Method Not Allowed\r\n")
    check s.contains("Allow: GET, HEAD\r\n")
    check s.contains("Content-Length: 22\r\n")
    check s.endsWith("\r\n\r\n405 Method Not Allowed")

  test "400":
    let s = encodeResponse(badRequest(), false)
    check s.startsWith("HTTP/1.1 400 Bad Request\r\n")
    check s.contains("Content-Length: 15\r\n")
    check s.contains("Connection: close\r\n")
    check s.endsWith("\r\n\r\n400 Bad Request")

  test "206 with Content-Range and Accept-Ranges":
    let r = ByteRange(first: 2, last: 4)
    let s = encodeResponse(partialContent("cde", "video/mp4", r, 10), true)
    check s.startsWith("HTTP/1.1 206 Partial Content\r\n")
    check s.contains("Content-Type: video/mp4\r\n")
    check s.contains("Content-Range: bytes 2-4/10\r\n")
    check s.contains("Accept-Ranges: bytes\r\n")
    check s.contains("Content-Length: 3\r\n")
    check s.endsWith("\r\n\r\ncde")
    check contentRange(ByteRange(first: 0, last: 999), 1000) == "bytes 0-999/1000"

  test "416 with Content-Range: bytes */len":
    let s = encodeResponse(rangeNotSatisfiable(10), true)
    check s.startsWith("HTTP/1.1 416 Range Not Satisfiable\r\n")
    check s.contains("Content-Range: bytes */10\r\n")
    check s.contains("Accept-Ranges: bytes\r\n")
    check s.contains("Content-Length: 25\r\n")
    check contentRangeUnsatisfied(0) == "bytes */0"

  test "explicit Content-Length and Connection headers are not duplicated":
    var r = initResponse(101)
    r.addHeader("Upgrade", "websocket")
    r.addHeader("Connection", "Upgrade")
    let s = encodeResponse(r, true)
    check s == "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" &
               "Connection: Upgrade\r\n\r\n"
    var h = initResponse(200, "", "application/octet-stream")
    h.setHeader("Content-Length", "1234")
    let hs = encodeResponse(h, true, headOnly = true)
    check hs.count("Content-Length") == 1
    check hs.contains("Content-Length: 1234\r\n")

  test "setHeader replaces, addHeader appends":
    var r = initResponse(200)
    r.addHeader("X-A", "1")
    r.addHeader("x-a", "2")
    check r.headers.len == 2
    r.setHeader("X-A", "3")
    check r.headers.len == 1
    check r.getHeader("x-a") == "3"
    check r.hasHeader("X-A")

  test "reason phrases":
    check reasonPhrase(200) == "OK"
    check reasonPhrase(206) == "Partial Content"
    check reasonPhrase(400) == "Bad Request"
    check reasonPhrase(404) == "Not Found"
    check reasonPhrase(405) == "Method Not Allowed"
    check reasonPhrase(416) == "Range Not Satisfiable"
    check reasonPhrase(499) == "Client Error"

suite "http range":
  test "a-b":
    let r = parseRange("bytes=0-99", 1000)
    check r.status == rsSatisfiable
    check r.range == ByteRange(first: 0, last: 99)
    check r.range.len == 100
    check parseRange("bytes=5-5", 10).range == ByteRange(first: 5, last: 5)

  test "a- (open end)":
    let r = parseRange("bytes=500-", 1000)
    check r.status == rsSatisfiable
    check r.range == ByteRange(first: 500, last: 999)

  test "-n (suffix)":
    let r = parseRange("bytes=-100", 1000)
    check r.status == rsSatisfiable
    check r.range == ByteRange(first: 900, last: 999)
    # Suffix longer than the body selects everything.
    check parseRange("bytes=-5000", 1000).range == ByteRange(first: 0, last: 999)
    check parseRange("bytes=-0", 1000).status == rsUnsatisfiable

  test "start at or past the end is unsatisfiable":
    check parseRange("bytes=1000-", 1000).status == rsUnsatisfiable
    check parseRange("bytes=1000-1005", 1000).status == rsUnsatisfiable
    check parseRange("bytes=5000-", 1000).status == rsUnsatisfiable
    check parseRange("bytes=0-", 0).status == rsUnsatisfiable
    check parseRange("bytes=-1", 0).status == rsUnsatisfiable

  test "end past the length is clamped":
    let r = parseRange("bytes=900-5000", 1000)
    check r.status == rsSatisfiable
    check r.range == ByteRange(first: 900, last: 999)
    check parseRange("bytes=0-99999999999999999999999", 10).range ==
      ByteRange(first: 0, last: 9)

  test "invalid and multi-range inputs are ignored":
    check parseRange("", 1000).status == rsIgnored
    check parseRange("bytes=", 1000).status == rsIgnored
    check parseRange("bytes=-", 1000).status == rsIgnored
    check parseRange("bytes=0-99,200-299", 1000).status == rsIgnored
    check parseRange("bytes=10-5", 1000).status == rsIgnored
    check parseRange("bytes=a-b", 1000).status == rsIgnored
    check parseRange("bytes=0-9x", 1000).status == rsIgnored
    check parseRange("bytes=0x-9", 1000).status == rsIgnored
    check parseRange("bytes=5", 1000).status == rsIgnored
    check parseRange("items=0-9", 1000).status == rsIgnored
    check parseRange("0-9", 1000).status == rsIgnored

  test "unit is case-insensitive and whitespace is tolerated":
    check parseRange("BYTES=0-9", 1000).range == ByteRange(first: 0, last: 9)
    check parseRange(" bytes= 0 - 9 ", 1000).range == ByteRange(first: 0, last: 9)

suite "http mime":
  test "javascript":
    check contentTypeFor("app.js") == "application/javascript"
    check contentTypeFor("/static/mod.mjs") == "application/javascript"
    check contentTypeFor("UPPER.JS") == "application/javascript"

  test "wasm":
    check contentTypeFor("lib.wasm") == "application/wasm"

  test "html and png":
    check contentTypeFor("/index.html") == "text/html"
    check contentTypeFor("img/logo.png") == "image/png"

  test "other web assets":
    check contentTypeFor("data.json") == "application/json"
    check contentTypeFor("app.js.map") == "application/json"
    check contentTypeFor("font.woff2") == "font/woff2"
    check contentTypeFor("pic.webp") == "image/webp"
    check contentTypeFor("icon.svg") == "image/svg+xml"
    check contentTypeFor("style.css") == "text/css"

  test "unknown or missing extension":
    check contentTypeFor("file.zzzunknown") == OctetStream
    check contentTypeFor("LICENSE") == OctetStream
    check contentTypeFor("dir.v2/file") == OctetStream
    check contentTypeFor("trailing.") == OctetStream
    check contentTypeFor("") == OctetStream
