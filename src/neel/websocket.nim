## websocket.nim - RFC 6455 frame encoding and decoding. No socket IO here.
##
## Pure byte-level logic so it can be unit tested with split reads and
## pipelined input. `server.nim` owns a growing receive buffer per connection,
## hands it to `decodeFrame` after every read, drops `consumed` bytes on a
## complete frame, passes the frame to `feed` on the connection's
## `MessageAssembler`, and sends whatever the `encode*` procs return.
##
## Surface:
## - `FrameDecoder` + `decodeFrame`: incremental decoder for one frame.
##   Reports `fsIncomplete` (append more bytes and call again) or `fsComplete`
##   with the number of bytes consumed (so several frames in one buffer work).
##   The parsed header is kept between calls so a growing buffer is never
##   re-scanned. Masking is enforced by role: client-to-server frames must be
##   masked, server-to-client frames must not be. A declared payload length
##   above the configured maximum is rejected before any payload is buffered.
## - `MessageAssembler` + `feed`: reassembles fragmented text/binary messages
##   up to a configurable maximum size, lets ping/pong/close interleave with
##   fragments, validates text as UTF-8 once complete, and reports complete
##   messages and control frames separately.
## - `encodeFrame` and the `encodeText` / `encodeBinary` / `encodeContinuation`
##   / `encodePing` / `encodePong` / `encodeClose` wrappers, each with an
##   overload that masks with a caller-supplied `MaskKey` (for scripted
##   clients and tests; this module never generates keys).
## - Close handshake helpers: `decodeClose`, `encodeCloseReply`,
##   `isValidCloseCode`, and the `Close*` status-code constants.
## - `applyMask` / `xorMask`: the symmetric XOR used for masking.
##
## Malformed or oversized input raises `NeelFrameError`, whose `closeCode`
## (1002 protocol error, 1007 invalid UTF-8, 1009 message too big) is the
## status the server should send in its close frame. "Need more data" is
## always a status result, never an exception.
##
## Binary frames are decoded and reassembled exactly like text frames (minus
## the UTF-8 check). Neel's protocol uses text frames only, but whether to
## accept binary is a protocol decision, so rejecting binary messages with
## close code 1003 is left to `server.nim` / `protocol.nim`.

import std/unicode

const
  DefaultMaxMessageSize* = 16 * 1024 * 1024
    ## Default limit for a single frame payload and for an assembled message.
  MaxControlPayload* = 125
    ## Largest payload a control frame (close, ping, pong) may carry
    ## (RFC 6455 section 5.5).
  MaxFrameHeader* = 14
    ## Largest possible frame header: 2 bytes + 8-byte length + 4-byte key.

  # Close status codes (RFC 6455 section 7.4.1).
  CloseNormal* = 1000             ## Normal closure.
  CloseGoingAway* = 1001          ## Endpoint is going away (page navigated, server shutting down).
  CloseProtocolError* = 1002      ## Protocol error (malformed frame).
  CloseUnsupportedData* = 1003    ## Data type the endpoint cannot accept (e.g. binary).
  CloseNoStatus* = 1005           ## Reserved: no status code was present. Never sent on the wire.
  CloseAbnormal* = 1006           ## Reserved: connection lost without a close frame. Never sent.
  CloseInvalidPayload* = 1007     ## Payload inconsistent with its type (invalid UTF-8 in text).
  ClosePolicyViolation* = 1008    ## Generic policy violation.
  CloseMessageTooBig* = 1009      ## Message exceeds the configured maximum.
  CloseMandatoryExtension* = 1010 ## Client expected an extension the server did not negotiate.
  CloseInternalError* = 1011      ## Server hit an unexpected condition.
  CloseTlsHandshake* = 1015       ## Reserved: TLS handshake failure. Never sent.

