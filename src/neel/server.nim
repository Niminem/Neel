## server.nim - single-threaded `std/selectors` IO loop and per-connection
## state machine (HTTP -> WebSocket upgrade -> WebSocket -> closing).
##
## Owns every socket. Reads are parsed with `http.nim` and `websocket.nim`,
## anything that can wait or runs user code is dispatched to `pool.nim`, and
## outbound data is queued per connection under a `Lock` and drained on
## writable events. The IO thread itself never blocks: it parses, dispatches,
## and shovels bytes.
##
## Surface:
## - `newServer(hooks..., workers, queueCapacity, maxMessageSize)`,
##   `listen(server, port = 0)` (binds `127.0.0.1` only; `port` is readable
##   afterwards), `shutdown(server)` (idempotent, joins every thread).
## - Hooks, all run on pool workers and all `{.gcsafe.}`:
##   `RequestHandler = proc(conn, req): RequestAction` answers a request with
##   `respond(response)` or asks for a WebSocket upgrade with `upgrade()`;
##   `MessageHandler = proc(conn, message)` receives complete text messages;
##   `ConnectionHandler = proc(conn)` for `onOpen` (after a successful
##   upgrade) and `onClose` (exactly once per upgraded connection).
## - `send(server, conn, text)` queues a text frame from any thread;
##   `close(server, conn, code, reason)` starts the closing handshake.
## - `isWebSocketUpgrade(req)` so a handler can check before saying `upgrade()`.
##
## Threading: the IO thread owns the sockets, parsers, and receive buffers.
## Workers reach a connection only through its `ConnId` and the server lock,
## which guards the id table, each connection's outbound queue, and the
## "pending action" list the IO thread applies after a wake-up. Connection
## objects are `ptr`s allocated with `allocShared0`, so no refcount is ever
## touched from two threads.

when defined(windows):
  # The Windows `select` backend is capped at FD_SETSIZE handles and the
  # header defaults it to 64 (about 8 browser windows). `-d:FD_SETSIZE` has
  # no effect; the C macro must be set (PLAN.md spike (c)).
  {.passC: "-DFD_SETSIZE=1024".}

import std/[selectors, nativesockets, locks, tables, hashes, monotimes, times,
            tasks, typedthreads, oserrors, strutils]
import ./[http, websocket, sha1, pool]

const
  UseWinSockets = defined(windows) or defined(nimdoc)
    ## `std/nativesockets` exposes its Windows API shape (winlean `recv` /
    ## `send`, no POSIX errno re-exports) under `nim doc` as well, so the doc
    ## build follows the Windows branches below. Never true in a real build
    ## on a POSIX host.

when UseWinSockets:
  from std/winlean import TCP_NODELAY, WSAEWOULDBLOCK
else:
  # `nativesockets` already re-exports EAGAIN/EWOULDBLOCK/EINTR/MSG_NOSIGNAL
  # (and SO_NOSIGPIPE on macOS); a full `import std/posix` would clash with
  # its socket helpers.
  from std/posix import RLimit, getrlimit, setrlimit, RLIMIT_NOFILE, TCP_NODELAY

const
  DefaultCloseTimeoutMs* = 2000
    ## How long a closing connection may take to flush its last bytes or to
    ## receive the peer's close reply before the socket is dropped.
  LifecycleSubmitTimeoutMs = 1000
    ## Bound on the IO thread's wait when queueing `onOpen`/`onClose`; these
    ## are rare and must not be lost under a momentarily full queue.
  StallRetryMs = 10
    ## Retry period for a connection whose task could not be queued because
    ## the pool queue was full (the connection is not read meanwhile).
  IoTickMs = 250
    ## Upper bound on one `selectInto` wait so stop requests and deadlines
    ## are noticed promptly even without socket activity.
  ReadChunk = 64 * 1024
    ## Bytes read per readable event.
  Backlog = 128

