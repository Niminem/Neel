## expose.nim - the `{.expose.}` pragma, compile-time registry, and dispatch
## generation.
##
## `expose` is applied to top-level procs. It validates the signature (no
## nested procs, no generics, supported parameter forms including multi-name
## `IdentDefs` and default values) and emits an exported wrapper
## `<name>NeelSym*(args: seq[JsonNode]): JsonNode {.gcsafe.}` that checks arity,
## converts each argument with `std/jsonutils.fromJson`, calls the user proc,
## and returns `toJson` of the result (or `null` for void). It then emits
## `neelRegister("name", <name>NeelSym)`, a `typed` macro that stores the bound
## `nnkSym` in a `{.compileTime.}` registry.
##
## Surface:
## - `{.expose.}` on a top-level `proc` / `func`. The user's proc is emitted
##   unchanged, followed by the wrapper and the registration.
## - `neelRegister(name, wrapper)`: registration macro, also usable by hand for
##   a wrapper written manually (any top-level
##   `proc(args: seq[JsonNode]): JsonNode {.gcsafe.}`).
## - `generateDispatch(procName)`: emits
##   `proc procName(name: string; args: seq[JsonNode]): JsonNode {.gcsafe.}`
##   with a `case name` over every exposed proc registered *so far*; unknown
##   names raise `NeelUnknownProcError`. Duplicate exposed names are a compile
##   error naming both locations.
## - `handleCall(msg, dispatch)`: turns an incoming `call` into its `ret` /
##   `err` reply (`Option[Msg]`; `none` for a fire-and-forget call).
## - `exposedNames()`: compile-time `seq[string]` literal of the exposed names
##   registered so far (for the `__NEEL_EXPOSED__` placeholder);
##   `exposedProcs()`: the raw registry for other macros.
## - `NeelArgumentError` (arity / conversion failures, raised by wrappers) and
##   `NeelUnknownProcError` (raised by the dispatcher). Both reach JS as
##   `err.error.kind` via `$e.name`.
##
## Conversions use `std/jsonutils` (`jsonTo` / `toJson`) rather than
## `std/json`'s `to` / `%`: it covers more types (sets, arrays, distinct,
## `ref`, `Option`, `Table`, case objects, enums as strings) and lets
## `toJsonHook` / `fromJsonHook` customise user types. Supported parameter and
## return types are therefore everything `jsonutils` handles: `bool`, integers
## and floats (a float parameter accepts an integer), `string`, enums
## (arguments accept the name or the ordinal, results are emitted as names),
## `seq[T]` / `array[N, T]` / `set[T]` (the argument must be a JSON array),
## tuples, objects (extra JSON keys are ignored, missing keys are an error),
## `ref T` (`null` <-> `nil`), `distinct`, `Option[T]` (`null` <-> `none`),
## `Table[string, V]` / `OrderedTable` (from a JSON object), `HashSet` /
## `OrderedSet` (from a JSON array), and `JsonNode` itself (passed through
## untouched). The `jsonutils` hooks for `Option` / `Table` / `HashSet` are
## re-exported from here because the conversion is instantiated in the user's
## module, which need not import `std/jsonutils`; a user-defined
## `fromJsonHook` must raise a `CatchableError` (not `assert`) on bad input
## so the failure becomes an `err` reply rather than a Defect. Not supported
## as parameters: `var`, `ptr` / `pointer`, `openArray`, `varargs`, `sink` /
## `lent`, proc types, `typedesc` / `static` / `auto` / type classes (they
## make the proc generic). Note that `std/json` maps JSON `null` to `""` for a
## `string` parameter.
##
## Ordering rule: the registry is filled while modules are semantically
## checked, so `generateDispatch` (and therefore `startApp`) only sees procs
## whose `{.expose.}` was checked *before* its call site: call it after every
## exposed proc in the module and after the imports of modules that contain
## exposed procs. It may be called inside a proc (e.g. `main()`).
##
## Threading: wrappers, the generated dispatcher, and `handleCall` are
## `{.gcsafe.}` and run on pool workers. An exposed proc must therefore be
## GC-safe itself (no writes to global GC'd state without `{.cast(gcsafe).}`
## and a lock); the compiler reports a violation at the user's `proc` line.
## Nothing here touches a "current window"; Task 13 sets the thread-local
## window around its call to `handleCall` (see that proc's doc comment).

