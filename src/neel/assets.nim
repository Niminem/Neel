## assets.nim - serving the application's web directory from disk or from
## compile-time embedded data.
##
## `startApp` takes `embedAssets: static bool = defined(release)`. In debug
## builds assets are read from disk on every request so edits show up on
## refresh; in release builds the whole web directory is `staticRead` into the
## binary. Both modes share the same lookup API, enforce path containment
## (no escaping the web root), and return real 404s for missing files. MIME
## types and `Range` handling come from `http.nim`.
##
## Surface:
## - `AssetSource`: where files come from. `diskAssets(dir)` resolves `dir`
##   to an absolute, normalized root and reads files per request;
##   `embeddedAssets(files)` holds a table built at compile time by
##   `embedWebDir(dir, callerDir)`, keyed by the root-relative path with `/`
##   separators (`"index.html"`, `"css/app.css"`).
## - `resolveAssetPath(rawPath)`: the pure request-path -> key step shared by
##   both modes. Percent-decodes (`std/uri.decodeUrl`), rejects anything
##   with a NUL byte, a backslash, or a `..` segment, drops `.` and empty
##   segments, maps `/` to `index.html`, and returns `none` for a path that
##   ends in `/` (a directory request). Only a `some` key is ever looked up.
## - `lookupAsset(src, key)`: the bytes of one file or `none`. Disk mode
##   additionally containment-checks the joined path against the root
##   (`isRelativeTo` after `normalizedPath`) and never reads a directory;
##   symbolic links inside the web root are followed without further checks.
## - `serveAsset(src, req)`: the whole route as a pure proc returning an
##   `HttpResponse` (unit-testable without a server): 405 for anything but
##   `GET`/`HEAD`, 404 for a missing or escaping path, otherwise 200 with
##   `Content-Type` from `contentTypeFor` and `Accept-Ranges: bytes`, or
##   206 / 416 when a `Range` header is present (`parseRange`). `HEAD` gets
##   the same response; the server strips the body.
##
## Resolution of the web directory: a relative `webDir` is resolved against
## the directory of the source file that calls `startApp` (known at compile
## time) in *both* modes, so debug and release builds find the same files no
## matter which directory the program is started from. An absolute `webDir`
## is used as-is. Directory listings are never produced.

import std/[os, tables, options, strutils, uri, algorithm, macros]
import ./http

type
  AssetMode* = enum
    ## Where `AssetSource` reads from.
    amDisk      ## Read the file under `root` on every request.
    amEmbedded  ## Serve from `files`, filled at compile time.

  AssetSource* = object
    ## The application's web directory, either on disk or embedded. Built
    ## once by `startApp` (through `diskAssets` / `embeddedAssets`) and read
    ## concurrently by pool workers; nothing mutates it afterwards.
    mode*: AssetMode
    root*: string
      ## Absolute, normalized web root (`amDisk`); `""` when embedded.
    files*: Table[string, string]
      ## Root-relative key (`/` separators) -> file bytes (`amEmbedded`).

const
  IndexFile* = "index.html"
    ## What a request for `/` serves.

# --- sources ---------------------------------------------------------------------

proc resolveWebDir*(callerDir, dir: string): string =
  ## `dir` itself when absolute, otherwise `callerDir / dir`. `startApp`
  ## passes the directory of its calling source file as `callerDir` so both
  ## asset modes resolve the same directory. Pure.
  if dir.isAbsolute: dir else: callerDir / dir

proc diskAssets*(dir: string): AssetSource =
  ## A source that reads `dir` on every request. `dir` is made absolute
  ## against the current working directory if it is relative (callers that
  ## know a better base, such as `startApp`, join it first) and normalized.
  ## The directory need not exist yet; missing files are 404s at request
  ## time.
  AssetSource(mode: amDisk, root: normalizedPath(absolutePath(dir)))

proc embeddedAssets*(files: openArray[(string, string)]): AssetSource =
  ## A source serving `files`, each `(key, bytes)` with `key` root-relative
  ## and `/`-separated, as produced by `embedWebDir`.
  result = AssetSource(mode: amEmbedded)
  for (key, content) in files:
    result.files[key] = content