type
  ConnId* = distinct int
    ## Identity of one accepted connection, unique for the server's lifetime
    ## (never reused, unlike file descriptors).

  RequestActionKind* = enum
    ## What a request handler asks the server to do.
    raRespond  ## Send `response` and stay in HTTP mode (or close, per keep-alive).
    raUpgrade  ## Complete the WebSocket handshake for this request.

  RequestAction* = object
    ## What a `RequestHandler` wants done with a request. Build with
    ## `respond` or `upgrade`.
    case kind*: RequestActionKind ## Respond or upgrade.
    of raRespond:
      response*: HttpResponse ## The response to encode and send.
    of raUpgrade:
      discard

  RequestHandler* = proc(conn: ConnId; req: HttpRequest): RequestAction {.gcsafe.}
    ## Runs on a pool worker for every complete request. Exceptions become
    ## a 500 response. Returning `upgrade()` for a request that is not a
    ## valid WebSocket upgrade (see `isWebSocketUpgrade`) produces a 400 and
    ## closes.
  MessageHandler* = proc(conn: ConnId; message: string) {.gcsafe.}
    ## Runs on a pool worker for every complete text message. Exceptions are
    ## swallowed.
  ConnectionHandler* = proc(conn: ConnId) {.gcsafe.}
    ## Runs on a pool worker after an upgrade (`onOpen`) or when an upgraded
    ## connection ends (`onClose`). Exceptions are swallowed.

  ConnState = enum
    csHttp       # parsing requests
    csHttpBusy   # a request is on a worker; nothing is read until it answers
    csWebSocket  # upgraded, exchanging frames
    csClosing    # close frame sent or 400 queued; waiting for flush/reply/deadline

  PendingKind = enum
    pkResponse, pkUpgrade, pkClose

  Pending = object
    ## An action a worker (or `close`) asks the IO thread to apply. The bytes
    ## that go with it are already in `outbound`.
    kind: PendingKind
    keepAlive: bool

  ConnObj = object
    # --- IO thread only ---
    id: ConnId
    fd: SocketHandle
    state: ConnState
    recvBuf: string
    parser: HttpParser
    decoder: FrameDecoder
    assembler: MessageAssembler
    writeBuf: string          # bytes taken from `outbound`, partially sent
    writePos: int
    registered: set[Event]
    paused: bool              # no Read interest (busy request or stalled task)
    wantWrite: bool
    closeAfterFlush: bool     # tear down once everything queued is sent
    closeSent: bool           # we have queued a close frame
    upgraded: bool            # onOpen fired, so onClose must fire
    hasDeadline: bool
    deadline: MonoTime
    hasStalled: bool
    stalled: Task             # task the pool could not take yet
    # --- shared, guarded by ServerImpl.lock ---
    outbound: string
    pending: seq[Pending]
    isWebSocket: bool         # `send` is only valid once this is set
    closing: bool             # `send`/responses are refused once set

  Conn = ptr ConnObj

  ServerState = enum
    ssNew, ssListening, ssStopped

  ServerImpl = object
    # --- immutable after `listen` ---
    onRequest: RequestHandler
    onMessage: MessageHandler
    onOpen: ConnectionHandler
    onClose: ConnectionHandler
    workers, queueCapacity, maxMessageSize, closeTimeoutMs: int
    pool: Pool
    listenFd: SocketHandle
    port: int
    selector: Selector[int]
    wake: SelectEvent
    ioThread: Thread[ptr ServerImpl]
    state: ServerState        # main thread only
    # --- IO thread only ---
    byFd: Table[int, Conn]
    nextId: int
    readChunk: string
    acceptPending: bool
    stalledConns: int
    # --- guarded by lock ---
    lock: Lock
    byId: Table[ConnId, Conn]
    dirty: seq[ConnId]        # connections with new outbound bytes or actions
    ioRunning: bool           # the selector and wake event are alive
    stopRequested: bool

  ServerObj = object
    impl: ptr ServerImpl

  Server* = ref ServerObj
    ## Handle to one server. Dropping the last reference without `shutdown`
    ## shuts it down; call `shutdown` explicitly for deterministic teardown.

# --- ConnId ----------------------------------------------------------------------

proc `==`*(a, b: ConnId): bool {.borrow.}
  ## Identity comparison of two connection ids.
proc hash*(id: ConnId): Hash {.borrow.}
  ## Hash of the id, so `ConnId` can key a `Table`.