import std/[macros, json, jsonutils, options, strutils, tables, sets]
import ./protocol

# `jsonutils` finds its own `Option` / `Table` / `HashSet` hooks through a
# `mixin` lookup in the module that *instantiates* the conversion, which is
# the user's module (the wrapper lives there). Re-exporting the hook overloads
# puts them in scope so those types work without the user importing
# `std/jsonutils`. Deliberate, narrow exception to the "no stdlib re-exports"
# rule.
export fromJsonHook, toJsonHook

type
  NeelArgumentError* = object of CatchableError
    ## Raised by a wrapper when the argument count is outside the proc's
    ## arity or an argument cannot be converted to the parameter's type.
    ## Messages: `"<proc>: expected N argument(s), got M"`,
    ## `"<proc>: expected N to M arguments, got K"`, and
    ## `"<proc>: argument '<param>' expects <Type>, got <json kind>"` (with
    ## `": <detail>"` appended when the reason is more than the kind, e.g. a
    ## missing object key or an unknown enum name). Wire kind:
    ## `"NeelArgumentError"`.

  NeelUnknownProcError* = object of CatchableError
    ## Raised by the generated dispatcher for a name that is not exposed.
    ## Message: `"no exposed proc named '<name>'"`. Wire kind:
    ## `"NeelUnknownProcError"`.

  DispatchProc* = proc(name: string; args: seq[JsonNode]): JsonNode {.gcsafe.}
    ## Signature of the proc produced by `generateDispatch`; what
    ## `handleCall` takes.

  ExposedProc* = object
    ## One compile-time registry entry.
    name*: string    ## Exposed name (the proc's name).
    sym*: NimNode    ## Bound `nnkSym` of the `<name>NeelSym` wrapper.
    info*: LineInfo  ## Location of the user's `proc` line.

const
  ArgOptions = Joptions(allowExtraKeys: true, allowMissingKeys: false)
    ## JS objects often carry extra properties; a missing field is a real
    ## mismatch and stays an error.
  ResultOptions = ToJsonOptions(enumMode: joptEnumString,
                                jsonNodeMode: joptJsonNodeAsRef)
    ## Enums leave as their names (what JS code wants to compare against);
    ## a `JsonNode` result is passed through without copying.

var exposedRegistry {.compileTime.}: seq[ExposedProc]

# --- runtime helpers called by generated code ----------------------------------

proc jsonKindName(n: JsonNode): string =
  if n.isNil: return "null"
  case n.kind
  of JNull: "null"
  of JBool: "boolean"
  of JInt: "integer"
  of JFloat: "float"
  of JString: "string"
  of JArray: "array"
  of JObject: "object"

proc checkArity*(procName: string; given, minArgs, maxArgs: int) {.gcsafe.} =
  ## Raises `NeelArgumentError` unless `minArgs <= given <= maxArgs`. Called
  ## first by every wrapper; `minArgs` counts the parameters up to the last
  ## one without a default value.
  if given < minArgs or given > maxArgs:
    let expected =
      if minArgs == maxArgs:
        $minArgs & (if minArgs == 1: " argument" else: " arguments")
      else:
        $minArgs & " to " & $maxArgs & " arguments"
    raise newException(NeelArgumentError,
                       procName & ": expected " & expected & ", got " & $given)

proc conversionDetail(msg: string): string =
  ## Trims a `jsonutils` / `std/json` failure message for the wire: drops the
  ## `"<condition> failed: "` prefix and joins pretty-printed JSON onto one
  ## line. Empty when the message only restates a JSON kind mismatch, which
  ## the caller already names.
  var m = msg
  let sep = m.find(" failed: ")
  if sep >= 0:
    m = m[sep + " failed: ".len .. ^1]
  var parts: seq[string]
  for line in m.splitLines:
    let s = line.strip
    if s.len > 0: parts.add s
  result = parts.join(" ")
  if result.startsWith("Incorrect JSON kind") or
     result in ["JNull", "JBool", "JInt", "JFloat", "JString", "JArray", "JObject"]:
    result = ""

