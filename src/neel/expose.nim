## expose.nim - the `{.expose.}` pragma, compile-time registry, and dispatch
## generation.
##
## `expose` is applied to top-level procs. It validates the signature (no
## nested procs, no generics, supported parameter forms including multi-name
## `IdentDefs` and default values) and emits an exported wrapper
## `<name>NeelSym*(args: seq[JsonNode]): JsonNode {.gcsafe.}` that checks arity,
## converts each argument with `fromJson`, calls the user proc, and returns
## `toJson` of the result (or `null` for void). It then emits
## `neelRegister("name", <name>NeelSym)`, a `typed` macro that stores the bound
## `nnkSym` in a `{.compileTime.}` registry.
##
## The dispatch generator consumed by `startApp` splices those symbols into a
## `case name` statement, routes exceptions into `err` messages, and answers
## unknown names with a structured error. Cross-module behavior depends on the
## Task 2 spike results.
##
## Implemented in Task 8.
