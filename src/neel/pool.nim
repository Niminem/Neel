## pool.nim - bounded task queue and worker thread pool.
##
## Everything that may block, parse large input, or run user code is handed to
## this pool so the IO thread in `server.nim` never stalls. Built on
## `std/typedthreads` and `std/locks`; `std/threadpool` and `spawn` are not
## used anywhere in Neel.
##
## Surface:
## - `Pool`: N worker threads (default `DefaultWorkers`) sharing one bounded
##   FIFO queue of `std/tasks.Task` values. Build a task with `toTask f(a, b)`;
##   `f` must be a `{.gcsafe.}` non-closure proc and every argument must pass
##   `isolate`, which is exactly what makes a task safe to move to another
##   thread under ORC: the arguments are copied into a `allocShared` block
##   owned by the task, there is no closure environment and no shared `ref`
##   whose refcount two threads could touch. `ptr`, `int`, `string`, `seq` and
##   plain objects of those all qualify.
## - `submit` blocks with back-pressure while the queue is full, for at most
##   `timeoutMs`; `trySubmit` never blocks and leaves the task with the caller
##   on failure so it can be retried later.
## - `stop(drain)` either finishes the queued work or discards it, then joins
##   every worker. It is idempotent and wakes workers blocked on an empty queue.
## - `waitTimeout`: a timed condition-variable wait that `std/locks` lacks;
##   exported because `protocol.nim`'s pending-call table needs the same thing.
##
## Every public proc is usable from `{.gcsafe.}` code: `Pool` is a `ref` to a
## one-field object whose only field points at shared memory, and no proc here
## touches a GC'd global.

import std/[locks, tasks, typedthreads, monotimes, times]

when defined(windows):
  proc sleepConditionVariableCS(cond: var Cond; lock: var Lock;
                                dwMilliseconds: int32): int32
    {.stdcall, dynlib: "kernel32", importc: "SleepConditionVariableCS".}
else:
  import std/posix

  proc pthreadCondTimedwait(cond: var Cond; lock: var Lock;
                            abstime: var Timespec): cint
    {.importc: "pthread_cond_timedwait", header: "<pthread.h>".}

const
  DefaultWorkers* = 64
    ## Default number of worker threads.
  DefaultQueueCapacity* = 1024
    ## Default number of tasks that may wait in the queue before `submit`
    ## blocks.
  DefaultSubmitTimeoutMs* = 5000
    ## Default upper bound on how long `submit` waits for a free slot.
  IdleWaitMs = 1000
    ## Period at which idle workers re-check the stop flag; `stop` also wakes
    ## them explicitly, this is only a safety net.

type
  PoolImpl = object
    ## Shared state, allocated with `allocShared0` so every thread can hold a
    ## raw pointer to it. All fields below the lock are guarded by it.
    lock: Lock
    notEmpty: Cond      # signalled when a task is queued or stop is requested
    notFull: Cond       # signalled when a task is dequeued or stop is requested
    queue: seq[Task]    # ring buffer of fixed capacity
    head: int           # index of the oldest queued task
    count: int          # number of queued tasks
    running: int        # tasks currently executing
    stopping: bool      # no new submissions; workers exit once the queue is empty
    joined: bool        # every worker has been joined
    joining: bool       # a `stop` call is currently joining
    workers: seq[Thread[ptr PoolImpl]]

  PoolObj = object
    impl: ptr PoolImpl

  Pool* = ref PoolObj
    ## Handle to a worker pool. Dropping the last reference without calling
    ## `stop` performs `stop(drain = false)`; call `stop` explicitly for
    ## deterministic shutdown.

var currentPool {.threadvar.}: ptr PoolImpl
  ## Set on worker threads so `stop` can refuse to join the calling thread.

# --- timed condition wait ------------------------------------------------------

proc waitTimeout*(cond: var Cond; lock: var Lock; timeoutMs: int): bool =
  ## Waits on `cond` for at most `timeoutMs` milliseconds. `lock` must be held
  ## and is held again on return. Returns `false` when the wait timed out and
  ## `true` when the condition was signalled; spurious wake-ups are possible,
  ## so callers re-check their predicate in a loop either way.
  when defined(windows):
    sleepConditionVariableCS(cond, lock, int32(max(timeoutMs, 0))) != 0
  else:
    var ts: Timespec
    discard clock_gettime(CLOCK_REALTIME, ts)
    let ms = max(timeoutMs, 0)
    let nsec = ts.tv_nsec.int64 + (ms mod 1000) * 1_000_000
    ts.tv_sec = posix.Time(ts.tv_sec.int64 + ms div 1000 + nsec div 1_000_000_000)
    ts.tv_nsec = int(nsec mod 1_000_000_000)
    pthreadCondTimedwait(cond, lock, ts) == 0

# --- workers -------------------------------------------------------------------