proc typeLabel(T: typedesc): string =
  ## `$T` without the `system.` qualifier the compiler adds inside generics
  ## (`Option[system.int]` -> `Option[int]`).
  ($T).replace("system.", "")

proc convertArg*(args: seq[JsonNode]; index: int; procName, paramName: string;
                 T: typedesc): T {.gcsafe.} =
  ## Converts `args[index]` to `T` with `std/jsonutils`. Any conversion
  ## failure becomes a `NeelArgumentError` naming the proc, the parameter,
  ## the expected type, and the JSON kind that was received, plus the
  ## underlying reason when it says more than the kind (missing object key,
  ## unknown enum name, wrong array length, ...).
  let node = if index < args.len and not args[index].isNil: args[index]
             else: newJNull()
  var detail = ""
  try:
    # Shape checks `jsonutils` gets wrong for a wire input: it reads a
    # non-array as an empty `seq` (`len` of a scalar is 0), and its `Table`
    # and `HashSet` hooks `assert` the kind, which would be a Defect on a
    # worker thread instead of a reply to JS.
    when T is seq or T is array or T is set or T is HashSet or T is OrderedSet:
      if node.kind != JArray:
        raise newException(ValueError, "")
    elif T is Table or T is OrderedTable:
      if node.kind != JObject:
        raise newException(ValueError, "")
    result = jsonTo(node, T, ArgOptions)
    return
  except CatchableError as e:
    detail = conversionDetail(e.msg)
  var msg = procName & ": argument '" & paramName & "' expects " &
            typeLabel(T) & ", got " & jsonKindName(node)
  if detail.len > 0:
    msg.add ": " & detail
  raise newException(NeelArgumentError, msg)

proc convertResult*[T](value: T): JsonNode {.gcsafe.} =
  ## `toJson` of a wrapper's return value; a `nil` `JsonNode` becomes `null`.
  var r: JsonNode
  # `jsonutils` keeps no global state, but the compiler cannot infer that
  # for the enum path: `toJson[SomeEnum]` instantiates `toJson[string]`
  # from inside its own body and the inference gives up on the recursion
  # ("'toJson' is not GC-safe as it calls 'toJson'"). A user `toJsonHook`
  # is covered by the same cast, so hooks must be GC-safe themselves.
  {.cast(gcsafe).}:
    r = toJson(value, ResultOptions)
  if r.isNil: newJNull() else: r

proc raiseUnknownProc*(name: string) {.gcsafe, noreturn.} =
  ## The `else` branch of every generated dispatcher.
  raise newException(NeelUnknownProcError, "no exposed proc named '" & name & "'")

# --- compile-time registry -----------------------------------------------------

proc exposedProcs*(): seq[ExposedProc] {.compileTime.} =
  ## The registry as filled so far (registration order). For macros that need
  ## more than the names; `startApp` uses `generateDispatch` instead.
  exposedRegistry

macro exposedNames*(): untyped =
  ## Expands to a `seq[string]` literal of the exposed names registered so
  ## far, in registration order. Subject to the ordering rule in the module
  ## header. Task 10 substitutes it for `__NEEL_EXPOSED__`.
  if exposedRegistry.len == 0:
    result = newCall(newNimNode(nnkBracketExpr).add(ident"newSeq", bindSym"string"))
  else:
    var items = newNimNode(nnkBracket)
    for e in exposedRegistry:
      items.add newLit(e.name)
    result = newNimNode(nnkPrefix).add(ident"@", items)