type
  NeelFrameError* = object of CatchableError
    ## Raised on malformed or oversized frames and messages.
    closeCode*: int ## Status the server should send in its close frame.

  Opcode* = enum
    ## Frame opcode (RFC 6455 section 5.2). Reserved values are rejected by
    ## the decoder and never appear in a `Frame`.
    opContinuation = 0x0
    opText = 0x1
    opBinary = 0x2
    opClose = 0x8
    opPing = 0x9
    opPong = 0xA

  MaskKey* = array[4, byte]
    ## The 4-byte masking key of a client-to-server frame.

  Frame* = object
    ## One decoded frame. `payload` is already unmasked.
    fin*: bool
    opcode*: Opcode
    masked*: bool     ## Whether the frame carried a masking key on the wire.
    maskKey*: MaskKey ## Zero when `masked` is false.
    payload*: string

  FrameStatus* = enum
    fsIncomplete ## More bytes are needed; keep the buffer and call again.
    fsComplete   ## `frame` is valid and `consumed` bytes can be dropped.

  FrameResult* = object
    status*: FrameStatus
    consumed*: int ## Bytes of the buffer that made up the frame (fsComplete).
    frame*: Frame

  FrameRole* = enum
    ## Which direction a decoder reads. Determines the masking rule.
    frServer ## Decodes client-to-server frames: masking is required.
    frClient ## Decodes server-to-client frames: masking is forbidden.

  FrameDecoder* = object
    ## Incremental state for one connection. Between `fsIncomplete` results
    ## the caller must only append to the buffer; after `fsComplete` the
    ## decoder has reset itself and the caller drops `consumed` bytes. After a
    ## `NeelFrameError` the decoder is also reset, but the connection should
    ## be closed. A zero-initialized decoder behaves like
    ## `initFrameDecoder(frServer, DefaultMaxMessageSize)`.
    role: FrameRole
    maxPayload: int
    headerLen: int  # 0 until the header has been fully parsed
    payloadLen: int
    header: Frame   # fin/opcode/masked/maskKey; payload empty

  MessageKind* = enum
    mkText   ## UTF-8 text message.
    mkBinary ## Binary message (bytes in a `string`).

  Message* = object
    ## A complete, reassembled data message.
    kind*: MessageKind
    payload*: string

  AssembleStatus* = enum
    asNone    ## A fragment was absorbed; nothing to deliver yet.
    asMessage ## `message` holds a complete data message.
    asControl ## `control` holds a ping, pong, or close frame.

  AssembleResult* = object
    status*: AssembleStatus
    message*: Message ## Valid when `status == asMessage`.
    control*: Frame   ## Valid when `status == asControl`.

  MessageAssembler* = object
    ## Reassembly state for one connection. A zero-initialized assembler uses
    ## `DefaultMaxMessageSize`.
    maxMessageSize: int
    inProgress: bool
    kind: MessageKind
    buffer: string

  CloseInfo* = object
    ## Decoded close frame payload.
    code*: int      ## `CloseNoStatus` (1005) when the payload was empty.
    reason*: string ## UTF-8 reason, `""` when absent.

# --- errors --------------------------------------------------------------------

proc newFrameError(closeCode: int; msg: string): ref NeelFrameError =
  result = newException(NeelFrameError, msg)
  result.closeCode = closeCode

template fail(closeCode: int; msg: string) =
  raise newFrameError(closeCode, msg)

# --- masking -------------------------------------------------------------------

proc applyMask*(data: var string; key: MaskKey) =
  ## XORs `data` in place with `key` repeated every four bytes (RFC 6455
  ## section 5.3). Masking and unmasking are the same operation.
  for i in 0 ..< data.len:
    data[i] = char(byte(data[i]) xor key[i and 3])

proc xorMask*(data: string; key: MaskKey): string =
  ## Copy of `data` masked (or unmasked) with `key`.
  result = data
  result.applyMask(key)

# --- opcodes -------------------------------------------------------------------

proc isControl*(opcode: Opcode): bool =
  ## Whether `opcode` is a control frame (close, ping, pong).
  ord(opcode) >= 0x8

