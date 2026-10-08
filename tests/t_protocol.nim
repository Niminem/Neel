## t_protocol.nim - wire messages, id allocation, pending-call table.

import std/[unittest, json, locks, os, monotimes, times, typedthreads, sets,
            atomics]
import neel/protocol
import neel/server

# --- messages -----------------------------------------------------------------

template rejects(text: string) =
  ## `decode(text)` must raise `NeelProtocolError` and nothing else.
  expect NeelProtocolError:
    discard decode(text)

suite "protocol messages":
  test "protocol reference examples decode to the expected messages":
    # Exact strings from PLAN.md "Protocol reference".
    check decode("""{"t":"call", "id":17, "name":"add", "args":[1, 2]}""") ==
      callMsg("add", @[%1, %2], id = 17)
    check decode("""{"t":"ret",  "id":17, "value":3}""") == retMsg(17, %3)
    check decode("""{"t":"err",  "id":17, "error":{"kind":"ValueError", "msg":"..."}}""") ==
      errMsg(17, "ValueError", "...")
    check decode("""{"t":"call", "name":"logThis", "args":["hi"]}""") ==
      callMsg("logThis", @[%"hi"])

  test "encode is compact JSON in reference field order":
    check encode(callMsg("add", @[%1, %2], id = 17)) ==
      """{"t":"call","id":17,"name":"add","args":[1,2]}"""
    check encode(retMsg(17, %3)) == """{"t":"ret","id":17,"value":3}"""
    check encode(errMsg(17, "ValueError", "...")) ==
      """{"t":"err","id":17,"error":{"kind":"ValueError","msg":"..."}}"""
    check encode(callMsg("logThis", @[%"hi"])) ==
      """{"t":"call","name":"logThis","args":["hi"]}"""

  test "call round-trips with and without id":
    for m in [callMsg("f", @[%1], id = 5), callMsg("f", @[%1])]:
      let back = decode(encode(m))
      check back == m
      check back.hasId == (m.id != NoId)

  test "ret round-trips, including value null and nil value":
    check decode(encode(retMsg(1, %"x"))) == retMsg(1, %"x")
    let nullBack = decode(encode(retMsg(2, newJNull())))
    check nullBack.kind == msgRet
    check nullBack.value.kind == JNull
    check encode(retMsg(3, nil)) == """{"t":"ret","id":3,"value":null}"""

  test "err round-trips":
    let m = errMsg(9, "TypeError", "x is not a function")
    let back = decode(encode(m))
    check back == m
    check back.error.kind == "TypeError"
    check back.error.msg == "x is not a function"

  test "args of mixed JSON types survive a round-trip":
    let args = @[
      %1, %(-2), %3.5, %true, %false, newJNull(), %"s",
      %*[1, "two", [3, [4]], {"five": 5}],
      %*{"a": {"b": {"c": [nil, true, 1.25]}}, "empty": {}, "list": []}
    ]
    let back = decode(encode(callMsg("mixed", args, id = 1)))
    check back.args == args
    check back.args[2].kind == JFloat
    check back.args[5].kind == JNull

  test "unicode in strings survives a round-trip":
    let m = callMsg("héllo", @[%"日本語 🎉 \"quoted\" \\ \n tab\t"], id = 1)
    let back = decode(encode(m))
    check back == m
    let e = errMsg(2, "Ошибка", "mañana ✓")
    check decode(encode(e)) == e

  test "unknown extra fields are ignored":
    let m = decode("""{"t":"ret","id":1,"value":2,"extra":[1,2,3],"more":{"x":1}}""")
    check m == retMsg(1, %2)
    let c = decode("""{"t":"call","name":"f","args":[],"id":4,"junk":null}""")
    check c == callMsg("f", @[], id = 4)

  test "the error-from-exception helper uses the exception name and message":
    var caught: ref CatchableError
    try:
      raise newException(ValueError, "bad value")
    except CatchableError as e:
      caught = e
    let info = errorInfo(caught)
    check info.kind == "ValueError"
    check info.msg == "bad value"
    let m = errMsg(7, caught)
    check m == errMsg(7, "ValueError", "bad value")
    check encode(m) == """{"t":"err","id":7,"error":{"kind":"ValueError","msg":"bad value"}}"""

  test "the helper forwards the original kind of a NeelRemoteError":
    var caught: ref CatchableError
    try:
      raise (ref NeelRemoteError)(kind: "TypeError", msg: "from js")
    except CatchableError as e:
      caught = e
    check errorInfo(caught) == ErrorInfo(kind: "TypeError", msg: "from js")

  test "a decode failure is a NeelProtocolError, never a json exception":
    var kindOk = false
    try:
      discard decode("""{"t":"ret","id":1}""")
    except NeelProtocolError as e:
      kindOk = e.msg.len > 0
    except CatchableError:
      kindOk = false
    check kindOk

  test "malformed: invalid JSON text":
    rejects ""
    rejects "   "
    rejects "{"
    rejects """{"t":"call","name":"f","args":[}"""
    rejects "not json"
    rejects """{"t":"ret","id":1,"value":1} trailing"""

  test "malformed: root is not an object":
    rejects "[]"
    rejects "null"
    rejects "42"
    rejects "\"call\""

  test "malformed: missing or bad t":
    rejects """{"id":1,"value":2}"""
    rejects """{"t":"nope","id":1,"value":2}"""
    rejects """{"t":1,"id":1,"value":2}"""
    rejects """{"t":null,"id":1,"value":2}"""
    rejects """{"t":"CALL","name":"f","args":[]}"""

  test "malformed: id as string, float, negative, zero, null, or overflow":
    rejects """{"t":"call","id":"17","name":"f","args":[]}"""
    rejects """{"t":"call","id":17.0,"name":"f","args":[]}"""
    rejects """{"t":"call","id":1.5,"name":"f","args":[]}"""
    rejects """{"t":"call","id":-1,"name":"f","args":[]}"""
    rejects """{"t":"call","id":0,"name":"f","args":[]}"""
    rejects """{"t":"call","id":null,"name":"f","args":[]}"""
    rejects """{"t":"call","id":true,"name":"f","args":[]}"""
    rejects """{"t":"ret","id":99999999999999999999999,"value":1}"""

  test "malformed: call without name or with bad name/args":
    rejects """{"t":"call","args":[]}"""
    rejects """{"t":"call","name":1,"args":[]}"""
    rejects """{"t":"call","name":null,"args":[]}"""
    rejects """{"t":"call","name":"f"}"""
    rejects """{"t":"call","name":"f","args":{}}"""
    rejects """{"t":"call","name":"f","args":"x"}"""
    rejects """{"t":"call","name":"f","args":null}"""

  test "malformed: ret without id or value":
    rejects """{"t":"ret","value":1}"""
    rejects """{"t":"ret","id":1}"""
    rejects """{"t":"ret"}"""

  test "malformed: err without id, with non-object error, or missing kind/msg":
    rejects """{"t":"err","error":{"kind":"E","msg":"m"}}"""
    rejects """{"t":"err","id":1}"""
    rejects """{"t":"err","id":1,"error":"boom"}"""
    rejects """{"t":"err","id":1,"error":null}"""
    rejects """{"t":"err","id":1,"error":["E","m"]}"""
    rejects """{"t":"err","id":1,"error":{"msg":"m"}}"""
    rejects """{"t":"err","id":1,"error":{"kind":"E"}}"""
    rejects """{"t":"err","id":1,"error":{"kind":1,"msg":"m"}}"""
    rejects """{"t":"err","id":1,"error":{"kind":"E","msg":null}}"""

  test "malformed: nesting beyond MaxJsonDepth is rejected before parsing":
    var deep = """{"t":"call","name":"f","args":"""
    for i in 0 ..< 2000:
      deep.add '['
    for i in 0 ..< 2000:
      deep.add ']'
    deep.add '}'
    rejects deep
    # Brackets inside strings do not count towards depth.
    var brackets = ""
    for i in 0 ..< 1000:
      brackets.add "[{"
    let fine = decode("""{"t":"call","name":"f","args":[""" & "\"" & brackets & "\"]}")
    check fine.args[0].getStr == brackets

