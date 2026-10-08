## t_pool.nim - worker pool: completion, back-pressure, drain/discard, stop.

import std/[unittest, tasks, locks, os, monotimes, times]
import neel/pool

type
  Shared = object
    ## Test-side state reached from tasks through a `ptr` (tasks must not
    ## touch GC'd globals).
    lock: Lock
    count: int
    threads: seq[int]
    gate: bool
    gateWaiters: int

proc waitUntil(deadlineMs: int; cond: proc(): bool): bool =
  ## Polls `cond` for up to `deadlineMs`; never hangs the suite.
  let deadline = getMonoTime() + initDuration(milliseconds = deadlineMs)
  while getMonoTime() < deadline:
    if cond():
      return true
    sleep(1)
  cond()

proc bump(sh: ptr Shared) {.gcsafe.} =
  acquire sh.lock
  inc sh.count
  sh.threads.add getThreadId()
  release sh.lock

proc bumpBy(sh: ptr Shared; n: int; tag: string) {.gcsafe.} =
  doAssert tag == "tag"
  acquire sh.lock
  sh.count += n
  release sh.lock

proc waitGate(sh: ptr Shared) {.gcsafe.} =
  ## Blocks a worker until the test opens the gate (bounded at 5 s).
  acquire sh.lock
  inc sh.gateWaiters
  release sh.lock
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while getMonoTime() < deadline:
    acquire sh.lock
    let open = sh.gate
    release sh.lock
    if open:
      break
    sleep(1)
  bump(sh)

proc openGate(sh: ptr Shared) =
  acquire sh.lock
  sh.gate = true
  release sh.lock

proc counted(sh: ptr Shared): int =
  acquire sh.lock
  result = sh.count
  release sh.lock

proc napThenBump(sh: ptr Shared; ms: int) {.gcsafe.} =
  sleep(ms)
  bump(sh)

template poolTest(name: string; body: untyped) =
  test name:
    var sh {.inject.}: Shared
    initLock sh.lock
    let shp {.inject.} = addr sh
    try:
      body
    finally:
      deinitLock sh.lock

suite "pool":
  poolTest "tasks run on worker threads and all complete":
    let p = newPool(workers = 4, queueCapacity = 64)
    try:
      for i in 0 ..< 50:
        check p.submit(toTask bump(shp))
      check waitUntil(3000, proc(): bool = counted(shp) == 50)
      check counted(shp) == 50
      acquire sh.lock
      let threads = sh.threads
      release sh.lock
      check threads.len == 50
      for t in threads:
        check t != getThreadId()
    finally:
      p.stop()
    check p.isStopped
    check p.workerCount == 4
    check p.capacity == 64

  poolTest "isolated arguments are copied into the task":
    let p = newPool(workers = 2, queueCapacity = 8)
    try:
      var tag = "tag"
      check p.submit(toTask bumpBy(shp, 5, tag))
      tag = "mutated after submit"
      check waitUntil(2000, proc(): bool = counted(shp) == 5)
    finally:
      p.stop()

  poolTest "back-pressure: submit blocks while the queue is full, then times out":
    let p = newPool(workers = 1, queueCapacity = 2)
    try:
      check p.submit(toTask waitGate(shp))       # occupies the worker
      check waitUntil(2000, proc(): bool =
        acquire shp.lock
        result = shp.gateWaiters == 1
        release shp.lock)
      check p.submit(toTask bump(shp))           # queue slot 1
      check p.submit(toTask bump(shp))           # queue slot 2
      check p.queued == 2
      var extra = toTask bump(shp)
      check not p.trySubmit(extra)               # full, non-blocking
      let t0 = getMonoTime()
      check not p.submit(toTask bump(shp), timeoutMs = 150)
      let waited = (getMonoTime() - t0).inMilliseconds
      check waited >= 140
      check waited < 2000
      openGate(shp)
      check waitUntil(3000, proc(): bool = counted(shp) == 3)
      check p.trySubmit(extra)                   # room again
      check waitUntil(2000, proc(): bool = counted(shp) == 4)
    finally:
      p.stop()

  poolTest "stop(drain = true) runs everything queued":
    let p = newPool(workers = 1, queueCapacity = 32)
    for i in 0 ..< 10:
      check p.submit(toTask napThenBump(shp, 5))
    p.stop(drain = true)
    check counted(shp) == 10
    check p.queued == 0
    check p.isStopped

  poolTest "stop(drain = false) discards queued tasks but finishes the running one":
    let p = newPool(workers = 1, queueCapacity = 32)
    check p.submit(toTask napThenBump(shp, 150))
    check waitUntil(2000, proc(): bool = p.running == 1)
    for i in 0 ..< 10:
      check p.submit(toTask bump(shp))
    check p.queued == 10
    p.stop(drain = false)
    check counted(shp) == 1
    check p.queued == 0
    check p.isStopped

  poolTest "double stop is safe":
    let p = newPool(workers = 2, queueCapacity = 4)
    p.stop()
    p.stop()
    p.stop(drain = false)
    check p.isStopped

  poolTest "submit after stop fails cleanly and runs nothing":
    let p = newPool(workers = 2, queueCapacity = 4)
    p.stop()
    check not p.submit(toTask bump(shp))
    check not p.submit(toTask bump(shp), timeoutMs = 0)
    var t = toTask bump(shp)
    check not p.trySubmit(t)
    sleep(20)
    check counted(shp) == 0

  poolTest "a task that raises does not kill its worker":
    proc boom(sh: ptr Shared) {.gcsafe.} =
      bump(sh)
      raise newException(ValueError, "boom")
    let p = newPool(workers = 1, queueCapacity = 8)
    try:
      check p.submit(toTask boom(shp))
      check p.submit(toTask bump(shp))
      check waitUntil(2000, proc(): bool = counted(shp) == 2)
    finally:
      p.stop()

  poolTest "dropping the handle without stop joins the workers":
    block:
      let p = newPool(workers = 2, queueCapacity = 4)
      check p.submit(toTask bump(shp))
      check waitUntil(2000, proc(): bool = counted(shp) == 1)
    # Leaving the block destroyed `p`; reaching here means the destructor's
    # stop returned rather than deadlocking on idle workers.
    check counted(shp) == 1

suite "waitTimeout":
  test "times out without a signal and returns false":
    var lock: Lock
    var cond: Cond
    initLock lock
    initCond cond
    acquire lock
    let t0 = getMonoTime()
    let signalled = waitTimeout(cond, lock, 60)
    let waited = (getMonoTime() - t0).inMilliseconds
    release lock
    check not signalled
    check waited >= 50
    check waited < 1000
    deinitCond cond
    deinitLock lock
