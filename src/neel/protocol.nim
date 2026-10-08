## protocol.nim - `call` / `ret` / `err` messages and the pending-call table.
##
## Implements the symmetric JSON wire format from `PLAN.md` "Protocol
## reference". Messages are identical in both directions; a `call` carrying an
## `id` expects exactly one `ret` or `err` with that id, a `call` without an
## `id` is fire-and-forget. Ids are allocated per side and per connection.
##
## Surface:
## - `Msg` (`msgCall` / `msgRet` / `msgErr`), `encode(msg): string` (compact
##   JSON), `decode(text): Msg` (strict shape validation; every failure is a
##   `NeelProtocolError`, nothing from `std/json` leaks). An absent `id` is
##   the sentinel `NoId = 0`; wire ids are positive integers.
## - `ErrorInfo` (`kind` = Nim exception type name or JS error name, `msg`)
##   and `errorInfo(e)` / `errMsg(id, e)` to build an `err` from a caught
##   `ref CatchableError`.
## - `IdAllocator`: lock-free per-connection id counter starting at 1.
## - `PendingTable`: Nim -> JS waits. `register`, `wait` (bounded by a
##   deadline, raises `NeelTimeoutError` / `NeelDisconnectedError` /
##   `NeelRemoteError`), `complete` (from `onMessage`), `disconnect` (from
##   `onClose`), `cancel`.
##
## Threading: everything here is `{.gcsafe.}`. `PendingTable` is a `ref` to a
## one-field object pointing at shared memory (the `Pool` / `Server` pattern);
## one `Lock` guards the table and every entry's state, each entry has its own
## `Cond`. Entries are created and freed only by the waiting thread
## (`register` / `wait` / `cancel`); `complete` and `disconnect` only mutate
## state under the lock and signal, so a late `complete` after the waiter is
## gone is a harmless `false`. Result values are deep-copied into the entry on
## the completing thread and moved out by the waiter, so no `JsonNode`
## refcount is ever touched by two threads.

import std/[json, locks, tables, hashes, monotimes, times, atomics]
import ./pool
from ./server import ConnId, `==`, hash, `$`

const
  NoId* = 0
    ## Sentinel for "this message carries no id" (fire-and-forget `call`).
    ## Wire ids are positive, so 0 never collides with a real id; a message
    ## with `"id": 0` on the wire is malformed.
  MaxJsonDepth* = 256
    ## Maximum nesting of arrays/objects accepted by `decode`. `std/json`
    ## parses recursively, so a deeper document is rejected before parsing
    ## rather than risking the stack.