proc pickWrapperSym(wrapper: NimNode): NimNode =
  ## `wrapper` is the typed argument of `neelRegister`. Normally an `nnkSym`;
  ## when the same wrapper name is visible from several modules the compiler
  ## hands over a sym choice, and the one declared in the registering file
  ## is the intended one.
  case wrapper.kind
  of nnkSym:
    wrapper
  of nnkClosedSymChoice, nnkOpenSymChoice:
    let here = wrapper.lineInfoObj.filename
    for s in wrapper:
      if s.lineInfoObj.filename == here:
        return s
    error("neelRegister: '" & $wrapper[0] & "' is ambiguous here; expose it under " &
          "a unique name", wrapper)
  else:
    error("neelRegister expects a proc symbol, got " & $wrapper.kind, wrapper)

macro neelRegister*(name: static string; wrapper: typed): untyped =
  ## Records `wrapper` (a `proc(args: seq[JsonNode]): JsonNode`) in the
  ## compile-time registry under the exposed `name`. Emitted by `{.expose.}`;
  ## may be called by hand for a hand-written wrapper. Errors when the proc
  ## is not top-level, since its symbol must stay reachable for the dispatch
  ## generated in another module.
  let sym = pickWrapperSym(wrapper)
  if sym.symKind != nskProc:
    error("neelRegister expects a proc symbol, '" & $sym & "' is a " & $sym.symKind, wrapper)
  let t = sym.getTypeInst
  if t.kind != nnkProcTy or t[0].len != 2:
    error("neelRegister: '" & $sym & "' must have the signature " &
          "proc(args: seq[JsonNode]): JsonNode", wrapper)
  # `owner` is deprecated because it misbehaves for generic instantiations;
  # the wrapper is never generic, and there is no other way to learn where a
  # proc was declared from inside a macro.
  {.push warning[Deprecated]: off.}
  let own = sym.owner
  {.pop.}
  if own.kind == nnkSym and own.symKind != nskModule:
    error("cannot expose '" & name & "': it is declared inside '" & $own &
          "'. Exposed procs must be top-level so the dispatch generated by " &
          "startApp can reach them", sym)
  exposedRegistry.add ExposedProc(name: name, sym: sym, info: sym.lineInfoObj)
  newStmtList()

# --- the expose pragma -----------------------------------------------------------

proc describeKind(k: NimNodeKind): string =
  case k
  of nnkTemplateDef: "template"
  of nnkMacroDef: "macro"
  of nnkIteratorDef: "iterator"
  of nnkMethodDef: "method"
  of nnkConverterDef: "converter"
  of nnkTypeDef, nnkTypeSection: "type"
  of nnkLetSection, nnkVarSection, nnkConstSection, nnkIdentDefs: "variable"
  else: $k

proc fmtInfo(info: LineInfo): string =
  ## `file(line, col)` with a 1-based column, like the compiler's own messages
  ## (`$LineInfo` prints the 0-based column).
  info.filename & "(" & $info.line & ", " & $(info.column + 1) & ")"

proc stamp(n: NimNode; src: NimNode) =
  ## Gives every node of a generated tree the line info of `src` (the user's
  ## proc name) so diagnostics about the wrapper point at the user's code,
  ## not at this module.
  n.copyLineInfo(src)
  for child in n:
    stamp(child, src)

proc pragmaName(p: NimNode): NimNode =
  if p.kind in {nnkExprColonExpr, nnkCall, nnkCommand} and p.len > 0: p[0]
  else: p

