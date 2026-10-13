## t_expose.nim - `{.expose.}` wrappers, the compile-time registry, dispatch
## generation, reply building, and compile-time diagnostics.

import std/[unittest, json, options, tables, sets, os, osproc, streams,
            strutils, monotimes, times]
import neel/expose
import neel/protocol
import fixtures/exposed_helper

# --- exposed fixtures (top-level, before the dispatch generators) ------------------

type
  Point = object
    x, y: float
  Color = enum
    red, green, blue
  Payload = object
    label: string
    values: seq[int]
    origin: Point

proc add(a, b: int): int {.expose.} = a + b

proc greet(name: string; punct = "!"; times: int = 1): string {.expose.} =
  for _ in 0 ..< times:
    result.add "hi " & name & punct

proc span(lo: int; hi = lo + 2): seq[int] {.expose.} =
  for i in lo .. hi:
    result.add i

proc mixed(i: int; f: float; s: string; b: bool; xs: seq[int];
           p: Point): string {.expose.} =
  $i & "|" & $f & "|" & s & "|" & $b & "|" & $xs & "|" & $p

proc scale(p: Point; factor = 2.0): Point {.expose.} =
  Point(x: p.x * factor, y: p.y * factor)

proc noop() {.expose.} = discard

proc makePayload(label: string): Payload {.expose.} =
  Payload(label: label, values: @[1, 2, 3], origin: Point(x: 0.5, y: -1.0))

proc paint(c: Color): Color {.expose.} =
  if c == blue: red else: succ(c)

proc passthrough(n: JsonNode): JsonNode {.expose.} = n

proc maybe(o: Option[int]): int {.expose.} = o.get(-1)

proc firstPositive(xs: seq[int]): Option[int] {.expose.} =
  for x in xs:
    if x > 0: return some(x)

proc total(t: Table[string, int]): int {.expose.} =
  for v in t.values: result += v

proc distinctCount(s: HashSet[string]): int {.expose.} = s.len

proc count(args: seq[string]): int {.expose.} =
  ## A parameter named like the wrapper's own parameter must not clash.
  args.len

func doubled(a: int): int {.expose.} = a * 2

proc failing(): int {.expose.} =
  raise newException(ValueError, "bad value")

proc remoteFailing(): int {.expose.} =
  raise (ref NeelRemoteError)(kind: "TypeError", msg: "x is not a function")

generateDispatch(earlyDispatch)

proc lateProc(): string {.expose.} = "late"

generateDispatch(fullDispatch)

const names = exposedNames()

# --- helpers ---------------------------------------------------------------------

template argError(body: untyped): string =
  ## Message of the `NeelArgumentError` that `body` must raise.
  var msg = ""
  try:
    discard body
    checkpoint "expected NeelArgumentError"
    fail()
  except NeelArgumentError as e:
    msg = e.msg
  msg

template rejected(body: untyped): bool =
  ## `body` (a declaration) must fail to compile.
  not compiles((block:
    body
    true))

const NimCheckTimeoutMs = 120_000

proc nimCheck(dir, mainFile: string): string =
  ## Runs `nim check` on `dir / mainFile` with the repo's `src/` on the path
  ## and returns its combined output. Bounded by `NimCheckTimeoutMs`.
  let nim = findExe("nim")
  doAssert nim.len > 0, "nim not found on PATH"
  let srcDir = currentSourcePath().parentDir.parentDir / "src"
  let p = startProcess(nim, workingDir = dir,
                       args = ["check", "--hints:off", "--path:" & srcDir,
                               "--nimcache:" & (dir / "cache"), mainFile],
                       options = {poStdErrToStdOut})
  defer: close(p)
  let deadline = getMonoTime() + initDuration(milliseconds = NimCheckTimeoutMs)
  var line = ""
  while true:
    if p.hasData:
      if p.outputStream.readLine(line):
        result.add line & "\n"
      elif p.peekExitCode != -1:
        break
      else:
        sleep 10
    elif p.peekExitCode != -1:
      result.add p.outputStream.readAll()
      break
    elif getMonoTime() > deadline:
      p.kill()
      doAssert false, "nim check timed out after " & $NimCheckTimeoutMs & " ms"
    else:
      sleep 20

proc errorLine(output, text: string): string =
  ## The first `Error:` line of `output` containing `text` ("" if none).
  for line in output.splitLines:
    if " Error: " in line and text in line:
      return line
  ""