proc toOpcode(raw: byte): Opcode =
  case raw
  of 0x0: opContinuation
  of 0x1: opText
  of 0x2: opBinary
  of 0x8: opClose
  of 0x9: opPing
  of 0xA: opPong
  else: fail(CloseProtocolError, "reserved opcode 0x" & $raw)

# --- close codes -------------------------------------------------------------

proc isValidCloseCode*(code: int): bool =
  ## Whether `code` may appear in a close frame on the wire: 1000-1003,
  ## 1007-1011, and 3000-4999 (RFC 6455 section 7.4). Everything else,
  ## including the reserved 1004/1005/1006/1015 and the unassigned 1012-2999
  ## range, is rejected with 1002.
  code in 1000 .. 1003 or code in 1007 .. 1011 or code in 3000 .. 4999

proc decodeClose*(payload: string): CloseInfo =
  ## Interprets a close frame payload: 2-byte big-endian status code followed
  ## by a UTF-8 reason. An empty payload yields `CloseNoStatus`. Raises 1002
  ## for a 1-byte payload or an invalid code and 1007 for a reason that is
  ## not valid UTF-8.
  if payload.len == 0:
    return CloseInfo(code: CloseNoStatus)
  if payload.len == 1:
    fail(CloseProtocolError, "close payload of exactly 1 byte")
  let code = int(byte(payload[0])) shl 8 or int(byte(payload[1]))
  if not isValidCloseCode(code):
    fail(CloseProtocolError, "invalid close code " & $code)
  result = CloseInfo(code: code, reason: payload[2 .. ^1])
  if validateUtf8(result.reason) >= 0:
    fail(CloseInvalidPayload, "close reason is not valid UTF-8")

proc decodeClose*(frame: Frame): CloseInfo =
  ## `decodeClose` on the payload of a close frame.
  doAssert frame.opcode == opClose, "decodeClose needs a close frame"
  decodeClose(frame.payload)

proc closePayload(code: int; reason: string): string =
  ## Builds a close payload, validating what the encoder is asked to send.
  if code == CloseNoStatus:
    if reason.len > 0:
      fail(CloseInternalError, "a close frame without a status code cannot carry a reason")
    return ""
  if not isValidCloseCode(code):
    fail(CloseInternalError, "close code " & $code & " must not be sent on the wire")
  if reason.len > MaxControlPayload - 2:
    fail(CloseInternalError, "close reason exceeds " & $(MaxControlPayload - 2) & " bytes")
  if validateUtf8(reason) >= 0:
    fail(CloseInternalError, "close reason is not valid UTF-8")
  result = newStringOfCap(2 + reason.len)
  result.add char(byte(code shr 8))
  result.add char(byte(code and 0xFF))
  result.add reason

# --- encoding ------------------------------------------------------------------

proc encodeFrameImpl(opcode: Opcode; payload: string; fin, masked: bool;
                     key: MaskKey): string =
  if isControl(opcode):
    if not fin:
      fail(CloseInternalError, "control frames cannot be fragmented")
    if payload.len > MaxControlPayload:
      fail(CloseInternalError, "control frame payload exceeds " & $MaxControlPayload & " bytes")
  result = newStringOfCap(MaxFrameHeader + payload.len)
  var b0 = byte(ord(opcode))
  if fin:
    b0 = b0 or 0x80
  result.add char(b0)
  let maskBit: byte = if masked: 0x80 else: 0
  let n = payload.len
  if n <= 125:
    result.add char(maskBit or byte(n))
  elif n <= 0xFFFF:
    result.add char(maskBit or 126)
    result.add char(byte(n shr 8))
    result.add char(byte(n and 0xFF))
  else:
    result.add char(maskBit or 127)
    for shift in countdown(56, 0, 8):
      result.add char(byte((uint64(n) shr shift) and 0xFF))
  if masked:
    for b in key:
      result.add char(b)
    result.add xorMask(payload, key)
  else:
    result.add payload

