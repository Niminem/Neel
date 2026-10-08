## js.nim - the `js` proxy for calling browser-side functions from Nim.
##
## `js.foo(args...)` uses experimental dot operators to send a fire-and-forget
## `call` and returns a discardable handle. `.wait(timeoutMs = default)` on
## that handle sends with an id, blocks on the pending table in
## `protocol.nim`, and returns the `JsonNode` result; a generic `.wait[T]`
## returns `fromJson(T)`. `js.foo` targets the window whose exposed proc is
## currently running (thread-local, set by the dispatcher); `win.js.foo`
## targets an explicit window. With no connected window `NeelNoWindowError`
## is raised.
##
## Whether `{.experimental: "dotOperators".}` must also be enabled in the
## user's module is settled by the Task 2 spike. Implemented in Task 9.
