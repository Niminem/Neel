## t_assets.nim - asset path resolution, disk and embedded serving, containment,
## Range handling, and byte-identical output across the two modes.
##
## The fixture web directory is `tests/fixtures/web/` (an index, a script, a
## stylesheet, a nested page, a nested file with spaces in its name, a file
## without extension, and a 256-byte binary holding every byte value for the
## Range tests). Requests are built through the real `http.nim` parser so
## path/query splitting matches production; no server is started.

import std/[unittest, os, strutils, options, algorithm, tables]
import neel/[assets, http]

const
  FixtureDir = currentSourcePath().parentDir / "fixtures" / "web"
  Embedded = embedWebDir("fixtures/web", currentSourcePath().parentDir)
    ## Compile-time walk of the same directory.

let disk = diskAssets(FixtureDir)
let embedded = embeddedAssets(Embedded)
let blob = readFile(FixtureDir / "media" / "blob.bin")

proc request(target: string; httpMethod = "GET"; headers: seq[(string, string)] = @[]): HttpRequest =
  ## Parses a one-request wire text into an `HttpRequest`.
  var text = httpMethod & " " & target & " HTTP/1.1\r\nHost: 127.0.0.1\r\n"
  for (k, v) in headers:
    text.add k & ": " & v & "\r\n"
  text.add "\r\n"
  var p: HttpParser
  let r = p.parseRequest(text)
  doAssert r.status == psComplete, "fixture request is malformed: " & r.error
  r.request

template bothModes(name: string; body: untyped) =
  ## Runs `body` once per mode with `src` bound to the source under test.
  test name & " (disk)":
    let src {.inject.} = disk
    body
  test name & " (embedded)":
    let src {.inject.} = embedded
    body

# --- path resolution -------------------------------------------------------------

suite "assets: resolveAssetPath":
  test "root and plain files":
    check resolveAssetPath("/") == some(IndexFile)
    check resolveAssetPath("/index.html") == some("index.html")
    check resolveAssetPath("/sub/page.html") == some("sub/page.html")
    check resolveAssetPath("/./index.html") == some("index.html")
    check resolveAssetPath("//index.html") == some("index.html")
    check resolveAssetPath("/sub//page.html") == some("sub/page.html")

  test "percent-decoding":
    check resolveAssetPath("/sub/data%20with%20space.json") ==
      some("sub/data with space.json")
    check resolveAssetPath("/%69ndex.html") == some("index.html")
    check resolveAssetPath("/a+b.txt") == some("a+b.txt")  # no form decoding
    check resolveAssetPath("/100%.html") == some("100%.html")  # bad escape kept

  test "escapes are refused":
    check resolveAssetPath("/../x").isNone
    check resolveAssetPath("/sub/../../x").isNone
    check resolveAssetPath("/%2e%2e/x").isNone
    check resolveAssetPath("/..%2fx").isNone
    check resolveAssetPath("/sub/%2E%2E/x").isNone
    check resolveAssetPath("/a\\b").isNone
    check resolveAssetPath("/%5c..%5cx").isNone
    check resolveAssetPath("/index.html%00.png").isNone
    check resolveAssetPath("relative").isNone
    check resolveAssetPath("").isNone

  test "directory requests yield none, the root is the only exception":
    check resolveAssetPath("/sub/").isNone
    check resolveAssetPath("/sub/./").isNone
    check resolveAssetPath("/./").get == IndexFile
    # `..` is refused even when it would stay inside the root.
    check resolveAssetPath("/sub/..").isNone

# --- serving ---------------------------------------------------------------------