proc checkParamType(procName: string; param, typ: NimNode) =
  ## Rejects parameter forms that have no JSON representation or would make
  ## the proc generic. Only the top-level form is checked here; a nested
  ## unsupported type (e.g. `seq[ptr int]`) is reported by `jsonutils`.
  template reject(reason: string) =
    error("cannot expose '" & procName & "': parameter '" & $param & "' " &
          reason, typ)
  case typ.kind
  of nnkVarTy:
    reject("is a 'var' parameter; arguments arrive as JSON copies, so the " &
           "proc could not modify the caller's variable")
  of nnkPtrTy:
    reject("is a pointer type, which has no JSON representation")
  of nnkProcTy, nnkIteratorTy:
    reject("is a proc type, which has no JSON representation")
  of nnkBracketExpr:
    if typ.len > 0 and typ[0].kind == nnkIdent:
      let head = normalize($typ[0])
      case head
      of "varargs":
        reject("uses varargs; a wrapper needs a fixed arity (take a seq[T] " &
               "and pass an array from JS)")
      of "openarray":
        reject("is an openArray, which cannot be stored in a local; use seq[T]")
      of "typedesc", "static":
        reject("makes the proc generic; exposed procs need concrete parameter types")
      of "ptr":
        reject("is a pointer type, which has no JSON representation")
      else: discard
  of nnkIdent:
    case normalize($typ)
    of "typedesc", "untyped", "typed", "auto":
      reject("makes the proc generic; exposed procs need concrete parameter types")
    of "pointer":
      reject("is a pointer type, which has no JSON representation")
    else: discard
  of nnkCommand:
    if typ.len > 0 and typ[0].kind == nnkIdent and
       normalize($typ[0]) in ["sink", "lent"]:
      reject("uses '" & $typ[0] & "'; use a plain parameter type")
  of nnkInfix:
    if typ[0].eqIdent("|") or typ[0].eqIdent("or"):
      reject("is a type class, which makes the proc generic; exposed procs " &
             "need concrete parameter types")
  else: discard

proc checkReturnType(procName: string; typ: NimNode) =
  template reject(reason: string) =
    error("cannot expose '" & procName & "': the return type " & reason, typ)
  case typ.kind
  of nnkVarTy: reject("is 'var'; return a value instead")
  of nnkPtrTy: reject("is a pointer type, which has no JSON representation")
  of nnkProcTy, nnkIteratorTy:
    reject("is a proc type, which has no JSON representation")
  of nnkIdent:
    if normalize($typ) in ["pointer", "typedesc", "untyped", "typed"]:
      reject("'" & $typ & "' has no JSON representation")
  of nnkBracketExpr:
    if typ.len > 0 and typ[0].kind == nnkIdent and
       normalize($typ[0]) in ["ptr", "typedesc", "static"]:
      reject("'" & typ.repr & "' has no JSON representation")
  else: discard

proc isVoid(typ: NimNode): bool =
  typ.kind == nnkEmpty or (typ.kind == nnkIdent and typ.eqIdent("void"))