proc encodeFrame*(opcode: Opcode; payload: string; fin = true): string =
  ## One unmasked frame (server-to-client) with the minimal length encoding.
  ## Raises `NeelFrameError` (1011) for a fragmented control frame or a
  ## control payload above `MaxControlPayload`.
  encodeFrameImpl(opcode, payload, fin, false, default(MaskKey))

proc encodeFrame*(opcode: Opcode; payload: string; maskKey: MaskKey;
                  fin = true): string =
  ## One frame masked with `maskKey` (client-to-server). The key is used as
  ## given; this module never generates keys.
  encodeFrameImpl(opcode, payload, fin, true, maskKey)

proc encodeText*(payload: string; fin = true): string =
  ## Unmasked text frame; `fin = false` starts a fragmented message.
  encodeFrame(opText, payload, fin)

proc encodeText*(payload: string; maskKey: MaskKey; fin = true): string =
  ## Masked text frame.
  encodeFrame(opText, payload, maskKey, fin)

proc encodeBinary*(payload: string; fin = true): string =
  ## Unmasked binary frame; `fin = false` starts a fragmented message.
  encodeFrame(opBinary, payload, fin)

proc encodeBinary*(payload: string; maskKey: MaskKey; fin = true): string =
  ## Masked binary frame.
  encodeFrame(opBinary, payload, maskKey, fin)

proc encodeContinuation*(payload: string; fin = true): string =
  ## Unmasked continuation frame; `fin = true` ends the message.
  encodeFrame(opContinuation, payload, fin)

proc encodeContinuation*(payload: string; maskKey: MaskKey; fin = true): string =
  ## Masked continuation frame.
  encodeFrame(opContinuation, payload, maskKey, fin)

proc encodePing*(payload = ""): string =
  ## Unmasked ping carrying `payload` (at most `MaxControlPayload` bytes).
  encodeFrame(opPing, payload)

proc encodePing*(payload: string; maskKey: MaskKey): string =
  ## Masked ping.
  encodeFrame(opPing, payload, maskKey)

proc encodePong*(payload = ""): string =
  ## Unmasked pong carrying `payload`. Answer a ping with the ping's payload
  ## verbatim (see `encodePongFor`).
  encodeFrame(opPong, payload)

proc encodePong*(payload: string; maskKey: MaskKey): string =
  ## Masked pong.
  encodeFrame(opPong, payload, maskKey)

proc encodePongFor*(ping: Frame): string =
  ## Unmasked pong answering `ping` with its payload verbatim (RFC 6455
  ## section 5.5.3).
  doAssert ping.opcode == opPing, "encodePongFor needs a ping frame"
  encodePong(ping.payload)

proc encodePongFor*(ping: Frame; maskKey: MaskKey): string =
  ## Masked pong answering `ping`.
  doAssert ping.opcode == opPing, "encodePongFor needs a ping frame"
  encodePong(ping.payload, maskKey)

proc encodeClose*(code = CloseNormal; reason = ""): string =
  ## Unmasked close frame. `CloseNoStatus` with an empty reason produces an
  ## empty payload. Raises `NeelFrameError` (1011) for a code that must not
  ## appear on the wire (see `isValidCloseCode`), a reason longer than 123
  ## bytes, or a reason that is not valid UTF-8.
  encodeFrame(opClose, closePayload(code, reason))

proc encodeClose*(code: int; reason: string; maskKey: MaskKey): string =
  ## Masked close frame.
  encodeFrame(opClose, closePayload(code, reason), maskKey)

proc encodeCloseReply*(received: CloseInfo): string =
  ## The unmasked close frame to echo back after receiving `received`: the
  ## same code with no reason, or `CloseNormal` when the peer sent no code
  ## (RFC 6455 section 5.5.1).
  encodeClose(if received.code == CloseNoStatus: CloseNormal else: received.code)

proc encodeCloseReply*(received: CloseInfo; maskKey: MaskKey): string =
  ## Masked variant of `encodeCloseReply`.
  encodeClose(if received.code == CloseNoStatus: CloseNormal else: received.code,
              "", maskKey)