suite "assets: serving":
  bothModes "/ serves index.html with Content-Type and Accept-Ranges":
    let r = src.serveAsset(request("/"))
    check r.status == 200
    check r.body == readFile(FixtureDir / "index.html")
    check r.getHeader("Content-Type") == "text/html"
    check r.getHeader("Accept-Ranges") == "bytes"
    check src.serveAsset(request("/index.html")).body == r.body
    check src.serveAsset(request("/?window=1")).body == r.body

  bothModes "script and stylesheet MIME types":
    check src.serveAsset(request("/app.js")).getHeader("Content-Type") ==
      "application/javascript"
    check src.serveAsset(request("/style.css")).getHeader("Content-Type") == "text/css"
    check src.serveAsset(request("/app.js")).body == readFile(FixtureDir / "app.js")

  bothModes "nested paths, including a percent-encoded name":
    let page = src.serveAsset(request("/sub/page.html"))
    check page.status == 200
    check page.body == readFile(FixtureDir / "sub" / "page.html")
    let data = src.serveAsset(request("/sub/data%20with%20space.json"))
    check data.status == 200
    check data.getHeader("Content-Type") == "application/json"
    check data.body == readFile(FixtureDir / "sub" / "data with space.json")
    check src.serveAsset(request("/%73ub/page.html")).status == 200

  bothModes "unknown extension and no extension are application/octet-stream":
    let r = src.serveAsset(request("/noext"))
    check r.status == 200
    check r.getHeader("Content-Type") == OctetStream
    check r.body == "no extension here"
    check src.serveAsset(request("/media/blob.bin")).getHeader("Content-Type") ==
      OctetStream

  bothModes "missing files are 404":
    check src.serveAsset(request("/missing.html")).status == 404
    check src.serveAsset(request("/sub/missing.js")).status == 404
    check src.serveAsset(request("/index.html/extra")).status == 404

  bothModes "escaping paths are 404":
    for target in ["/../neel.nimble", "/sub/../../neel.nimble",
                   "/%2e%2e/neel.nimble", "/..%2fneel.nimble",
                   "/sub/%2e%2e/%2e%2e/neel.nimble",
                   "/%5c..%5cneel.nimble", "/\\..\\neel.nimble",
                   "/sub\\..\\..\\neel.nimble",
                   "/index.html%00", "/index.html%00.png",
                   "//etc/passwd", "/%2fetc/passwd", "/etc/passwd",
                   "/" & FixtureDir / "index.html"]:
      checkpoint target
      check src.serveAsset(request(target)).status == 404

  bothModes "directory requests are 404 and never listed":
    for target in ["/sub", "/sub/", "/media", "/media/", "/sub/./"]:
      checkpoint target
      let r = src.serveAsset(request(target))
      check r.status == 404
      check "page.html" notin r.body
      check "blob.bin" notin r.body

  bothModes "HEAD gets the same response; the body is stripped by the encoder":
    let g = src.serveAsset(request("/app.js"))
    let h = src.serveAsset(request("/app.js", "HEAD"))
    check h.status == 200
    check h.headers == g.headers
    check h.body == g.body
    let wire = encodeResponse(h, keepAlive = true, headOnly = true)
    check wire.endsWith("\r\n\r\n")
    check ("Content-Length: " & $g.body.len) in wire
    check g.body notin wire

  bothModes "methods other than GET/HEAD are 405":
    for m in ["POST", "PUT", "DELETE", "OPTIONS"]:
      checkpoint m
      let r = src.serveAsset(request("/", m))
      check r.status == 405
      check r.getHeader("Allow") == "GET, HEAD"
    check src.serveAsset(request("/missing", "POST")).status == 405

  bothModes "Range: 206 for a satisfiable range":
    let r = src.serveAsset(request("/media/blob.bin", headers = @[("Range", "bytes=10-19")]))
    check r.status == 206
    check r.body == blob[10 .. 19]
    check r.getHeader("Content-Range") == "bytes 10-19/256"
    check r.getHeader("Accept-Ranges") == "bytes"
    check r.getHeader("Content-Type") == OctetStream
    let tail = src.serveAsset(request("/media/blob.bin", headers = @[("Range", "bytes=-16")]))
    check tail.status == 206
    check tail.body == blob[240 .. 255]
    check tail.getHeader("Content-Range") == "bytes 240-255/256"
    let open = src.serveAsset(request("/media/blob.bin", headers = @[("Range", "bytes=250-")]))
    check open.status == 206
    check open.body == blob[250 .. 255]
    let clamped = src.serveAsset(request("/media/blob.bin", headers = @[("Range", "bytes=0-999")]))
    check clamped.status == 206
    check clamped.body == blob

  bothModes "Range: 416 when unsatisfiable, 200 when ignorable":
    let r = src.serveAsset(request("/media/blob.bin", headers = @[("Range", "bytes=256-")]))
    check r.status == 416
    check r.getHeader("Content-Range") == "bytes */256"
    check src.serveAsset(request("/media/blob.bin", headers = @[("Range", "bytes=-0")])).status == 416
    for ignorable in ["foo", "bytes=5-2", "bytes=0-1,3-4", "items=0-3"]:
      checkpoint ignorable
      let ok = src.serveAsset(request("/media/blob.bin", headers = @[("Range", ignorable)]))
      check ok.status == 200
      check ok.body == blob

  bothModes "the whole binary round-trips byte for byte":
    let r = src.serveAsset(request("/media/blob.bin"))
    check r.body.len == 256
    check r.body == blob