type
  NeelProtocolError* = object of CatchableError
    ## Raised by `decode` for text that is not a well-formed Neel message
    ## (invalid JSON, wrong shape, wrong field types).

  NeelTimeoutError* = object of CatchableError
    ## Raised by `wait` when no `ret` / `err` arrived before the deadline.

  NeelDisconnectedError* = object of CatchableError
    ## Raised by `wait` when the connection closed while waiting (or had
    ## already closed when the wait began).

  NeelRemoteError* = object of CatchableError
    ## Raised by `wait` when the remote side answered with `err`. `msg` is
    ## the remote message, `kind` the remote exception type / JS error name.
    kind*: string

  MsgKind* = enum
    msgCall = "call"  ## Invoke `name` with `args`; `id` optional.
    msgRet = "ret"    ## Successful reply to the `call` with the same `id`.
    msgErr = "err"    ## Failed reply to the `call` with the same `id`.

  ErrorInfo* = object
    ## Structured error carried by an `err` message.
    kind*: string  ## Nim exception type name or JS error name.
    msg*: string   ## Human-readable message.

  Msg* = object
    ## One wire message. `id` is `NoId` when absent (only legal for `call`).
    ## Named `Msg` rather than `Message` so it does not clash with
    ## `websocket.Message` in modules that import both.
    id*: int
    case kind*: MsgKind
    of msgCall:
      name*: string
      args*: seq[JsonNode]
    of msgRet:
      value*: JsonNode
    of msgErr:
      error*: ErrorInfo

  IdAllocator* = object
    ## Per-connection id counter. Zero-initialized means "next id is 1".
    ## `nextId` is an atomic fetch-add, so several worker threads may
    ## allocate for the same connection at once without a lock. Keep one
    ## per connection (e.g. on the window record) and drop it with the
    ## connection; the pending table deliberately holds no counters so its
    ## per-connection records can vanish as soon as they are empty.
    counter: Atomic[int]

  PendingState = enum
    psWaiting, psRet, psErr, psDisconnected

  PendingEntry = object
    ## One outstanding Nim -> JS call. Shared-allocated so the `Cond` has a
    ## stable address while the table rehashes. Owned by the waiting thread.
    cond: Cond
    state: PendingState
    value: JsonNode   # psRet; deep copy owned solely by this entry
    error: ErrorInfo  # psErr

  PendingImpl = object
    lock: Lock
    conns: Table[ConnId, Table[int, ptr PendingEntry]]
      ## Two levels so `disconnect` touches only one connection's entries.
      ## A connection record exists exactly while it has entries.

  PendingTableObj = object
    impl: ptr PendingImpl

  PendingTable* = ref PendingTableObj
    ## Pending-call table for Nim -> JS waits. Create with `newPendingTable`;
    ## keep one per server (Task 13 stores it in a module global). Must not
    ## be dropped while a `wait` is in progress.

# --- messages ----------------------------------------------------------------

proc `==`*(a, b: Msg): bool =
  ## Structural equality (JSON values compared with `std/json`'s `==`).
  if a.kind != b.kind or a.id != b.id:
    return false
  case a.kind
  of msgCall:
    a.name == b.name and a.args == b.args
  of msgRet:
    a.value == b.value
  of msgErr:
    a.error == b.error

proc hasId*(m: Msg): bool {.inline.} =
  ## Whether the message carries an id (`id != NoId`).
  m.id != NoId

proc callMsg*(name: string; args: seq[JsonNode]; id = NoId): Msg =
  ## A `call`; `id = NoId` makes it fire-and-forget.
  Msg(kind: msgCall, id: id, name: name, args: args)

proc retMsg*(id: int; value: JsonNode): Msg =
  ## A `ret` reply. A `nil` value is encoded as JSON `null`.
  Msg(kind: msgRet, id: id, value: (if value.isNil: newJNull() else: value))

proc errMsg*(id: int; error: ErrorInfo): Msg =
  ## An `err` reply carrying `error`.
  Msg(kind: msgErr, id: id, error: error)

proc errMsg*(id: int; kind, msg: string): Msg =
  ## An `err` reply with `kind` and `msg` given directly.
  errMsg(id, ErrorInfo(kind: kind, msg: msg))

proc errorInfo*(e: ref CatchableError): ErrorInfo =
  ## The structured error for a caught exception: `kind = $e.name`
  ## (e.g. `"ValueError"`), `msg = e.msg`. For a `NeelRemoteError` the
  ## original remote `kind` is forwarded instead of `"NeelRemoteError"`, so
  ## an error that crosses the bridge twice keeps its origin.
  if e of NeelRemoteError:
    ErrorInfo(kind: (ref NeelRemoteError)(e).kind, msg: e.msg)
  else:
    ErrorInfo(kind: $e.name, msg: e.msg)

proc errMsg*(id: int; e: ref CatchableError): Msg =
  ## An `err` reply for a caught exception; see `errorInfo`.
  errMsg(id, errorInfo(e))