macro expose*(def: untyped): untyped =
  ## Marks a top-level proc as callable from JS as `neel.<name>(...)`. Emits
  ## the proc unchanged, the wrapper `<name>NeelSym*(args: seq[JsonNode]):
  ## JsonNode {.gcsafe.}`, and `neelRegister("<name>", <name>NeelSym)`.
  ##
  ## The wrapper raises `NeelArgumentError` for a wrong argument count
  ## (default values make trailing parameters optional) or an argument whose
  ## JSON cannot be converted to the parameter type; see the module header
  ## for the supported types. Exceptions from the proc itself propagate.
  ##
  ## Compile errors (all at the user's code): not a proc, nested proc,
  ## generic proc, operator name, forward declaration, duplicate `expose`,
  ## `compileTime` / `varargs` / `thread` pragmas, and the parameter forms
  ## listed in the module header.
  if def.kind notin {nnkProcDef, nnkFuncDef}:
    error("{.expose.} can only be applied to a proc or func, not to a " &
          describeKind(def.kind), def)

  var nameNode = def[0]
  if nameNode.kind == nnkPostfix:
    nameNode = nameNode[1]
  if nameNode.kind == nnkAccQuoted:
    if nameNode.len == 1 and nameNode[0].kind == nnkIdent:
      nameNode = nameNode[0]
    else:
      error("cannot expose an operator: the exposed name becomes the JS " &
            "function name neel.<name> and must be an identifier", nameNode)
  if nameNode.kind != nnkIdent:
    error("{.expose.} needs a named proc", def)
  let procName = nameNode.strVal
  if not validIdentifier(procName):
    error("cannot expose '" & procName & "': the exposed name becomes the JS " &
          "function name neel.<name> and must be an identifier", nameNode)

  if def[2].kind != nnkEmpty:
    error("cannot expose generic proc '" & procName & "': the wrapper needs " &
          "concrete parameter types to convert JSON arguments. Expose a " &
          "non-generic proc that calls it instead", nameNode)

  if def.pragma.kind != nnkEmpty:
    for p in def.pragma:
      let id = pragmaName(p)
      if id.kind != nnkIdent: continue
      if id.eqIdent("expose"):
        error("'" & procName & "' has {.expose.} twice", p)
      elif id.eqIdent("compileTime"):
        error("cannot expose '" & procName & "': a {.compileTime.} proc does " &
              "not exist at runtime", p)
      elif id.eqIdent("varargs"):
        error("cannot expose '" & procName & "': the {.varargs.} pragma " &
              "(C variadics) cannot be called with a fixed JSON argument list", p)
      elif id.eqIdent("thread"):
        error("cannot expose '" & procName & "': a {.thread.} proc is a " &
              "thread entry point, not a callable; wrap it in a plain proc", p)

  if def.body.kind == nnkEmpty:
    error("cannot expose '" & procName & "': it has no body. Put {.expose.} " &
          "on the definition, not on a forward declaration or an imported proc",
          nameNode)

  let formal = def.params
  checkReturnType(procName, formal[0])

  # Collect (name, type-or-empty, default-or-empty) per parameter, expanding
  # multi-name IdentDefs (`a, b: int`).
  type Param = tuple[name, typ, default: NimNode]
  var params: seq[Param]
  for i in 1 ..< formal.len:
    let d = formal[i]
    let typ = d[^2]
    let default = d[^1]
    if typ.kind == nnkEmpty and default.kind == nnkEmpty:
      error("cannot expose '" & procName & "': parameter '" & $d[0] &
            "' needs a type", d[0])
    for j in 0 ..< d.len - 2:
      let pname = d[j]
      if typ.kind != nnkEmpty:
        checkParamType(procName, pname, typ)
      params.add((pname, typ, default))

  var minArgs = 0
  for i, p in params:
    if p.default.kind == nnkEmpty:
      minArgs = i + 1
  let maxArgs = params.len

  # Wrapper body: arity check, one local per parameter, the call.
  let argsSym = genSym(nskParam, "args")
  var body = newStmtList()
  body.add newCall(bindSym"checkArity", newLit(procName),
                   newDotExpr(argsSym, ident"len"), newLit(minArgs), newLit(maxArgs))
  var callArgs: seq[NimNode]
  for i, p in params:
    let local = ident($p.name)
    let paramLit = newLit($p.name)
    if p.default.kind == nnkEmpty:
      # let a = convertArg(args, i, "f", "a", T)
      body.add newLetStmt(local,
        newCall(bindSym"convertArg", argsSym, newLit(i), newLit(procName),
                paramLit, p.typ))
    else:
      # var c: T = default; if args.len > i: c = convertArg(..., typeof(c))
      body.add newNimNode(nnkVarSection).add(
        newIdentDefs(local, p.typ, p.default))
      let conv = newCall(bindSym"convertArg", argsSym, newLit(i), newLit(procName),
                         paramLit, newCall(bindSym"typeof", local))
      body.add newIfStmt((
        infix(newDotExpr(argsSym, ident"len"), ">", newLit(i)),
        newStmtList(newAssignment(local, conv))))
    callArgs.add local
  let userCall = newCall(ident(procName), callArgs)
  if isVoid(formal[0]):
    body.add userCall
    body.add newCall(bindSym"newJNull")
  else:
    body.add newCall(bindSym"convertResult", userCall)

  let wrapperName = ident(procName & "NeelSym")
  let wrapper = newProc(
    name = postfix(wrapperName, "*"),
    params = [bindSym"JsonNode",
              newIdentDefs(argsSym, newNimNode(nnkBracketExpr).add(
                ident"seq", bindSym"JsonNode"))],
    body = body,
    pragmas = newNimNode(nnkPragma).add(ident"gcsafe"))
  let register = newCall(bindSym"neelRegister", newLit(procName), wrapperName)
  stamp(wrapper, nameNode)
  stamp(register, nameNode)

  result = newStmtList(def, wrapper, register)