proc `$`*(id: ConnId): string =
  ## Decimal rendering of the id.
  $int(id)

# --- request actions ---------------------------------------------------------------

proc respond*(response: HttpResponse): RequestAction =
  ## Answer the request with `response`. Keep-alive follows the request
  ## (`keepAlive(req)`); `HEAD` requests get headers only.
  RequestAction(kind: raRespond, response: response)

proc upgrade*(): RequestAction =
  ## Complete the WebSocket handshake for this request. The server validates
  ## the upgrade headers and computes `Sec-WebSocket-Accept`; after the 101 is
  ## queued the connection switches to frames and `onOpen` fires.
  RequestAction(kind: raUpgrade)

proc isWebSocketUpgrade*(req: HttpRequest): bool =
  ## Whether `req` is a valid RFC 6455 opening handshake: `GET`,
  ## `Connection` listing `Upgrade`, `Upgrade` listing `websocket`
  ## (case-insensitive), `Sec-WebSocket-Version: 13`, and a non-empty
  ## `Sec-WebSocket-Key`. Path and token checks are the handler's business.
  req.httpMethod == hmGet and
    req.headerHasToken("Connection", "Upgrade") and
    req.headerHasToken("Upgrade", "websocket") and
    req.getHeader("Sec-WebSocket-Version") == "13" and
    req.getHeader("Sec-WebSocket-Key").len > 0

proc upgradeResponse(req: HttpRequest): HttpResponse =
  result = initResponse(101)
  result.addHeader("Upgrade", "websocket")
  result.addHeader("Connection", "Upgrade")
  result.addHeader("Sec-WebSocket-Accept",
                   webSocketAccept(req.getHeader("Sec-WebSocket-Key")))

# --- platform helpers -------------------------------------------------------------

when UseWinSockets:
  const SendFlags = 0'i32
else:
  const SendFlags = cint(MSG_NOSIGNAL)

proc wouldBlock(err: OSErrorCode): bool =
  when UseWinSockets:
    err.int32 == WSAEWOULDBLOCK
  else:
    err.int32 == EAGAIN or err.int32 == EWOULDBLOCK or err.int32 == EINTR