proc location(errLine: string): (string, int) =
  ## Splits `path(line, col) Error: ...` into the file name and line.
  let open = errLine.find('(')
  let comma = errLine.find(',', open)
  (extractFilename(errLine[0 ..< open]), parseInt(errLine[open + 1 ..< comma]))

# --- wrappers --------------------------------------------------------------------

suite "expose wrapper":
  test "wrapper symbol is callable directly and round-trips every scalar kind":
    let r = mixedNeelSym(@[%1, %2.5, %"s", %true, %*[1, 2], %*{"x": 1, "y": 2}])
    check r == %"1|2.5|s|true|@[1, 2]|(x: 1.0, y: 2.0)"

  test "multi-name IdentDefs (a, b: int)":
    check addNeelSym(@[%2, %3]) == %5

  test "defaults make trailing parameters optional":
    check greetNeelSym(@[%"bob"]) == %"hi bob!"
    check greetNeelSym(@[%"bob", %"?"]) == %"hi bob?"
    check greetNeelSym(@[%"bob", %"?", %2]) == %"hi bob?hi bob?"

  test "a default may refer to an earlier parameter":
    check spanNeelSym(@[%1]) == %*[1, 2, 3]
    check spanNeelSym(@[%1, %1]) == %*[1]

  test "void proc returns JNull":
    let r = noopNeelSym(@[])
    check r.kind == JNull

  test "object return value serialises field by field":
    check makePayloadNeelSym(@[%"p"]) ==
      %*{"label": "p", "values": [1, 2, 3], "origin": {"x": 0.5, "y": -1.0}}

  test "object parameter converts; extra JSON keys are ignored":
    check scaleNeelSym(@[%*{"x": 1, "y": 2, "extra": true}]) == %*{"x": 2.0, "y": 4.0}
    check scaleNeelSym(@[%*{"x": 1, "y": 2}, %3]) == %*{"x": 3.0, "y": 6.0}

  test "enum parameters accept the name or the ordinal; results are names":
    check paintNeelSym(@[%"red"]) == %"green"
    check paintNeelSym(@[%1]) == %"blue"
    check paintNeelSym(@[%"blue"]) == %"red"

  test "JsonNode parameters and results pass through untouched":
    let raw = %*{"k": [1, nil, "x"]}
    check passthroughNeelSym(@[raw]) == raw

  test "Option parameter: null is none (jsonutils hooks without importing jsonutils)":
    check maybeNeelSym(@[newJNull()]) == %(-1)
    check maybeNeelSym(@[%7]) == %7
    check argError(maybeNeelSym(@[%"x"])) == "maybe: argument 'o' expects Option[int], got string"

  test "Option result: none is null, some is the value":
    check firstPositiveNeelSym(@[%*[-1, 0, 3]]) == %3
    check firstPositiveNeelSym(@[%*[-1]]).kind == JNull

  test "Table and HashSet parameters; a wrong shape is an error, not a Defect":
    check totalNeelSym(@[%*{"a": 1, "b": 2}]) == %3
    check argError(totalNeelSym(@[%*[1]])) ==
      "total: argument 't' expects Table[string, int], got array"
    check distinctCountNeelSym(@[%*["a", "b", "a"]]) == %2
    check argError(distinctCountNeelSym(@[%*{"a": 1}])) ==
      "distinctCount: argument 's' expects HashSet[string], got object"

  test "a user parameter named 'args' does not clash with the wrapper's":
    check countNeelSym(@[%*["a", "b"]]) == %2

  test "func can be exposed":
    check doubledNeelSym(@[%21]) == %42

  test "exceptions from the proc propagate unchanged":
    expect ValueError:
      discard failingNeelSym(@[])

  test "arity: too few and too many arguments":
    check argError(addNeelSym(@[%1])) == "add: expected 2 arguments, got 1"
    check argError(addNeelSym(@[%1, %2, %3])) == "add: expected 2 arguments, got 3"
    check argError(noopNeelSym(@[%1])) == "noop: expected 0 arguments, got 1"
    check argError(doubledNeelSym(@[])) == "doubled: expected 1 argument, got 0"

  test "arity with defaults reports the range":
    check argError(greetNeelSym(@[])) == "greet: expected 1 to 3 arguments, got 0"
    check argError(greetNeelSym(@[%"a", %"b", %1, %2])) ==
      "greet: expected 1 to 3 arguments, got 4"

  test "type mismatch names the proc, the parameter, the type, and the JSON kind":
    check argError(addNeelSym(@[%"x", %2])) == "add: argument 'a' expects int, got string"
    check argError(addNeelSym(@[%1, %2.5])) == "add: argument 'b' expects int, got float"
    check argError(addNeelSym(@[%1, newJNull()])) == "add: argument 'b' expects int, got null"
    check argError(mixedNeelSym(@[%1, %2.5, %"s", %true, %"nope", %*{"x": 1, "y": 2}])) ==
      "mixed: argument 'xs' expects seq[int], got string"
    check argError(mixedNeelSym(@[%1, %2.5, %"s", %true, %*[1], %*[1, 2]])) ==
      "mixed: argument 'p' expects Point, got array"
    check argError(greetNeelSym(@[%"a", %"b", %"c"])) ==
      "greet: argument 'times' expects int, got string"

  test "a mismatch inside an object or array carries the detail":
    let missing = argError(scaleNeelSym(@[%*{"x": 1}]))
    check missing.startsWith("scale: argument 'p' expects Point, got object: ")
    check "key 'y' for Point" in missing
    check '\n' notin missing
    let badElem = argError(spanNeelSym(@[%1, %*[1]]))
    check badElem == "span: argument 'hi' expects int, got array"
    let badEnum = argError(paintNeelSym(@[%"purple"]))
    check badEnum.startsWith("paint: argument 'c' expects Color, got string: ")
    check "purple" in badEnum

  test "exposed name is the proc name":
    check "add" in names
    check "greet" in names
    check "doubled" in names
    check fullDispatch("add", @[%1, %1]) == %2