proc encode*(m: Msg): string =
  ## Compact JSON for `m`, fields in the order of the protocol reference
  ## (`t`, `id`, then the kind-specific fields). `id` is omitted when `NoId`.
  var o = newJObject()
  o["t"] = %($m.kind)
  if m.hasId:
    o["id"] = %m.id
  case m.kind
  of msgCall:
    o["name"] = %m.name
    var a = newJArray()
    for x in m.args:
      a.add(if x.isNil: newJNull() else: x)
    o["args"] = a
  of msgRet:
    o["value"] = (if m.value.isNil: newJNull() else: m.value)
  of msgErr:
    o["error"] = %*{"kind": m.error.kind, "msg": m.error.msg}
  $o

proc protocolError(reason: string): ref NeelProtocolError =
  (ref NeelProtocolError)(msg: reason)

proc checkDepth(text: string) =
  ## Rejects documents nested deeper than `MaxJsonDepth` (brackets inside
  ## strings are skipped). Anything else is left to the JSON parser.
  var depth = 0
  var inString = false
  var escaped = false
  for ch in text:
    if inString:
      if escaped:
        escaped = false
      elif ch == '\\':
        escaped = true
      elif ch == '"':
        inString = false
    else:
      case ch
      of '"':
        inString = true
      of '[', '{':
        inc depth
        if depth > MaxJsonDepth:
          raise protocolError("JSON nested deeper than " & $MaxJsonDepth)
      of ']', '}':
        if depth > 0:
          dec depth
      else:
        discard

proc requireField(o: JsonNode; name: string; kind: JsonNodeKind;
                  what: string): JsonNode =
  let v = o.getOrDefault(name)
  if v.isNil:
    raise protocolError("missing field '" & name & "'")
  if v.kind != kind:
    raise protocolError("field '" & name & "' must be " & what)
  v

proc decode*(text: string): Msg =
  ## Parses one wire message, validating its shape strictly:
  ## - the text must be a JSON object with `t` in `call` / `ret` / `err`;
  ## - `id`, when present, must be a positive integer (floats, strings,
  ##   negatives, `null`, and `0` are rejected);
  ## - `call` needs a string `name` and an array `args` (`id` optional);
  ## - `ret` needs `id` and `value` (any JSON, including `null`);
  ## - `err` needs `id` and an object `error` with string `kind` and `msg`.
  ## Unknown extra fields are ignored. Any violation, including invalid JSON
  ## or nesting beyond `MaxJsonDepth`, raises `NeelProtocolError` with a
  ## reason.
  checkDepth(text)
  var root: JsonNode
  try:
    root = parseJson(text)
  except CatchableError as e:
    raise protocolError("invalid JSON: " & e.msg)
  if root.isNil or root.kind != JObject:
    raise protocolError("message must be a JSON object")

  let t = requireField(root, "t", JString, "a string").getStr
  var kind: MsgKind
  case t
  of "call": kind = msgCall
  of "ret": kind = msgRet
  of "err": kind = msgErr
  else:
    raise protocolError("unknown message type '" & t & "'")

  var id = NoId
  let idNode = root.getOrDefault("id")
  if not idNode.isNil:
    if idNode.kind != JInt:
      raise protocolError("field 'id' must be an integer")
    let v = idNode.getBiggestInt
    if v < 1 or v > BiggestInt(high(int)):
      raise protocolError("field 'id' must be a positive integer")
    id = int(v)

  case kind
  of msgCall:
    let name = requireField(root, "name", JString, "a string").getStr
    let argsNode = requireField(root, "args", JArray, "an array")
    result = Msg(kind: msgCall, id: id, name: name, args: argsNode.getElems)
  of msgRet:
    if id == NoId:
      raise protocolError("'ret' requires an id")
    let value = root.getOrDefault("value")
    if value.isNil:
      raise protocolError("missing field 'value'")
    result = Msg(kind: msgRet, id: id, value: value)
  of msgErr:
    if id == NoId:
      raise protocolError("'err' requires an id")
    let errNode = requireField(root, "error", JObject, "an object")
    let kindStr = requireField(errNode, "kind", JString, "a string").getStr
    let msgStr = requireField(errNode, "msg", JString, "a string").getStr
    result = Msg(kind: msgErr, id: id,
                 error: ErrorInfo(kind: kindStr, msg: msgStr))