macro embedWebDir*(dir, callerDir: static string): untyped =
  ## Expands to a `seq[(string, string)]` literal of every file under `dir`
  ## (walked recursively at compile time, sorted by key, `staticRead` into
  ## the binary), keyed by the path relative to `dir` with `/` separators. A
  ## relative `dir` is resolved against `callerDir` (the directory of the
  ## source file calling `startApp`). A missing directory is a compile
  ## error. Pass the result to `embeddedAssets`.
  let root = normalizedPath(resolveWebDir(callerDir, dir))
  if not dirExists(root):
    error("neel: web directory not found for embedding: " & root &
          " (webDir = \"" & dir & "\" relative to " & callerDir & ")")
  var keys: seq[string]
  for rel in walkDirRec(root, relative = true):
    keys.add rel.replace('\\', '/')
  keys.sort()
  var items = nnkBracket.newTree()
  for key in keys:
    items.add nnkTupleConstr.newTree(newLit(key), newLit(staticRead(root / key)))
  if keys.len == 0:
    result = newCall(nnkBracketExpr.newTree(ident"newSeq",
      nnkTupleConstr.newTree(bindSym"string", bindSym"string")))
  else:
    result = prefix(items, "@")

# --- path resolution -------------------------------------------------------------

proc resolveAssetPath*(rawPath: string): Option[string] =
  ## Turns a raw request path (not yet percent-decoded) into a lookup key:
  ## decodes it, rejects a NUL byte, a backslash, or any `..` segment,
  ## drops `.` and empty segments, and joins the rest with `/`. `/` (or any
  ## path that reduces to nothing) becomes `IndexFile`; a path that ends in
  ## `/` otherwise is a directory request and yields `none`, as does a path
  ## that does not start with `/`. Pure.
  if rawPath.len == 0 or rawPath[0] != '/':
    return none(string)
  # `decodeUrl` never raises: a `%` not followed by two hex digits is kept.
  let decoded = decodeUrl(rawPath, decodePlus = false)
  if '\0' in decoded or '\\' in decoded:
    return none(string)
  var segments: seq[string]
  for seg in decoded.split('/'):
    case seg
    of "", ".":
      discard
    of "..":
      return none(string)
    else:
      segments.add seg
  if segments.len == 0:
    return some(IndexFile)
  if decoded[^1] == '/':
    return none(string)
  some(segments.join("/"))

# --- lookup ----------------------------------------------------------------------

proc lookupAsset*(src: AssetSource; key: string): Option[string] =
  ## The bytes of the file `key` (a `resolveAssetPath` result) or `none`
  ## when it does not exist, is a directory, or (disk mode) resolves outside
  ## the web root. Disk mode reads the file on every call.
  case src.mode
  of amEmbedded:
    if src.files.hasKey(key):
      return some(src.files[key])
    none(string)
  of amDisk:
    let full = normalizedPath(src.root / key)
    # Defence in depth: `resolveAssetPath` already refused `..`, so this
    # only fails if the key somehow escapes anyway.
    if not full.isRelativeTo(src.root):
      return none(string)
    if not fileExists(full):  # false for directories and dangling links
      return none(string)
    try:
      some(readFile(full))
    except IOError, OSError:
      none(string)

# --- the route -------------------------------------------------------------------

proc serveAsset*(src: AssetSource; req: HttpRequest): HttpResponse =
  ## The response for an asset request: `methodNotAllowed()` unless `GET`
  ## or `HEAD`; `notFound()` when `resolveAssetPath` or `lookupAsset` says
  ## no; otherwise the file with `Content-Type` from `contentTypeFor` and
  ## `Accept-Ranges: bytes`, honouring a single `Range` (`partialContent`
  ## for 206, `rangeNotSatisfiable` for 416; an unusable `Range` is
  ## ignored). Pure apart from the disk read.
  if req.httpMethod notin {hmGet, hmHead}:
    return methodNotAllowed()
  let key = resolveAssetPath(req.path)
  if key.isNone:
    return notFound()
  let content = src.lookupAsset(key.get)
  if content.isNone:
    return notFound()
  let body = content.get
  let contentType = contentTypeFor(key.get)
  if req.hasHeader("Range"):
    let r = parseRange(req.getHeader("Range"), body.len)
    case r.status
    of rsSatisfiable:
      return partialContent(body[r.range.first .. r.range.last], contentType,
                            r.range, body.len)
    of rsUnsatisfiable:
      return rangeNotSatisfiable(body.len)
    of rsIgnored:
      discard
  result = okResponse(body, contentType)
  result.addHeader("Accept-Ranges", "bytes")