# --- dispatch ----------------------------------------------------------------------

suite "dispatch":
  test "generateDispatch routes by name over several procs":
    check fullDispatch("add", @[%1, %2]) == %3
    check fullDispatch("greet", @[%"x"]) == %"hi x!"
    check fullDispatch("noop", @[]).kind == JNull
    check fullDispatch("doubled", @[%4]) == %8

  test "unknown name raises NeelUnknownProcError":
    try:
      discard fullDispatch("nope", @[])
      fail()
    except NeelUnknownProcError as e:
      check e.msg == "no exposed proc named 'nope'"
      check $e.name == "NeelUnknownProcError"

  test "ordering rule: only procs exposed before the generator are dispatched":
    expect NeelUnknownProcError:
      discard earlyDispatch("lateProc", @[])
    check fullDispatch("lateProc", @[]) == %"late"
    check "lateProc" in names
    check earlyDispatch("add", @[%1, %2]) == %3

  test "cross-module: procs exposed in the fixture module are dispatched":
    check helperMul(6, 7) == 42
    check fullDispatch("helperMul", @[%6, %7]) == %42
    check fullDispatch("helperSecret", @[]) == %"reached through the registry"
    check "helperMul" in names
    check "helperSecret" in names

  test "exposedNames lists registration order: imported module first":
    check names[0] == "helperMul"
    check names[1] == "helperSecret"
    check names.find("add") < names.find("greet")
    check names[^1] == "lateProc"

  test "wrapper errors route through the dispatcher unchanged":
    expect NeelArgumentError:
      discard fullDispatch("add", @[%1])

# --- reply building --------------------------------------------------------------------

suite "handleCall":
  test "success with id -> ret":
    let reply = handleCall(callMsg("add", @[%1, %2], id = 17), fullDispatch)
    check reply.isSome
    check reply.get == retMsg(17, %3)
    check encode(reply.get) == """{"t":"ret","id":17,"value":3}"""

  test "void proc with id -> ret with value null":
    let reply = handleCall(callMsg("noop", @[], id = 2), fullDispatch)
    check reply.isSome
    check encode(reply.get) == """{"t":"ret","id":2,"value":null}"""

  test "plain exception -> err with the exception type as kind":
    let reply = handleCall(callMsg("failing", @[], id = 3), fullDispatch)
    check reply.isSome
    check reply.get == errMsg(3, "ValueError", "bad value")

  test "NeelRemoteError keeps its forwarded kind":
    let reply = handleCall(callMsg("remoteFailing", @[], id = 4), fullDispatch)
    check reply.isSome
    check reply.get == errMsg(4, "TypeError", "x is not a function")

  test "argument errors -> err with kind NeelArgumentError":
    let reply = handleCall(callMsg("add", @[%"x", %1], id = 5), fullDispatch)
    check reply.get == errMsg(5, "NeelArgumentError",
                              "add: argument 'a' expects int, got string")
    let arity = handleCall(callMsg("add", @[], id = 6), fullDispatch)
    check arity.get == errMsg(6, "NeelArgumentError", "add: expected 2 arguments, got 0")

  test "unknown name -> err with kind NeelUnknownProcError":
    let reply = handleCall(callMsg("nope", @[], id = 7), fullDispatch)
    check reply.get == errMsg(7, "NeelUnknownProcError", "no exposed proc named 'nope'")

  test "call without id produces no reply, whether it succeeds or raises":
    check handleCall(callMsg("add", @[%1, %2]), fullDispatch).isNone
    # The raising case logs one line to stderr in debug builds; that is
    # expected output of this test.
    check handleCall(callMsg("failing", @[]), fullDispatch).isNone
    check handleCall(callMsg("nope", @[]), fullDispatch).isNone

  test "fire-and-forget still runs the proc":
    var ran = false
    let probe: DispatchProc = proc(name: string; args: seq[JsonNode]): JsonNode {.gcsafe.} =
      ran = true
      nil
    check handleCall(callMsg("anything", @[]), probe).isNone
    check ran

  test "a closure dispatcher is accepted and a nil result encodes as null":
    let constant: DispatchProc = proc(name: string; args: seq[JsonNode]): JsonNode {.gcsafe.} =
      nil
    let reply = handleCall(callMsg("x", @[], id = 9), constant)
    check encode(reply.get) == """{"t":"ret","id":9,"value":null}"""

