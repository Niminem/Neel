## exposed_helper.nim - fixture for t_expose: exposed procs living in a module
## other than the one that calls `generateDispatch`. Not a test file (the name
## does not start with `t`, so `nimble test` does not run it).

import neel/expose

proc helperMul*(a, b: int): int {.expose.} =
  ## Exported so the test can also call it directly.
  a * b

proc helperSecret(): string {.expose.} =
  ## Deliberately not exported: dispatch must still reach it through the
  ## registered symbol.
  "reached through the registry"