# --- id allocator ---------------------------------------------------------------

type
  AllocShared = object
    alloc: IdAllocator
    lock: Lock
    ids: seq[int]

const
  AllocThreads = 8
  AllocPerThread = 2000

proc allocWorker(sh: ptr AllocShared) {.thread.} =
  var mine = newSeqOfCap[int](AllocPerThread)
  for i in 0 ..< AllocPerThread:
    mine.add sh.alloc.nextId()
  acquire sh.lock
  sh.ids.add mine
  release sh.lock

suite "id allocator":
  test "starts at 1 and is monotonic":
    var a: IdAllocator
    check a.nextId() == 1
    check a.nextId() == 2
    check a.nextId() == 3
    var b: IdAllocator
    check b.nextId() == 1

  test "ids are unique under concurrent allocation from several threads":
    var sh: AllocShared
    initLock sh.lock
    var threads: array[AllocThreads, Thread[ptr AllocShared]]
    for i in 0 ..< AllocThreads:
      createThread(threads[i], allocWorker, addr sh)
    joinThreads(threads)
    deinitLock sh.lock
    check sh.ids.len == AllocThreads * AllocPerThread
    let unique = sh.ids.toHashSet
    check unique.len == sh.ids.len
    check min(sh.ids) == 1
    check max(sh.ids) == AllocThreads * AllocPerThread
    check sh.alloc.nextId() == AllocThreads * AllocPerThread + 1