# --- compile-time diagnostics ----------------------------------------------------------

suite "expose compile-time diagnostics":
  test "compiles(): generic proc, non-proc target, and varargs are rejected":
    let generic = rejected:
      proc g[T](x: T): T {.expose.} = x
    check generic
    let tmpl = rejected:
      template t(): int {.expose.} = 1
    check tmpl
    let va = rejected:
      proc v(x: varargs[int]) {.expose.} = discard
    check va

  let dir = getTempDir() / ("neel_t_expose_" & $getCurrentProcessId())
  createDir(dir)

  try:
    test "nim check: nested proc is rejected at the user's proc line":
      writeFile(dir / "nested.nim", """
import neel/expose
proc outer() =
  proc inner(a: int): int {.expose.} = a
  discard inner(1)
outer()
""")
      let output = nimCheck(dir, "nested.nim")
      let line = errorLine(output, "cannot expose 'inner': it is declared inside 'outer'")
      check line.len > 0
      check "must be top-level" in line
      check location(line) == ("nested.nim", 3)

    test "nim check: generic proc is rejected at the user's proc line":
      writeFile(dir / "generic.nim", """
import neel/expose

proc same[T](x: T): T {.expose.} = x
""")
      let output = nimCheck(dir, "generic.nim")
      let line = errorLine(output, "cannot expose generic proc 'same'")
      check line.len > 0
      check "concrete parameter types" in line
      check location(line) == ("generic.nim", 3)

    test "nim check: non-proc target is rejected":
      writeFile(dir / "nonproc.nim", """
import neel/expose
template shout(s: string): string {.expose.} = s & "!"
""")
      let output = nimCheck(dir, "nonproc.nim")
      let line = errorLine(output, "can only be applied to a proc or func, not to a template")
      check line.len > 0
      check location(line) == ("nonproc.nim", 2)

    test "nim check: duplicate exposed names across two modules name both locations":
      writeFile(dir / "dup_a.nim", """
import neel/expose
proc dup(a: int): int {.expose.} = a
""")
      writeFile(dir / "dup_b.nim", """
import neel/expose

proc dup(a: string): string {.expose.} = a
""")
      writeFile(dir / "dup_main.nim", """
import neel/expose
import dup_a, dup_b
generateDispatch(dispatch)
""")
      let output = nimCheck(dir, "dup_main.nim")
      let line = errorLine(output, "exposed name 'dup' is used twice")
      check line.len > 0
      check "dup_a.nim(2, 6)" in line
      check "dup_b.nim(3, 6)" in line
      check "unique across all modules" in line
      # Reported at the second definition, not inside macros.nim.
      check location(line) == ("dup_b.nim", 3)
      check "duplicate case label" notin output
      check "macros.nim" notin errorLine(output, "Error:")

    test "nim check: a GC-unsafe exposed proc is reported at the user's proc line":
      writeFile(dir / "unsafe.nim", """
import neel/expose
var counter: seq[int]
proc bump(): int {.expose.} =
  counter.add 1
  counter.len
""")
      let output = nimCheck(dir, "unsafe.nim")
      let line = errorLine(output, "'bumpNeelSym' is not GC-safe as it calls 'bump'")
      check line.len > 0
      check location(line) == ("unsafe.nim", 3)
  finally:
    removeDir(dir)