proc rawRecv(fd: SocketHandle; buf: pointer; len: int): int =
  when UseWinSockets:
    int(recv(fd, buf, cint(len), 0'i32))
  else:
    recv(fd, buf, len, 0'i32)

proc rawSend(fd: SocketHandle; buf: pointer; len: int): int =
  when UseWinSockets:
    int(send(fd, buf, cint(len), SendFlags))
  else:
    send(fd, buf, len, SendFlags)

proc raiseFdLimit() =
  ## Raises the soft `RLIMIT_NOFILE` to `min(hard, 4096)` when it is lower
  ## (the macOS GUI default is 256). Failure is ignored. Must run before
  ## `newSelector`, which sizes itself from the limit (PLAN.md spike (c)).
  when defined(posix) and not UseWinSockets:
    const Target = 4096
    var lim: RLimit
    if getrlimit(RLIMIT_NOFILE, lim) != 0:
      return
    let cur = int(lim.rlim_cur)
    let hard = int(lim.rlim_max)
    if cur < 0 or cur >= Target:
      return # already unlimited or large enough
    let wanted = if hard < 0: Target else: min(hard, Target)
    if wanted > cur:
      lim.rlim_cur = typeof(lim.rlim_cur)(wanted)
      discard setrlimit(RLIMIT_NOFILE, lim)

proc openListener(port: int): (SocketHandle, int) =
  ## A non-blocking TCP listener on `127.0.0.1:port`; returns the handle and
  ## the bound port (`port = 0` picks an ephemeral one). Raises `OSError`.
  let fd = createNativeSocket(nativesockets.AF_INET, nativesockets.SOCK_STREAM,
                              nativesockets.IPPROTO_TCP)
  if fd == osInvalidSocket:
    raiseOSError(osLastError())
  try:
    setSockOptInt(fd, SOL_SOCKET, SO_REUSEADDR, 1)
    var sa: Sockaddr_in
    sa.sin_family = typeof(sa.sin_family)(toInt(nativesockets.AF_INET))
    sa.sin_port = htons(uint16(port))
    sa.sin_addr.s_addr = htonl(0x7F000001'u32) # 127.0.0.1, never anything else
    if bindAddr(fd, cast[ptr SockAddr](addr sa), SockLen(sizeof(sa))) < 0:
      raiseOSError(osLastError())
    if nativesockets.listen(fd, Backlog) < 0:
      raiseOSError(osLastError())
    let (_, bound) = getLocalAddr(fd, nativesockets.AF_INET)
    fd.setBlocking(false)
    result = (fd, int(uint16(bound)))
  except CatchableError:
    fd.close()
    raise

# --- shared-state helpers (any thread) -----------------------------------------

proc markDirtyLocked(s: ptr ServerImpl; id: ConnId) =
  ## Caller holds `s.lock`. Records that the IO thread must look at `id` and
  ## wakes the selector once per batch (the pipe behind the event is small).
  let wasEmpty = s.dirty.len == 0
  s.dirty.add id
  if wasEmpty and s.ioRunning:
    try:
      s.wake.trigger()
    except IOSelectorsException:
      discard # pipe full: a wake-up is already pending

proc enqueue(s: ptr ServerImpl; id: ConnId; bytes: string; action: Pending) =
  ## Worker side of a request result: appends the encoded response (or 101)
  ## and asks the IO thread to apply `action`. Dropped if the connection is
  ## gone or already closing.
  acquire s.lock
  let c = s.byId.getOrDefault(id)
  if c != nil and not c.closing:
    c.outbound.add bytes
    c.pending.add action
    s.markDirtyLocked(id)
  release s.lock

# --- worker-side tasks ------------------------------------------------------------

proc runRequest(s: ptr ServerImpl; id: ConnId; req: HttpRequest) {.gcsafe.} =
  var action: RequestAction
  try:
    action = if s.onRequest != nil: s.onRequest(id, req) else: respond(notFound())
  except CatchableError:
    action = respond(initResponse(500, "500 Internal Server Error", "text/plain"))
  let headOnly = req.httpMethod == hmHead
  case action.kind
  of raRespond:
    let ka = req.keepAlive
    s.enqueue(id, encodeResponse(action.response, ka, headOnly),
              Pending(kind: pkResponse, keepAlive: ka))
  of raUpgrade:
    if isWebSocketUpgrade(req):
      s.enqueue(id, encodeResponse(upgradeResponse(req), true),
                Pending(kind: pkUpgrade))
    else:
      s.enqueue(id, encodeResponse(badRequest(), false),
                Pending(kind: pkResponse, keepAlive: false))

proc runMessage(s: ptr ServerImpl; id: ConnId; message: string) {.gcsafe.} =
  if s.onMessage != nil:
    try:
      s.onMessage(id, message)
    except CatchableError:
      discard

proc runOpen(s: ptr ServerImpl; id: ConnId) {.gcsafe.} =
  if s.onOpen != nil:
    try:
      s.onOpen(id)
    except CatchableError:
      discard

proc runClose(s: ptr ServerImpl; id: ConnId) {.gcsafe.} =
  if s.onClose != nil:
    try:
      s.onClose(id)
    except CatchableError:
      discard

# --- IO thread: connection bookkeeping --------------------------------------------

proc setDeadline(s: ptr ServerImpl; c: Conn) =
  c.hasDeadline = true
  c.deadline = getMonoTime() + initDuration(milliseconds = s.closeTimeoutMs)

proc updateInterest(s: ptr ServerImpl; c: Conn) =
  var wanted: set[Event]
  if not c.paused:
    wanted.incl Event.Read
  if c.wantWrite:
    wanted.incl Event.Write
  if wanted != c.registered:
    s.selector.updateHandle(c.fd, wanted)
    c.registered = wanted

proc teardown(s: ptr ServerImpl; c: Conn) =
  ## Closes the socket, forgets the connection, fires `onClose` if it had
  ## been upgraded, and frees it. `c` is invalid afterwards.
  s.selector.unregister(c.fd)
  c.fd.close()
  s.byFd.del(int(c.fd))
  acquire s.lock
  s.byId.del(c.id)
  release s.lock
  if c.hasStalled:
    dec s.stalledConns
  if c.upgraded and s.onClose != nil:
    discard s.pool.submit(toTask runClose(s, c.id), LifecycleSubmitTimeoutMs)
  `=destroy`(c[])
  deallocShared(c)

proc queueBytes(s: ptr ServerImpl; c: Conn; bytes: string) =
  ## IO-thread append to the outbound queue (control frames, 400s).
  acquire s.lock
  c.outbound.add bytes
  release s.lock

proc beginCloseAfterFlush(s: ptr ServerImpl; c: Conn) =
  ## Everything queued so far is sent, then the socket is closed. Incoming
  ## bytes are discarded from now on.
  c.closeAfterFlush = true
  c.state = csClosing
  c.recvBuf.setLen 0
  acquire s.lock
  c.closing = true
  release s.lock
  s.setDeadline(c)

proc flush(s: ptr ServerImpl; c: Conn): bool =
  ## Writes as much queued output as the socket takes. Returns `false` if the
  ## connection was torn down (write error, or close-after-flush completed).
  while true:
    if c.writePos >= c.writeBuf.len:
      c.writeBuf.setLen 0
      c.writePos = 0
      acquire s.lock
      if c.outbound.len > 0:
        c.writeBuf = move c.outbound
      release s.lock
      if c.writeBuf.len == 0:
        break
    let n = rawSend(c.fd, addr c.writeBuf[c.writePos], c.writeBuf.len - c.writePos)
    if n < 0:
      if wouldBlock(osLastError()):
        break
      s.teardown(c)
      return false
    c.writePos += n
  c.wantWrite = c.writePos < c.writeBuf.len
  if not c.wantWrite and c.closeAfterFlush:
    s.teardown(c)
    return false
  s.updateInterest(c)
  true

proc failClose(s: ptr ServerImpl; c: Conn; code: int) =
  ## Server-side protocol failure: send a close frame with `code`, then drop
  ## the connection once it is flushed.
  if not c.closeSent:
    s.queueBytes(c, encodeClose(code))
    c.closeSent = true
  s.beginCloseAfterFlush(c)

proc dispatch(s: ptr ServerImpl; c: Conn; task: var Task) =
  ## Hands `task` to the pool. If the queue is full the task is parked on the
  ## connection, reading from it stops, and the IO loop retries shortly.
  if s.pool.trySubmit(task):
    return
  c.stalled = move task
  c.hasStalled = true
  c.paused = true
  inc s.stalledConns

# --- IO thread: protocol processing -------------------------------------------

proc processHttp(s: ptr ServerImpl; c: Conn): bool {.gcsafe.}
proc processFrames(s: ptr ServerImpl; c: Conn): bool {.gcsafe.}

proc processBuffer(s: ptr ServerImpl; c: Conn): bool {.gcsafe.} =
  ## Parses whatever is in `recvBuf` for the current state. Returns `false`
  ## if the connection was torn down.
  case c.state
  of csHttp: s.processHttp(c)
  of csHttpBusy: true
  of csWebSocket, csClosing: s.processFrames(c)

proc processHttp(s: ptr ServerImpl; c: Conn): bool {.gcsafe.} =
  while c.state == csHttp and not c.paused:
    let r = c.parser.parseRequest(c.recvBuf)
    case r.status
    of psIncomplete:
      break
    of psMalformed:
      s.queueBytes(c, encodeResponse(badRequest(), keepAlive = false))
      s.beginCloseAfterFlush(c)
      return s.flush(c)
    of psComplete:
      c.recvBuf.delete(0 ..< r.consumed)
      c.state = csHttpBusy
      c.paused = true
      var task = toTask runRequest(s, c.id, r.request)
      s.dispatch(c, task)
  s.updateInterest(c)
  true

proc processFrames(s: ptr ServerImpl; c: Conn): bool {.gcsafe.} =
  try:
    while c.state in {csWebSocket, csClosing} and not c.paused and not c.closeAfterFlush:
      let r = c.decoder.decodeFrame(c.recvBuf)
      if r.status == fsIncomplete:
        break
      c.recvBuf.delete(0 ..< r.consumed)
      let a = c.assembler.feed(r.frame)
      case a.status
      of asNone:
        discard
      of asControl:
        case a.control.opcode
        of opPing:
          if not c.closeSent:
            s.queueBytes(c, encodePongFor(a.control))
        of opClose:
          let info = decodeClose(a.control)
          if c.closeSent:
            # Our close was answered: the handshake is complete.
            s.teardown(c)
            return false
          s.queueBytes(c, encodeCloseReply(info))
          c.closeSent = true
          s.beginCloseAfterFlush(c)
        else:
          discard # pong
      of asMessage:
        if c.state == csClosing:
          discard # no data after we sent a close frame
        elif a.message.kind == mkBinary:
          s.failClose(c, CloseUnsupportedData)
        else:
          var task = toTask runMessage(s, c.id, a.message.payload)
          s.dispatch(c, task)
  except NeelFrameError as e:
    if c.closeSent:
      s.teardown(c)
      return false
    s.failClose(c, e.closeCode)
  s.flush(c)

proc readFrom(s: ptr ServerImpl; c: Conn): bool =
  let n = rawRecv(c.fd, addr s.readChunk[0], ReadChunk)
  if n == 0:
    s.teardown(c)
    return false
  if n < 0:
    if wouldBlock(osLastError()):
      return true
    s.teardown(c)
    return false
  if c.closeAfterFlush:
    return true # draining only; input is discarded
  let old = c.recvBuf.len
  c.recvBuf.setLen(old + n)
  copyMem(addr c.recvBuf[old], addr s.readChunk[0], n)
  s.processBuffer(c)

proc applyPending(s: ptr ServerImpl; c: Conn; p: Pending): bool =
  ## Applies one worker-requested state change. Returns `false` if the
  ## connection was torn down.
  case p.kind
  of pkResponse:
    if c.state != csHttpBusy:
      return true
    c.state = csHttp
    c.paused = c.hasStalled
    if not p.keepAlive:
      s.beginCloseAfterFlush(c)
      return true
    s.processHttp(c)
  of pkUpgrade:
    if c.state != csHttpBusy:
      return true
    c.state = csWebSocket
    c.paused = c.hasStalled
    c.upgraded = true
    c.decoder = initFrameDecoder(frServer, s.maxMessageSize)
    c.assembler = initMessageAssembler(s.maxMessageSize)
    acquire s.lock
    c.isWebSocket = true
    release s.lock
    if s.onOpen != nil:
      discard s.pool.submit(toTask runOpen(s, c.id), LifecycleSubmitTimeoutMs)
    s.processFrames(c)
  of pkClose:
    case c.state
    of csWebSocket:
      # The close frame is already in `outbound`; wait for the peer's reply.
      c.state = csClosing
      c.closeSent = true
      s.setDeadline(c)
      true
    of csHttp, csHttpBusy:
      s.beginCloseAfterFlush(c)
      true
    of csClosing:
      true

proc processDirty(s: ptr ServerImpl) =
  var ids: seq[ConnId]
  acquire s.lock
  swap(ids, s.dirty)
  release s.lock
  for id in ids:
    # `byId` is only mutated by this thread, so reading it unlocked is safe.
    let c = s.byId.getOrDefault(id)
    if c == nil:
      continue
    var actions: seq[Pending]
    acquire s.lock
    swap(actions, c.pending)
    release s.lock
    var alive = true
    for p in actions:
      alive = s.applyPending(c, p)
      if not alive:
        break
    if alive:
      discard s.flush(c)

proc retryStalled(s: ptr ServerImpl) =
  if s.stalledConns == 0:
    return
  var stalled: seq[Conn]
  for c in s.byFd.values:
    if c.hasStalled:
      stalled.add c
  for c in stalled:
    if not s.pool.trySubmit(c.stalled):
      break
    c.hasStalled = false
    dec s.stalledConns
    if c.state != csHttpBusy:
      c.paused = false
      if s.processBuffer(c):
        s.updateInterest(c)
    else:
      s.updateInterest(c)

proc processDeadlines(s: ptr ServerImpl) =
  let now = getMonoTime()
  var expired: seq[Conn]
  for c in s.byFd.values:
    if c.hasDeadline and now >= c.deadline:
      expired.add c
  for c in expired:
    s.teardown(c)

proc selectTimeout(s: ptr ServerImpl): int =
  result = IoTickMs
  if s.stalledConns > 0:
    result = min(result, StallRetryMs)
  let now = getMonoTime()
  for c in s.byFd.values:
    if c.hasDeadline:
      let left = (c.deadline - now).inMilliseconds
      result = min(result, int(max(left, 0)))

proc acceptAll(s: ptr ServerImpl) =
  while true:
    let (fd, _) = s.listenFd.accept()
    if fd == osInvalidSocket:
      break
    fd.setBlocking(false)
    try:
      setSockOptInt(fd, toInt(nativesockets.IPPROTO_TCP), TCP_NODELAY, 1)
      when defined(macosx) and not UseWinSockets:
        setSockOptInt(fd, SOL_SOCKET, SO_NOSIGPIPE, 1)
    except OSError:
      discard
    inc s.nextId
    let c = cast[Conn](allocShared0(sizeof(ConnObj)))
    c.id = ConnId(s.nextId)
    c.fd = fd
    c.state = csHttp
    c.registered = {Event.Read}
    s.byFd[int(fd)] = c
    acquire s.lock
    s.byId[c.id] = c
    release s.lock
    s.selector.registerHandle(fd, {Event.Read}, int(c.id))

proc handleEvent(s: ptr ServerImpl; rk: ReadyKey) =
  if Event.User in rk.events:
    return # wake-up; `processDirty` runs after the batch
  if rk.fd == int(s.listenFd):
    s.acceptPending = true # accept after the batch so a reused fd cannot be confused
    return
  let c = s.byFd.getOrDefault(rk.fd)
  if c == nil:
    return
  if Event.Error in rk.events:
    s.teardown(c)
    return
  if Event.Read in rk.events:
    if not s.readFrom(c):
      return
  if Event.Write in rk.events:
    discard s.flush(c)

proc teardownAll(s: ptr ServerImpl) =
  var conns: seq[Conn]
  for c in s.byFd.values:
    conns.add c
  for c in conns:
    if c.upgraded and not c.closeSent:
      # Best effort: tell the browser we are going away.
      let frame = encodeClose(CloseGoingAway)
      discard rawSend(c.fd, unsafeAddr frame[0], frame.len)
    s.teardown(c)

proc ioLoop(s: ptr ServerImpl) {.thread.} =
  var keys = newSeq[ReadyKey](128)
  while true:
    acquire s.lock
    let stop = s.stopRequested
    release s.lock
    if stop:
      break
    let n = s.selector.selectInto(s.selectTimeout(), keys)
    s.acceptPending = false
    for i in 0 ..< n:
      s.handleEvent(keys[i])
    if s.acceptPending:
      s.acceptAll()
    s.processDirty()
    s.retryStalled()
    s.processDeadlines()
  s.selector.unregister(s.listenFd)
  s.listenFd.close()
  s.teardownAll()
  acquire s.lock
  s.ioRunning = false
  release s.lock
  s.selector.unregister(s.wake)
  s.wake.close()
  s.selector.close()

# --- public API --------------------------------------------------------------------

proc shutdownImpl(s: ptr ServerImpl) =
  case s.state
  of ssStopped:
    return
  of ssNew:
    s.state = ssStopped
    return
  of ssListening:
    acquire s.lock
    s.stopRequested = true
    if s.ioRunning:
      try:
        s.wake.trigger()
      except IOSelectorsException:
        discard
    release s.lock
    joinThread(s.ioThread)
    s.pool.stop(drain = true)
    s.state = ssStopped

proc `=destroy`(s: ServerObj) =
  if s.impl != nil:
    shutdownImpl(s.impl)
    deinitLock s.impl.lock
    `=destroy`(s.impl[])
    deallocShared(s.impl)

proc newServer*(onRequest: RequestHandler = nil;
                onMessage: MessageHandler = nil;
                onOpen: ConnectionHandler = nil;
                onClose: ConnectionHandler = nil;
                workers = DefaultWorkers;
                queueCapacity = DefaultQueueCapacity;
                maxMessageSize = DefaultMaxMessageSize;
                closeTimeoutMs = DefaultCloseTimeoutMs): Server =
  ## A server with the given hooks and limits. Nothing is bound or started
  ## until `listen`. A `nil` `onRequest` answers every request with 404; a
  ## `nil` `onMessage` ignores messages.
  let impl = cast[ptr ServerImpl](allocShared0(sizeof(ServerImpl)))
  initLock impl.lock
  impl.onRequest = onRequest
  impl.onMessage = onMessage
  impl.onOpen = onOpen
  impl.onClose = onClose
  impl.workers = workers
  impl.queueCapacity = queueCapacity
  impl.maxMessageSize = maxMessageSize
  impl.closeTimeoutMs = closeTimeoutMs
  impl.listenFd = osInvalidSocket
  result = Server(impl: impl)

proc listen*(s: Server; port = 0) =
  ## Binds `127.0.0.1:port` (`0` picks an ephemeral port, readable through
  ## `port` afterwards), starts the worker pool and the IO thread. Raises
  ## `OSError` if the port cannot be bound. A server listens at most once.
  let impl = s.impl
  doAssert impl.state == ssNew, "listen called twice"
  raiseFdLimit()
  let (fd, bound) = openListener(port)
  impl.listenFd = fd
  impl.port = bound
  impl.readChunk = newString(ReadChunk)
  impl.selector = newSelector[int]()
  impl.wake = newSelectEvent()
  impl.selector.registerEvent(impl.wake, 0)
  impl.selector.registerHandle(fd, {Event.Read}, 0)
  impl.pool = newPool(impl.workers, impl.queueCapacity)
  impl.ioRunning = true
  impl.state = ssListening
  createThread(impl.ioThread, ioLoop, impl)

proc port*(s: Server): int =
  ## The bound port, or 0 before `listen`.
  s.impl.port

proc running*(s: Server): bool =
  ## `true` between `listen` and `shutdown`.
  s.impl.state == ssListening

proc shutdown*(s: Server) =
  ## Stops accepting, closes every connection (upgraded ones get a best-effort
  ## 1001 close frame and their `onClose`), joins the IO thread, drains and
  ## joins the pool. Idempotent; safe in a test `finally`. Must be called from
  ## outside the pool (not from a hook).
  shutdownImpl(s.impl)

proc send*(s: Server; conn: ConnId; text: string): bool =
  ## Queues `text` as one WebSocket text message to `conn` from any thread.
  ## Returns `false` (and sends nothing) if the connection is unknown, not
  ## upgraded, or already closing.
  let frame = encodeText(text)
  let impl = s.impl
  acquire impl.lock
  let c = impl.byId.getOrDefault(conn)
  if c == nil or not c.isWebSocket or c.closing:
    release impl.lock
    return false
  c.outbound.add frame
  impl.markDirtyLocked(conn)
  release impl.lock
  true

proc close*(s: Server; conn: ConnId; code = CloseNormal; reason = ""): bool =
  ## Starts closing `conn` from any thread. On a WebSocket connection a close
  ## frame with `code`/`reason` is sent and the socket is dropped after the
  ## peer's reply or `closeTimeoutMs`; a plain HTTP connection is closed once
  ## its queued output is flushed. Later `send`s are refused. Returns `false`
  ## if the connection is unknown or already closing. Raises `NeelFrameError`
  ## for a code that must not go on the wire.
  let frame = encodeClose(code, reason)
  let impl = s.impl
  acquire impl.lock
  let c = impl.byId.getOrDefault(conn)
  if c == nil or c.closing:
    release impl.lock
    return false
  c.closing = true
  if c.isWebSocket:
    c.outbound.add frame
  c.pending.add Pending(kind: pkClose)
  impl.markDirtyLocked(conn)
  release impl.lock
  true