# --- dispatch ----------------------------------------------------------------------

macro generateDispatch*(procName: untyped): untyped =
  ## Expands to
  ## `proc procName(name: string; args: seq[JsonNode]): JsonNode {.gcsafe.}`
  ## whose body is a `case name` over every exposed proc registered so far
  ## (`of "<name>": return <name>NeelSym(args)`, spliced as bound symbols so
  ## it works from a module that never imports the exposing modules) and an
  ## `else` that raises `NeelUnknownProcError`. With an empty registry every
  ## name is unknown.
  ##
  ## Two registrations with the same exposed name are a compile error at the
  ## second proc, naming both locations (names become `neel.<name>` in JS and
  ## `case` labels here). See the module header for the ordering rule.
  if procName.kind != nnkIdent:
    error("generateDispatch expects the identifier to define, e.g. " &
          "generateDispatch(neelDispatch)", procName)
  var seen = initTable[string, ExposedProc]()
  for e in exposedRegistry:
    if seen.hasKey(e.name):
      let first = seen[e.name]
      error("exposed name '" & e.name & "' is used twice: first at " &
            fmtInfo(first.info) & ", again at " & fmtInfo(e.info) &
            ". Exposed names must be unique across all modules because they " &
            "become neel.<name> in JS", e.sym)
    seen[e.name] = e

  let nameP = genSym(nskParam, "name")
  let argsP = genSym(nskParam, "args")
  var body = newStmtList()
  let unknown = newCall(bindSym"raiseUnknownProc", nameP)
  if exposedRegistry.len == 0:
    body.add unknown
  else:
    var cs = newNimNode(nnkCaseStmt).add(nameP)
    for e in exposedRegistry:
      cs.add newNimNode(nnkOfBranch).add(
        newLit(e.name),
        newStmtList(newNimNode(nnkReturnStmt).add(newCall(e.sym, argsP))))
    cs.add newNimNode(nnkElse).add(newStmtList(unknown))
    body.add cs
  result = newProc(
    name = procName,
    params = [bindSym"JsonNode",
              newIdentDefs(nameP, bindSym"string"),
              newIdentDefs(argsP, newNimNode(nnkBracketExpr).add(
                ident"seq", bindSym"JsonNode"))],
    body = body,
    pragmas = newNimNode(nnkPragma).add(ident"gcsafe"))
  stamp(result, procName)

proc handleCall*(m: Msg; dispatch: DispatchProc): Option[Msg] {.gcsafe.} =
  ## Runs the `call` message `m` through `dispatch` and builds the reply.
  ## With an id: `some(retMsg(m.id, value))` on success,
  ## `some(errMsg(m.id, e))` for any `CatchableError` (so the wire `kind` is
  ## the exception type name, e.g. `"ValueError"`, `"NeelArgumentError"`,
  ## `"NeelUnknownProcError"`; a `NeelRemoteError` from a nested `js.wait`
  ## keeps its remote kind). Without an id: runs it, drops the result, logs
  ## the exception to stderr in debug builds only, and returns `none`.
  ## Defects are not caught. `m.kind` must be `msgCall`.
  ##
  ## Task 13: this is the place to bracket with the thread-local current
  ## window - set it from the connection before calling `handleCall` in
  ## `onMessage` and clear it afterwards (or pass a `dispatch` closure that
  ## does so); nothing in this module reads or writes it.
  doAssert m.kind == msgCall, "handleCall needs a call message"
  if m.hasId:
    try:
      result = some(retMsg(m.id, dispatch(m.name, m.args)))
    except CatchableError as e:
      result = some(errMsg(m.id, e))
  else:
    try:
      discard dispatch(m.name, m.args)
    except CatchableError as e:
      when not defined(release):
        let info = errorInfo(e)
        try:
          stderr.writeLine("neel: fire-and-forget call '" & m.name &
                           "' raised " & info.kind & ": " & info.msg)
        except IOError:
          discard
    result = none(Msg)