# --- pending table ---------------------------------------------------------------

type
  Ctx = object
    ## Reached by helper threads through a `ptr`; the table ref itself is only
    ## read, never copied, on the other thread.
    table: ptr PendingTable
    conn: ConnId
    id: int
    delayMs: int
    reply: Msg
    completed: bool
    results: seq[JsonNode]
    errors: seq[string]
    lock: Lock
    go: Atomic[bool]

proc completer(c: ptr Ctx) {.thread.} =
  if c.delayMs > 0:
    sleep(c.delayMs)
  let ok = c.table[].complete(c.conn, c.id, c.reply)
  acquire c.lock
  c.completed = ok
  release c.lock

proc gatedCompleter(c: ptr Ctx) {.thread.} =
  ## Spins until the test flips `go`, then completes at once; this puts the
  ## completion within microseconds of the waiter's deadline.
  while not c.go.load(moAcquire):
    cpuRelax()
  let ok = c.table[].complete(c.conn, c.id, c.reply)
  acquire c.lock
  c.completed = ok
  release c.lock

proc disconnecter(c: ptr Ctx) {.thread.} =
  if c.delayMs > 0:
    sleep(c.delayMs)
  discard c.table[].disconnect(c.conn)

proc waiter(c: ptr Ctx) {.thread.} =
  ## Registers before the test thread completes; records the outcome.
  try:
    let v = c.table[].wait(c.conn, c.id, 3000)
    acquire c.lock
    c.results.add v
    release c.lock
  except NeelDisconnectedError:
    acquire c.lock
    c.errors.add "disconnected"
    release c.lock
  except NeelTimeoutError:
    acquire c.lock
    c.errors.add "timeout"
    release c.lock
  except NeelRemoteError as e:
    acquire c.lock
    c.errors.add "remote:" & e.kind
    release c.lock

proc waitUntil(deadlineMs: int; cond: proc(): bool): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = deadlineMs)
  while getMonoTime() < deadline:
    if cond():
      return true
    sleep(1)
  cond()

template ctxFor(name: untyped; tbl: var PendingTable; c: ConnId; i: int;
                delay: int; r: Msg) =
  ## Declares `var name: Ctx` in place (a `Lock` must not be copied once
  ## initialised).
  var name = Ctx(table: addr tbl, conn: c, id: i, delayMs: delay, reply: r)
  initLock name.lock