# --- the two modes agree ---------------------------------------------------------

suite "assets: disk and embedded modes":
  test "the embedded table holds exactly the files on disk, keyed with / separators":
    var onDisk: seq[string]
    for rel in walkDirRec(FixtureDir, relative = true):
      onDisk.add rel.replace('\\', '/')
    onDisk.sort()
    var keys: seq[string]
    for (k, _) in Embedded:
      keys.add k
    check keys == onDisk
    check keys == sorted(keys)
    check "sub/page.html" in keys
    check "media/blob.bin" in keys
    for (k, content) in Embedded:
      checkpoint k
      check content == readFile(FixtureDir / k)
    check embedded.files.len == keys.len
    check embedded.mode == amEmbedded
    check disk.mode == amDisk

  test "every fixture file encodes identically from both modes":
    for (k, _) in Embedded:
      let target = "/" & k.replace(" ", "%20")  # a request line cannot hold a space
      checkpoint target
      let a = disk.serveAsset(request(target))
      let b = embedded.serveAsset(request(target))
      check a.status == 200
      check encodeResponse(a, true) == encodeResponse(b, true)
      let ra = disk.serveAsset(request(target, headers = @[("Range", "bytes=1-3")]))
      let rb = embedded.serveAsset(request(target, headers = @[("Range", "bytes=1-3")]))
      check ra.status == 206
      check encodeResponse(ra, true) == encodeResponse(rb, true)
    check encodeResponse(disk.serveAsset(request("/")), true) ==
      encodeResponse(embedded.serveAsset(request("/")), true)
    check encodeResponse(disk.serveAsset(request("/nope")), true) ==
      encodeResponse(embedded.serveAsset(request("/nope")), true)

  test "diskAssets normalizes its root; a missing root serves only 404s":
    check disk.root == FixtureDir.normalizedPath
    check diskAssets(FixtureDir & "/sub/..").root == FixtureDir.normalizedPath
    let missing = diskAssets(FixtureDir / "no-such-dir")
    check missing.serveAsset(request("/")).status == 404
    check missing.serveAsset(request("/index.html")).status == 404
    check lookupAsset(missing, "index.html").isNone

  test "resolveWebDir keeps absolute paths and joins relative ones":
    check resolveWebDir("/caller", "web") == "/caller" / "web"
    check resolveWebDir("/caller", FixtureDir) == FixtureDir

  test "an empty embedded source serves only 404s and 405s":
    let empty = embeddedAssets(newSeq[(string, string)]())
    check empty.serveAsset(request("/")).status == 404
    check empty.serveAsset(request("/", "POST")).status == 405

  test "embedding a missing directory is a compile error":
    check not compiles(embedWebDir("no/such/dir", "/nonexistent-base"))