proc workerLoop(p: ptr PoolImpl) {.thread.} =
  currentPool = p
  while true:
    var task: Task
    acquire p.lock
    while p.count == 0 and not p.stopping:
      discard waitTimeout(p.notEmpty, p.lock, IdleWaitMs)
    if p.count == 0:
      # Stopping with nothing left to run (a non-draining stop has already
      # emptied the queue).
      release p.lock
      break
    task = move p.queue[p.head]
    p.head = (p.head + 1) mod p.queue.len
    dec p.count
    inc p.running
    signal p.notFull
    release p.lock
    try:
      task.invoke()
    except CatchableError:
      # A task that lets an exception escape must not take the worker down.
      discard
    acquire p.lock
    dec p.running
    release p.lock

# --- lifecycle ----------------------------------------------------------------

proc stopImpl(p: ptr PoolImpl; drain: bool) =
  doAssert currentPool != p, "Pool.stop must not be called from one of its own workers"
  acquire p.lock
  if p.joined:
    release p.lock
    return
  p.stopping = true
  if not drain:
    # Discard everything queued; each slot's destructor frees the task's
    # argument block.
    for i in 0 ..< p.queue.len:
      p.queue[i] = Task()
    p.head = 0
    p.count = 0
  broadcast p.notEmpty
  broadcast p.notFull
  let mustJoin = not p.joining
  p.joining = true
  release p.lock
  if mustJoin:
    joinThreads(p.workers)
    acquire p.lock
    p.joined = true
    release p.lock

proc `=destroy`(p: PoolObj) =
  if p.impl != nil:
    stopImpl(p.impl, drain = false)
    deinitLock p.impl.lock
    deinitCond p.impl.notEmpty
    deinitCond p.impl.notFull
    `=destroy`(p.impl[])
    deallocShared(p.impl)

proc newPool*(workers = DefaultWorkers; queueCapacity = DefaultQueueCapacity): Pool =
  ## Starts `workers` threads sharing a queue that holds at most
  ## `queueCapacity` waiting tasks. Both must be at least 1.
  doAssert workers >= 1, "a pool needs at least one worker"
  doAssert queueCapacity >= 1, "the queue needs room for at least one task"
  let impl = cast[ptr PoolImpl](allocShared0(sizeof(PoolImpl)))
  initLock impl.lock
  initCond impl.notEmpty
  initCond impl.notFull
  impl.queue = newSeq[Task](queueCapacity)
  impl.workers = newSeq[Thread[ptr PoolImpl]](workers)
  for i in 0 ..< workers:
    createThread(impl.workers[i], workerLoop, impl)
  result = Pool(impl: impl)

proc stop*(p: Pool; drain = true) =
  ## Stops accepting tasks, then joins every worker. With `drain = true` the
  ## tasks already queued run first; with `drain = false` they are discarded
  ## (in-flight tasks always finish). Idempotent: later calls return at once.
  ## Must not be called from a worker thread (it would join itself); Neel
  ## shuts down from the main thread.
  stopImpl(p.impl, drain)

# --- submission ----------------------------------------------------------------

proc trySubmit*(p: Pool; task: var Task): bool =
  ## Queues `task` if a slot is free right now, moving it out of `task`.
  ## Returns `false` without blocking when the queue is full or the pool is
  ## stopping; `task` is then left untouched so the caller can retry.
  let impl = p.impl
  acquire impl.lock
  if impl.stopping or impl.count == impl.queue.len:
    release impl.lock
    return false
  impl.queue[(impl.head + impl.count) mod impl.queue.len] = move task
  inc impl.count
  signal impl.notEmpty
  release impl.lock
  true

proc submit*(p: Pool; task: sink Task; timeoutMs = DefaultSubmitTimeoutMs): bool =
  ## Queues `task`, waiting up to `timeoutMs` milliseconds (>= 0) for a free
  ## slot when the queue is full. Returns `false`, and destroys the task,
  ## when the pool is stopping or stopped or when no slot freed up in time.
  ## Never blocks the caller beyond the deadline.
  doAssert timeoutMs >= 0, "submit needs a non-negative timeout"
  let impl = p.impl
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  acquire impl.lock
  while impl.count == impl.queue.len and not impl.stopping:
    let remaining = (deadline - getMonoTime()).inMilliseconds
    if remaining <= 0:
      break
    discard waitTimeout(impl.notFull, impl.lock, int(remaining))
  if impl.stopping or impl.count == impl.queue.len:
    release impl.lock
    return false
  impl.queue[(impl.head + impl.count) mod impl.queue.len] = move task
  inc impl.count
  signal impl.notEmpty
  release impl.lock
  true

# --- introspection -------------------------------------------------------------

proc workerCount*(p: Pool): int =
  ## Number of worker threads the pool was created with.
  p.impl.workers.len

proc capacity*(p: Pool): int =
  ## Maximum number of tasks that can wait in the queue.
  p.impl.queue.len

proc queued*(p: Pool): int =
  ## Number of tasks waiting to be picked up (not counting running ones).
  acquire p.impl.lock
  result = p.impl.count
  release p.impl.lock

proc running*(p: Pool): int =
  ## Number of tasks currently executing on workers.
  acquire p.impl.lock
  result = p.impl.running
  release p.impl.lock

proc isStopped*(p: Pool): bool =
  ## Whether `stop` has completed and every worker thread has been joined.
  acquire p.impl.lock
  result = p.impl.joined
  release p.impl.lock