# --- id allocation -------------------------------------------------------------

proc nextId*(a: var IdAllocator): int =
  ## The next id for this connection: 1, 2, 3, ... Safe to call from several
  ## threads at once (atomic fetch-add); every caller gets a distinct value.
  a.counter.fetchAdd(1, moRelaxed) + 1

# --- pending-call table ----------------------------------------------------------

proc freeEntry(e: ptr PendingEntry) =
  deinitCond e.cond
  `=destroy`(e[])
  deallocShared(e)

proc `=destroy`(t: PendingTableObj) =
  if t.impl != nil:
    for _, byId in t.impl.conns:
      for _, e in byId:
        freeEntry(e)
    deinitLock t.impl.lock
    `=destroy`(t.impl[])
    deallocShared(t.impl)

proc newPendingTable*(): PendingTable =
  ## An empty table. Dropping the last reference frees every entry; do that
  ## only after all waiters have returned.
  let impl = cast[ptr PendingImpl](allocShared0(sizeof(PendingImpl)))
  initLock impl.lock
  impl.conns = initTable[ConnId, Table[int, ptr PendingEntry]]()
  PendingTable(impl: impl)

proc lookup(impl: ptr PendingImpl; conn: ConnId; id: int): ptr PendingEntry =
  ## Lock must be held. `nil` when unknown.
  impl.conns.withValue(conn, byId):
    return byId[].getOrDefault(id)
  nil

proc remove(impl: ptr PendingImpl; conn: ConnId; id: int) =
  ## Lock must be held. Drops the entry's slot (not the entry itself) and the
  ## connection record once it is empty.
  impl.conns.withValue(conn, byId):
    byId[].del(id)
    if byId[].len == 0:
      impl.conns.del(conn)

proc register*(t: PendingTable; conn: ConnId; id: int) {.gcsafe.} =
  ## Registers `(conn, id)` as awaiting a reply. Call *before* sending the
  ## `call` so a fast reply cannot arrive at an unknown id. The same thread
  ## must then call `wait` or `cancel` exactly once. Registering an id that is
  ## already pending on that connection is a programming error (`doAssert`).
  ## Any thread; O(1) under the table lock.
  doAssert id != NoId, "cannot register a wait for NoId"
  let impl = t.impl
  let e = cast[ptr PendingEntry](allocShared0(sizeof(PendingEntry)))
  initCond e.cond
  e.state = psWaiting
  acquire impl.lock
  if lookup(impl, conn, id) != nil:
    release impl.lock
    freeEntry(e)
    doAssert false, "id " & $id & " is already pending on connection " & $conn
  impl.conns.mgetOrPut(conn, initTable[int, ptr PendingEntry]())[id] = e
  release impl.lock

proc cancel*(t: PendingTable; conn: ConnId; id: int): bool {.gcsafe.} =
  ## Forgets a registered `(conn, id)` without waiting (e.g. the `send`
  ## after `register` failed). Returns `false` if nothing was registered.
  ## Only the thread that registered may cancel. Any later `complete` for
  ## the id returns `false`.
  let impl = t.impl
  acquire impl.lock
  let e = lookup(impl, conn, id)
  if e != nil:
    remove(impl, conn, id)
  release impl.lock
  if e != nil:
    freeEntry(e)
  e != nil