# --- decoding ------------------------------------------------------------------

proc initFrameDecoder*(role = frServer;
                       maxPayload = DefaultMaxMessageSize): FrameDecoder =
  ## A decoder for `role` that rejects frames whose declared payload length
  ## exceeds `maxPayload` (1009) before buffering any of it. Use the same
  ## value as the connection's `MessageAssembler`.
  FrameDecoder(role: role, maxPayload: maxPayload)

proc reset*(d: var FrameDecoder) =
  ## Forgets any partially parsed header, keeping role and limit.
  d.headerLen = 0
  d.payloadLen = 0
  d.header = Frame()

proc limit(d: FrameDecoder): int =
  if d.maxPayload > 0: d.maxPayload else: DefaultMaxMessageSize

proc parseHeader(d: var FrameDecoder; buf: openArray[char]): bool =
  ## Parses the header at the start of `buf` into `d`. Returns false when more
  ## bytes are needed. Validates each field as soon as its bytes are present.
  if buf.len < 2:
    return false
  let b0 = byte(buf[0])
  let b1 = byte(buf[1])
  if (b0 and 0x70) != 0:
    fail(CloseProtocolError, "RSV bits set without a negotiated extension")
  let opcode = toOpcode(b0 and 0x0F)
  let fin = (b0 and 0x80) != 0
  let masked = (b1 and 0x80) != 0
  let len7 = int(b1 and 0x7F)
  if isControl(opcode):
    if not fin:
      fail(CloseProtocolError, "fragmented control frame")
    if len7 > MaxControlPayload:
      fail(CloseProtocolError, "control frame payload exceeds " & $MaxControlPayload & " bytes")
  case d.role
  of frServer:
    if not masked:
      fail(CloseProtocolError, "client-to-server frame is not masked")
  of frClient:
    if masked:
      fail(CloseProtocolError, "server-to-client frame is masked")
  var pos = 2
  var length: uint64
  case len7
  of 126:
    if buf.len < 4:
      return false
    length = uint64(byte(buf[2])) shl 8 or uint64(byte(buf[3]))
    if length < 126:
      fail(CloseProtocolError, "non-minimal 16-bit payload length")
    pos = 4
  of 127:
    if buf.len < 10:
      return false
    for i in 2 .. 9:
      length = length shl 8 or uint64(byte(buf[i]))
    if (length and (1'u64 shl 63)) != 0:
      fail(CloseProtocolError, "64-bit payload length with the high bit set")
    if length < 65536:
      fail(CloseProtocolError, "non-minimal 64-bit payload length")
    pos = 10
  else:
    length = uint64(len7)
  if length > uint64(d.limit):
    fail(CloseMessageTooBig, "payload of " & $length & " bytes exceeds the maximum of " &
                             $d.limit & " bytes")
  var key: MaskKey
  if masked:
    if buf.len < pos + 4:
      return false
    for i in 0 .. 3:
      key[i] = byte(buf[pos + i])
    pos += 4
  d.headerLen = pos
  d.payloadLen = int(length)
  d.header = Frame(fin: fin, opcode: opcode, masked: masked, maskKey: key)
  true

proc decodeFrame*(d: var FrameDecoder; buf: openArray[char]): FrameResult =
  ## Decodes the frame at the start of `buf`. Returns `fsIncomplete` when more
  ## bytes are needed (append to `buf` and call again) or `fsComplete` with
  ## `consumed` set to the frame's total length and `frame.payload` unmasked.
  ## Raises `NeelFrameError` for RSV bits, reserved opcodes, a masking
  ## violation for the decoder's role, a fragmented or oversized control
  ## frame, a non-minimal or high-bit 64-bit length (all 1002), or a declared
  ## payload above the configured maximum (1009). Header fields are checked
  ## as soon as they arrive, and the parsed header is kept between calls so
  ## the payload is never rescanned.
  if d.headerLen == 0:
    try:
      if not d.parseHeader(buf):
        return FrameResult(status: fsIncomplete)
    except NeelFrameError:
      d.reset()
      raise
  let total = d.headerLen + d.payloadLen
  if buf.len < total:
    return FrameResult(status: fsIncomplete)
  var frame = d.header
  frame.payload = newString(d.payloadLen)
  if d.payloadLen > 0:
    copyMem(addr frame.payload[0], unsafeAddr buf[d.headerLen], d.payloadLen)
    if frame.masked:
      frame.payload.applyMask(frame.maskKey)
  result = FrameResult(status: fsComplete, consumed: total, frame: frame)
  d.reset()

# --- message assembly ----------------------------------------------------------

proc initMessageAssembler*(maxMessageSize = DefaultMaxMessageSize): MessageAssembler =
  ## An assembler that rejects messages larger than `maxMessageSize` (1009).
  MessageAssembler(maxMessageSize: maxMessageSize)

proc inProgress*(a: MessageAssembler): bool =
  ## Whether a fragmented message has started and not yet finished.
  a.inProgress

proc reset*(a: var MessageAssembler) =
  ## Drops any partial message, keeping the size limit.
  a.inProgress = false
  a.buffer = ""

proc limit(a: MessageAssembler): int =
  if a.maxMessageSize > 0: a.maxMessageSize else: DefaultMaxMessageSize

proc assemblerFail(a: var MessageAssembler; closeCode: int; msg: string) =
  a.reset()
  fail(closeCode, msg)

proc complete(kind: MessageKind; payload: sink string): AssembleResult =
  if kind == mkText and validateUtf8(payload) >= 0:
    fail(CloseInvalidPayload, "text message is not valid UTF-8")
  AssembleResult(status: asMessage, message: Message(kind: kind, payload: payload))

proc feed*(a: var MessageAssembler; frame: Frame): AssembleResult =
  ## Consumes one decoded frame. Control frames are returned as `asControl`
  ## immediately, even in the middle of a fragmented message (a close frame's
  ## payload is validated; see `decodeClose`). A final text/binary frame is
  ## returned as `asMessage`; a non-final one starts a message and
  ## continuation frames extend it until `fin`. Raises `NeelFrameError` for a
  ## continuation with no message in progress or a new text/binary frame
  ## while one is in progress (1002), an assembled size above the maximum
  ## (1009, raised before the oversize fragment is buffered), and a complete
  ## text message that is not valid UTF-8 (1007). On any error the partial
  ## message is dropped.
  case frame.opcode
  of opClose, opPing, opPong:
    if not frame.fin:
      a.assemblerFail(CloseProtocolError, "fragmented control frame")
    if frame.payload.len > MaxControlPayload:
      a.assemblerFail(CloseProtocolError, "control frame payload exceeds " & $MaxControlPayload & " bytes")
    if frame.opcode == opClose:
      try:
        discard decodeClose(frame.payload)
      except NeelFrameError:
        a.reset()
        raise
    AssembleResult(status: asControl, control: frame)
  of opText, opBinary:
    if a.inProgress:
      a.assemblerFail(CloseProtocolError, "new data frame while a fragmented message is in progress")
    if frame.payload.len > a.limit:
      a.assemblerFail(CloseMessageTooBig, "message exceeds the maximum of " & $a.limit & " bytes")
    let kind = if frame.opcode == opText: mkText else: mkBinary
    if frame.fin:
      return complete(kind, frame.payload)
    a.inProgress = true
    a.kind = kind
    a.buffer = frame.payload
    AssembleResult(status: asNone)
  of opContinuation:
    if not a.inProgress:
      a.assemblerFail(CloseProtocolError, "continuation frame without a message in progress")
    if a.buffer.len + frame.payload.len > a.limit:
      a.assemblerFail(CloseMessageTooBig, "message exceeds the maximum of " & $a.limit & " bytes")
    a.buffer.add frame.payload
    if not frame.fin:
      return AssembleResult(status: asNone)
    let kind = a.kind
    let payload = move(a.buffer)
    a.reset()
    complete(kind, payload)