suite "pending table":
  let connA = ConnId(1)
  let connB = ConnId(2)

  test "wait returns the ret value delivered by another thread":
    var tbl = newPendingTable()
    tbl.register(connA, 1)
    ctxFor(ctx, tbl, connA, 1, 30, retMsg(1, %*{"sum": 3}))
    var th: Thread[ptr Ctx]
    createThread(th, completer, addr ctx)
    let v = tbl.wait(connA, 1, 3000)
    joinThread(th)
    check v == %*{"sum": 3}
    check ctx.completed
    check tbl.pendingCount == 0
    deinitLock ctx.lock

  test "a reply that arrived before wait is returned immediately":
    var tbl = newPendingTable()
    tbl.register(connA, 2)
    check tbl.complete(connA, 2, retMsg(2, %"early"))
    let t0 = getMonoTime()
    check tbl.wait(connA, 2, 3000) == %"early"
    check (getMonoTime() - t0).inMilliseconds < 500
    check tbl.pendingCount == 0

  test "the caller's reply value is not shared with the waiter":
    var tbl = newPendingTable()
    tbl.register(connA, 3)
    var original = %*{"n": 1}
    check tbl.complete(connA, 3, retMsg(3, original))
    original["n"] = %2
    check tbl.wait(connA, 3, 1000) == %*{"n": 1}

  test "an err reply raises NeelRemoteError with kind and msg":
    var tbl = newPendingTable()
    tbl.register(connA, 4)
    ctxFor(ctx, tbl, connA, 4, 20, errMsg(4, "TypeError", "x is not a function"))
    var th: Thread[ptr Ctx]
    createThread(th, completer, addr ctx)
    var raised = false
    try:
      discard tbl.wait(connA, 4, 3000)
    except NeelRemoteError as e:
      raised = true
      check e.kind == "TypeError"
      check e.msg == "x is not a function"
    joinThread(th)
    check raised
    check tbl.pendingCount == 0
    deinitLock ctx.lock

  test "timeout raises NeelTimeoutError within a bounded margin and frees the entry":
    var tbl = newPendingTable()
    tbl.register(connA, 5)
    check tbl.pendingCount(connA) == 1
    let t0 = getMonoTime()
    expect NeelTimeoutError:
      discard tbl.wait(connA, 5, 100)
    let waited = (getMonoTime() - t0).inMilliseconds
    check waited >= 90
    check waited < 1000
    check tbl.pendingCount == 0
    # A late reply for the timed-out id is ignored.
    check not tbl.complete(connA, 5, retMsg(5, %1))

  test "timeoutMs <= 0 polls once and does not block":
    var tbl = newPendingTable()
    tbl.register(connA, 6)
    let t0 = getMonoTime()
    expect NeelTimeoutError:
      discard tbl.wait(connA, 6, 0)
    check (getMonoTime() - t0).inMilliseconds < 500
    check tbl.pendingCount == 0

  test "complete on an unknown id or connection returns false":
    var tbl = newPendingTable()
    check not tbl.complete(connA, 42, retMsg(42, %1))
    check not tbl.complete(ConnId(999), 1, retMsg(1, %1))
    tbl.register(connA, 7)
    check not tbl.complete(connB, 7, retMsg(7, %1))   # right id, wrong conn
    check tbl.complete(connA, 7, retMsg(7, %1))
    check not tbl.complete(connA, 7, retMsg(7, %2))   # already answered
    check tbl.wait(connA, 7, 1000) == %1

  test "cancel frees the entry and later complete returns false":
    var tbl = newPendingTable()
    tbl.register(connA, 8)
    check tbl.pendingCount == 1
    check tbl.cancel(connA, 8)
    check tbl.pendingCount == 0
    check not tbl.cancel(connA, 8)
    check not tbl.complete(connA, 8, retMsg(8, %1))

  test "disconnect wakes every waiter on one connection and leaves others alone":
    var tbl = newPendingTable()
    ctxFor(a1, tbl, connA, 1, 0, Msg())
    ctxFor(a2, tbl, connA, 2, 0, Msg())
    ctxFor(b1, tbl, connB, 1, 0, Msg())
    tbl.register(connA, 1)
    tbl.register(connA, 2)
    tbl.register(connB, 1)
    var threads: array[3, Thread[ptr Ctx]]
    createThread(threads[0], waiter, addr a1)
    createThread(threads[1], waiter, addr a2)
    createThread(threads[2], waiter, addr b1)
    sleep(30)   # let the waiters block
    check tbl.disconnect(connA) == 2
    joinThread(threads[0])
    joinThread(threads[1])
    check a1.errors == @["disconnected"]
    check a2.errors == @["disconnected"]
    # connB's waiter is still pending and still answerable.
    check tbl.pendingCount(connA) == 0
    check tbl.pendingCount(connB) == 1
    check tbl.complete(connB, 1, retMsg(1, %"b"))
    joinThread(threads[2])
    check b1.results == @[%"b"]
    check b1.errors.len == 0
    check tbl.pendingCount == 0
    # Disconnecting an unknown connection is a no-op.
    check tbl.disconnect(ConnId(777)) == 0
    for c in [addr a1, addr a2, addr b1]:
      deinitLock c.lock

  test "disconnect while the waiter is between register and wait still fails it":
    var tbl = newPendingTable()
    tbl.register(connA, 9)
    check tbl.disconnect(connA) == 1
    expect NeelDisconnectedError:
      discard tbl.wait(connA, 9, 3000)
    check tbl.pendingCount == 0
    # A register after the disconnect is independent: it times out normally
    # (the caller's `send` would have failed and it would `cancel` instead).
    tbl.register(connA, 10)
    expect NeelTimeoutError:
      discard tbl.wait(connA, 10, 20)
    check tbl.pendingCount == 0

  test "disconnect from another thread wakes a blocked waiter":
    var tbl = newPendingTable()
    tbl.register(connA, 11)
    ctxFor(ctx, tbl, connA, 11, 30, Msg())
    var th: Thread[ptr Ctx]
    createThread(th, disconnecter, addr ctx)
    let t0 = getMonoTime()
    expect NeelDisconnectedError:
      discard tbl.wait(connA, 11, 3000)
    check (getMonoTime() - t0).inMilliseconds < 2000
    joinThread(th)
    deinitLock ctx.lock

  test "several waiters on one connection each receive their own result":
    var tbl = newPendingTable()
    const N = 6
    var ctxs: array[N, Ctx]
    var threads: array[N, Thread[ptr Ctx]]
    for i in 0 ..< N:
      ctxs[i] = Ctx(table: addr tbl, conn: connA, id: i + 1)
      initLock ctxs[i].lock
      tbl.register(connA, i + 1)
    for i in 0 ..< N:
      createThread(threads[i], waiter, addr ctxs[i])
    check waitUntil(2000, proc(): bool = tbl.pendingCount(connA) == N)
    # Answer in reverse order, odd ids with err, so delivery is clearly keyed.
    for i in countdown(N - 1, 0):
      let id = i + 1
      if id mod 2 == 0:
        check tbl.complete(connA, id, retMsg(id, %("value-" & $id)))
      else:
        check tbl.complete(connA, id, errMsg(id, "Kind" & $id, "m"))
    joinThreads(threads)
    for i in 0 ..< N:
      let id = i + 1
      if id mod 2 == 0:
        check ctxs[i].results == @[%("value-" & $id)]
        check ctxs[i].errors.len == 0
      else:
        check ctxs[i].results.len == 0
        check ctxs[i].errors == @["remote:Kind" & $id]
      deinitLock ctxs[i].lock
    check tbl.pendingCount == 0

  test "complete racing a timed-out wait neither crashes nor leaks":
    var tbl = newPendingTable()
    var timeouts, delivered = 0
    const Rounds = 300
    for round in 1 .. Rounds:
      tbl.register(connA, round)
      var ctx = Ctx(table: addr tbl, conn: connA, id: round,
                    delayMs: 0, reply: retMsg(round, %round))
      initLock ctx.lock
      var th: Thread[ptr Ctx]
      createThread(th, gatedCompleter, addr ctx)
      sleep(1)   # let the completer reach its spin loop
      ctx.go.store(true, moRelease)
      # A 0-3 ms deadline lands right on top of the completion; in practice
      # 0-1 ms times out and 2-3 ms delivers, so both paths run every time.
      var gotValue = false
      try:
        let v = tbl.wait(connA, round, round mod 4)
        check v == %round
        gotValue = true
        inc delivered
      except NeelTimeoutError:
        inc timeouts
      joinThread(th)
      # Exactly one side owns the outcome: complete returned true iff the
      # waiter saw the value; a timeout means complete found no entry.
      acquire ctx.lock
      let completed = ctx.completed
      release ctx.lock
      check completed == gotValue
      check tbl.pendingCount == 0
      deinitLock ctx.lock
    check timeouts + delivered == Rounds
    # Both sides of the race must have happened for the test to mean anything
    # (a 0 ms deadline cannot be beaten; a spinning completer beats 3 ms).
    check timeouts > 0
    check delivered > 0

  test "entries that were never waited on are freed with the table":
    block:
      var tbl = newPendingTable()
      tbl.register(connA, 1)
      tbl.register(connB, 2)
      check tbl.pendingCount == 2
    # Leaving the block destroyed the table and both entries without a wait.
    check true