proc wait*(t: PendingTable; conn: ConnId; id: int; timeoutMs: int): JsonNode
    {.gcsafe.} =
  ## Blocks until the reply for `(conn, id)` arrives or `timeoutMs` elapses
  ## (always bounded; `timeoutMs <= 0` just polls once). On return the entry
  ## is gone whatever happened. Returns the `ret` value; raises
  ## `NeelRemoteError` (with the remote `kind` and `msg`) for an `err`,
  ## `NeelDisconnectedError` if the connection closed, `NeelTimeoutError` on
  ## the deadline. A reply that lands while the deadline is being noticed
  ## still wins (the state is re-checked under the lock). Must follow a
  ## `register` on the same thread; waiting on an unregistered id is a
  ## programming error (`doAssert`).
  let impl = t.impl
  let deadline = getMonoTime() + initDuration(milliseconds = max(timeoutMs, 0))
  acquire impl.lock
  let e = lookup(impl, conn, id)
  if e == nil:
    release impl.lock
    doAssert false, "wait for id " & $id & " on connection " & $conn &
                    " without a matching register"
  while e.state == psWaiting:
    let remaining = (deadline - getMonoTime()).inMilliseconds
    if remaining <= 0:
      break
    discard waitTimeout(e.cond, impl.lock, int(remaining))
  remove(impl, conn, id)
  let state = e.state
  var value: JsonNode
  var error: ErrorInfo
  case state
  of psRet: value = move e.value
  of psErr: error = move e.error
  else: discard
  release impl.lock
  freeEntry(e)
  case state
  of psRet:
    value
  of psErr:
    raise (ref NeelRemoteError)(kind: error.kind, msg: error.msg)
  of psDisconnected:
    raise newException(NeelDisconnectedError,
                       "connection " & $conn & " closed while waiting for id " & $id)
  of psWaiting:
    raise newException(NeelTimeoutError,
                       "no reply for id " & $id & " on connection " & $conn &
                       " within " & $timeoutMs & " ms")

proc complete*(t: PendingTable; conn: ConnId; id: int; reply: Msg): bool
    {.gcsafe.} =
  ## Delivers a `ret` or `err` to the waiter for `(conn, id)` and wakes it.
  ## Returns `false`, without raising, when no such wait is pending: the id
  ## is unknown, already cancelled, timed out, or already answered (a late
  ## reply after `onClose` is the expected case). `reply.kind` must be
  ## `msgRet` or `msgErr`. The value is deep-copied into the entry so the
  ## caller may keep using `reply`. Any thread; O(1) under the table lock.
  doAssert reply.kind != msgCall, "complete needs a ret or err message"
  let impl = t.impl
  var copied: JsonNode
  if reply.kind == msgRet:
    copied = (if reply.value.isNil: newJNull() else: copy(reply.value))
  acquire impl.lock
  let e = lookup(impl, conn, id)
  if e == nil or e.state != psWaiting:
    release impl.lock
    return false
  case reply.kind
  of msgRet:
    e.state = psRet
    e.value = move copied
  of msgErr:
    e.state = psErr
    e.error = reply.error
  of msgCall:
    discard
  signal e.cond
  release impl.lock
  true

proc disconnect*(t: PendingTable; conn: ConnId): int {.gcsafe.} =
  ## Fails every pending wait on `conn` with `NeelDisconnectedError` and
  ## returns how many were woken. Unknown connections and already-answered
  ## entries are left alone. The waiters free their own entries, so a
  ## `register` racing this call either lands before (and is failed here) or
  ## after (and its `send` will return `false`; the caller then `cancel`s).
  ## Any thread; O(pending entries on `conn`) under the table lock.
  let impl = t.impl
  acquire impl.lock
  impl.conns.withValue(conn, byId):
    for _, e in byId[]:
      if e.state == psWaiting:
        e.state = psDisconnected
        signal e.cond
        inc result
  release impl.lock

proc pendingCount*(t: PendingTable): int {.gcsafe.} =
  ## Number of registered waits across all connections (for tests and
  ## diagnostics).
  let impl = t.impl
  acquire impl.lock
  for _, byId in impl.conns:
    result += byId.len
  release impl.lock

proc pendingCount*(t: PendingTable; conn: ConnId): int {.gcsafe.} =
  ## Number of registered waits on `conn`.
  let impl = t.impl
  acquire impl.lock
  impl.conns.withValue(conn, byId):
    result = byId[].len
  release impl.lock
