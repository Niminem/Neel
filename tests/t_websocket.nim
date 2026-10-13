## t_websocket.nim - RFC 6455 worked examples, round-trips, split and
## pipelined reads, fragment reassembly with interleaved control frames,
## every malformed category, oversize rejection, close handshake helpers.

import std/[unittest, strutils]
import neel/websocket

const
  # RFC 6455 section 5.7: the masking key used in the masked "Hello" example.
  RfcKey: MaskKey = [0x37'u8, 0xfa, 0x21, 0x3d]
  TestKey: MaskKey = [0x01'u8, 0x02, 0x03, 0x04]

proc bytes(hex: string): string =
  ## Bytes from a spaced hex string, e.g. `"81 05 48"`.
  parseHexStr(hex.replace(" ", ""))

proc hex(s: string): string =
  s.toHex.toLowerAscii

proc decodeAll(data: string; role = frServer;
               maxPayload = DefaultMaxMessageSize): FrameResult =
  ## Decodes `data` in one shot with a fresh decoder.
  var d = initFrameDecoder(role, maxPayload)
  d.decodeFrame(data)

proc decodeCode(data: string; role = frServer;
                maxPayload = DefaultMaxMessageSize): int =
  ## `closeCode` of the `NeelFrameError` raised by decoding `data`, or 0.
  try:
    discard decodeAll(data, role, maxPayload)
    0
  except NeelFrameError as e:
    e.closeCode

proc feedCode(frames: openArray[Frame]; maxMessageSize = DefaultMaxMessageSize): int =
  ## `closeCode` raised while feeding `frames` in order, or 0.
  var a = initMessageAssembler(maxMessageSize)
  try:
    for f in frames:
      discard a.feed(f)
    0
  except NeelFrameError as e:
    e.closeCode

proc closeCode(payload: string): int =
  ## `closeCode` raised by `decodeClose(payload)`, or 0.
  try:
    discard decodeClose(payload)
    0
  except NeelFrameError as e:
    e.closeCode

proc encodeCloseCode(code: int; reason = ""): int =
  ## `closeCode` raised by `encodeClose(code, reason)`, or 0.
  try:
    discard encodeClose(code, reason)
    0
  except NeelFrameError as e:
    e.closeCode

proc text(payload: string; fin = true): Frame =
  Frame(fin: fin, opcode: opText, payload: payload)

proc binary(payload: string; fin = true): Frame =
  Frame(fin: fin, opcode: opBinary, payload: payload)

proc cont(payload: string; fin = true): Frame =
  Frame(fin: fin, opcode: opContinuation, payload: payload)

proc control(opcode: Opcode; payload = ""; fin = true): Frame =
  Frame(fin: fin, opcode: opcode, payload: payload)

suite "websocket RFC 6455 section 5.7 examples":
  test "unmasked text 'Hello'":
    const wire = "81 05 48 65 6c 6c 6f"
    check hex(encodeText("Hello")) == bytes(wire).hex
    let r = decodeAll(bytes(wire), frClient)
    check r.status == fsComplete
    check r.consumed == 7
    check r.frame.fin
    check r.frame.opcode == opText
    check not r.frame.masked
    check r.frame.payload == "Hello"

  test "masked text 'Hello' with key 37 fa 21 3d":
    const wire = "81 85 37 fa 21 3d 7f 9f 4d 51 58"
    check hex(encodeText("Hello", RfcKey)) == bytes(wire).hex
    let r = decodeAll(bytes(wire))
    check r.status == fsComplete
    check r.consumed == 11
    check r.frame.masked
    check r.frame.maskKey == RfcKey
    check r.frame.payload == "Hello"

  test "fragmented 'Hel' + 'lo'":
    check hex(encodeText("Hel", fin = false)) == bytes("01 03 48 65 6c").hex
    check hex(encodeContinuation("lo")) == bytes("80 02 6c 6f").hex
    var d = initFrameDecoder(frClient)
    var a = initMessageAssembler()
    let f1 = d.decodeFrame(bytes("01 03 48 65 6c"))
    check f1.status == fsComplete
    check not f1.frame.fin
    check a.feed(f1.frame).status == asNone
    check a.inProgress
    let f2 = d.decodeFrame(bytes("80 02 6c 6f"))
    check f2.status == fsComplete
    check f2.frame.opcode == opContinuation
    let m = a.feed(f2.frame)
    check m.status == asMessage
    check m.message.kind == mkText
    check m.message.payload == "Hello"
    check not a.inProgress

  test "ping and pong 'Hello'":
    check hex(encodePing("Hello")) == bytes("89 05 48 65 6c 6c 6f").hex
    check hex(encodePong("Hello")) == bytes("8a 05 48 65 6c 6c 6f").hex
    let ping = decodeAll(bytes("89 05 48 65 6c 6c 6f"), frClient).frame
    check ping.opcode == opPing
    check encodePongFor(ping) == encodePong("Hello")
    check hex(encodePongFor(ping, RfcKey)) ==
      bytes("8a 85 37 fa 21 3d 7f 9f 4d 51 58").hex

  test "256-byte binary header (82 7e 01 00)":
    let frame = encodeBinary(repeat('x', 256))
    check hex(frame[0 .. 3]) == bytes("82 7e 01 00").hex
    check frame.len == 260

  test "64 KiB binary header (82 7f 00 00 00 00 00 01 00 00)":
    let frame = encodeBinary(repeat('x', 65536))
    check hex(frame[0 .. 9]) == bytes("82 7f 00 00 00 00 00 01 00 00").hex
    check frame.len == 65546

suite "websocket round-trips":
  test "text and binary at the length-encoding boundaries":
    for n in [0, 125, 126, 65535, 65536]:
      let payload = repeat('a', n)
      let headerLen = if n <= 125: 2 elif n <= 65535: 4 else: 10
      for kind in [opText, opBinary]:
        let wire = encodeFrame(kind, payload)
        check wire.len == headerLen + n
        let r = decodeAll(wire, frClient)
        check r.status == fsComplete
        check r.consumed == wire.len
        check r.frame.opcode == kind
        check r.frame.fin
        check r.frame.payload == payload

  test "masked round-trip with a known key":
    let payload = repeat("0123456789", 100)
    let wire = encodeText(payload, TestKey)
    check wire.len == 4 + 4 + payload.len
    check wire[8 .. ^1] != payload
    check wire[8 .. ^1] == xorMask(payload, TestKey)
    let r = decodeAll(wire)
    check r.status == fsComplete
    check r.consumed == wire.len
    check r.frame.masked
    check r.frame.maskKey == TestKey
    check r.frame.payload == payload

  test "xor mask is symmetric":
    check hex(xorMask("Hello", RfcKey)) == bytes("7f 9f 4d 51 58").hex
    var s = "Hello"
    s.applyMask(RfcKey)
    check s != "Hello"
    s.applyMask(RfcKey)
    check s == "Hello"
    check xorMask(xorMask(repeat('z', 1001), TestKey), TestKey) == repeat('z', 1001)

  test "delivered one byte at a time":
    let payload = repeat('q', 300)  # 16-bit length + masking key: 8-byte header
    let wire = encodeText(payload, TestKey)
    var d = initFrameDecoder()
    var buf = ""
    for i in 0 ..< wire.len - 1:
      buf.add wire[i]
      check d.decodeFrame(buf).status == fsIncomplete
    buf.add wire[^1]
    let r = d.decodeFrame(buf)
    check r.status == fsComplete
    check r.consumed == wire.len
    check r.frame.payload == payload

  test "split inside the extended length and inside the masking key":
    let payload = repeat('q', 300)
    let wire = encodeText(payload, TestKey)
    var d = initFrameDecoder()
    check d.decodeFrame(wire[0 ..< 3]).status == fsIncomplete   # inside 16-bit length
    check d.decodeFrame(wire[0 ..< 6]).status == fsIncomplete   # inside mask key
    check d.decodeFrame(wire[0 ..< 8]).status == fsIncomplete   # header only
    check d.decodeFrame(wire[0 ..< 200]).status == fsIncomplete # partial payload
    let r = d.decodeFrame(wire)
    check r.status == fsComplete
    check r.consumed == wire.len
    check r.frame.payload == payload

  test "split inside the 64-bit length":
    let payload = repeat('w', 65536)
    let wire = encodeBinary(payload, TestKey)
    var d = initFrameDecoder()
    check d.decodeFrame(wire[0 ..< 7]).status == fsIncomplete
    check d.decodeFrame(wire[0 ..< 13]).status == fsIncomplete
    let r = d.decodeFrame(wire)
    check r.status == fsComplete
    check r.consumed == 14 + 65536
    check r.frame.payload == payload

  test "three frames pipelined in one buffer":
    let f1 = encodeText("first", TestKey)
    let f2 = encodePing("p", RfcKey)
    let f3 = encodeClose(CloseNormal, "bye", TestKey)
    var buf = f1 & f2 & f3
    var d = initFrameDecoder()
    let r1 = d.decodeFrame(buf)
    check r1.status == fsComplete
    check r1.consumed == f1.len
    check r1.frame.payload == "first"
    buf.delete(0 ..< r1.consumed)
    let r2 = d.decodeFrame(buf)
    check r2.status == fsComplete
    check r2.consumed == f2.len
    check r2.frame.opcode == opPing
    check r2.frame.payload == "p"
    buf.delete(0 ..< r2.consumed)
    let r3 = d.decodeFrame(buf)
    check r3.status == fsComplete
    check r3.consumed == f3.len
    check r3.frame.opcode == opClose
    check decodeClose(r3.frame) == CloseInfo(code: CloseNormal, reason: "bye")
    buf.delete(0 ..< r3.consumed)
    check buf.len == 0
    check d.decodeFrame(buf).status == fsIncomplete

  test "zero-initialized decoder requires masking":
    var d: FrameDecoder
    check d.decodeFrame(encodeText("x", TestKey)).frame.payload == "x"
    check decodeCode(encodeText("x")) == CloseProtocolError

  test "decoder is reusable after a malformed frame":
    var d = initFrameDecoder()
    expect NeelFrameError:
      discard d.decodeFrame(bytes("91 80 00 00 00 00"))
    let r = d.decodeFrame(encodeText("ok", TestKey))
    check r.status == fsComplete
    check r.frame.payload == "ok"

suite "websocket message assembler":
  test "message reassembled across three fragments":
    var a = initMessageAssembler()
    check a.feed(text("Hel", fin = false)).status == asNone
    check a.feed(cont("lo ", fin = false)).status == asNone
    check a.inProgress
    let m = a.feed(cont("World"))
    check m.status == asMessage
    check m.message.kind == mkText
    check m.message.payload == "Hello World"
    check not a.inProgress

  test "binary message reassembled":
    var a = initMessageAssembler()
    check a.feed(binary("\x00\x01", fin = false)).status == asNone
    let m = a.feed(cont("\xff\xfe"))
    check m.status == asMessage
    check m.message.kind == mkBinary
    check m.message.payload == "\x00\x01\xff\xfe"

  test "single-frame messages complete immediately":
    var a = initMessageAssembler()
    let t = a.feed(text("hi"))
    check t.status == asMessage
    check t.message.kind == mkText
    check t.message.payload == "hi"
    let b = a.feed(binary("\x80"))
    check b.status == asMessage
    check b.message.kind == mkBinary
    let e = a.feed(text(""))
    check e.status == asMessage
    check e.message.payload == ""

  test "ping and close interleaved between fragments":
    var a = initMessageAssembler()
    check a.feed(text("Hel", fin = false)).status == asNone
    let ping = a.feed(control(opPing, "keepalive"))
    check ping.status == asControl
    check ping.control.opcode == opPing
    check ping.control.payload == "keepalive"
    check a.inProgress
    check a.feed(cont("lo ", fin = false)).status == asNone
    let pong = a.feed(control(opPong, "keepalive"))
    check pong.status == asControl
    check pong.control.opcode == opPong
    let close = a.feed(control(opClose, bytes("03 e9") & "going"))
    check close.status == asControl
    check close.control.opcode == opClose
    check decodeClose(close.control) == CloseInfo(code: CloseGoingAway, reason: "going")
    check a.inProgress
    let m = a.feed(cont("World"))
    check m.status == asMessage
    check m.message.payload == "Hello World"

  test "UTF-8 is validated on the complete message, not per fragment":
    var a = initMessageAssembler()
    check a.feed(text("caf\xc3", fin = false)).status == asNone  # split inside 'é'
    let m = a.feed(cont("\xa9"))
    check m.status == asMessage
    check m.message.payload == "café"

  test "reset drops a partial message":
    var a = initMessageAssembler()
    check a.feed(text("abc", fin = false)).status == asNone
    a.reset()
    check not a.inProgress
    check a.feed(text("new")).message.payload == "new"

suite "websocket malformed frames":
  test "RSV bits set":
    check decodeCode(bytes("91 80 00 00 00 00")) == CloseProtocolError  # RSV1
    check decodeCode(bytes("a1 80 00 00 00 00")) == CloseProtocolError  # RSV2
    check decodeCode(bytes("c1 80 00 00 00 00")) == CloseProtocolError  # RSV3
    check decodeCode(bytes("f1 80")) == CloseProtocolError  # detected from the first 2 bytes

  test "reserved opcodes":
    for op in [0x3, 0x4, 0x5, 0x6, 0x7, 0xB, 0xC, 0xD, 0xE, 0xF]:
      check decodeCode(char(0x80 or op) & bytes("80 00 00 00 00")) == CloseProtocolError

  test "unmasked client frame":
    check decodeCode(encodeText("Hello")) == CloseProtocolError
    check decodeCode(bytes("81 05 48 65 6c 6c 6f"), frServer) == CloseProtocolError

  test "masked server frame":
    check decodeCode(encodeText("Hello", RfcKey), frClient) == CloseProtocolError

  test "fragmented control frame":
    check decodeCode(bytes("09 80 00 00 00 00")) == CloseProtocolError  # ping, FIN clear
    check decodeCode(bytes("08 80 00 00 00 00")) == CloseProtocolError  # close, FIN clear
    check feedCode([control(opPing, fin = false)]) == CloseProtocolError

  test "control payload of 126":
    check decodeCode(bytes("89 fe 00 7e")) == CloseProtocolError
    check decodeCode(bytes("89 fe")) == CloseProtocolError  # rejected before the length arrives
    check decodeCode(bytes("88 ff")) == CloseProtocolError
    check feedCode([control(opPong, repeat('x', 126))]) == CloseProtocolError

  test "continuation without a message in progress":
    check feedCode([cont("x")]) == CloseProtocolError
    check feedCode([cont("x", fin = false)]) == CloseProtocolError
    check feedCode([text("done"), cont("x")]) == CloseProtocolError

  test "new data frame while a message is in progress":
    check feedCode([text("a", fin = false), text("b")]) == CloseProtocolError
    check feedCode([text("a", fin = false), binary("b", fin = false)]) == CloseProtocolError
    check feedCode([binary("a", fin = false), text("b")]) == CloseProtocolError

  test "non-minimal 16-bit length":
    check decodeCode(bytes("81 fe 00 7d 01 02 03 04") & repeat('a', 125)) == CloseProtocolError
    check decodeCode(bytes("81 fe 00 00 01 02 03 04")) == CloseProtocolError

  test "non-minimal 64-bit length":
    check decodeCode(bytes("81 ff 00 00 00 00 00 00 ff ff")) == CloseProtocolError
    check decodeCode(bytes("81 ff 00 00 00 00 00 00 00 05")) == CloseProtocolError

  test "64-bit length with the high bit set":
    check decodeCode(bytes("81 ff 80 00 00 00 00 00 00 00")) == CloseProtocolError
    check decodeCode(bytes("81 ff ff ff ff ff ff ff ff ff")) == CloseProtocolError

  test "invalid UTF-8 in a text message":
    check feedCode([text("\xff\xfe")]) == CloseInvalidPayload
    check feedCode([text("ok\xc3", fin = false), cont("\x28")]) == CloseInvalidPayload
    check feedCode([text("\xc3", fin = false), cont("")]) == CloseInvalidPayload
    # Binary carries the same bytes without complaint.
    check feedCode([binary("\xff\xfe")]) == 0

  test "invalid UTF-8 in a close reason":
    check closeCode(bytes("03 e8 ff")) == CloseInvalidPayload
    check feedCode([control(opClose, bytes("03 e8 ff"))]) == CloseInvalidPayload

  test "close payload of exactly 1 byte":
    check closeCode("\x03") == CloseProtocolError
    check feedCode([control(opClose, "\x03")]) == CloseProtocolError

  test "invalid close codes":
    for code in [0, 999, 1004, 1005, 1006, 1012, 1015, 2999, 5000, 65535]:
      let payload = char(code shr 8) & char(code and 0xFF)
      check closeCode(payload) == CloseProtocolError
      check not isValidCloseCode(code)

  test "valid close codes":
    for code in [1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 3000, 4999]:
      let payload = char(code shr 8) & char(code and 0xFF)
      check isValidCloseCode(code)
      check decodeClose(payload).code == code

suite "websocket oversize rejection":
  test "declared frame length above the maximum is rejected before the payload":
    # 16-bit length 1001 with a limit of 1000; only the 8-byte header is present.
    check decodeCode(bytes("82 fe 03 e9 01 02 03 04"), maxPayload = 1000) ==
      CloseMessageTooBig
    # Declared 2^62 bytes: rejected with 1009, not treated as a protocol error.
    check decodeCode(bytes("81 ff 40 00 00 00 00 00 00 00")) == CloseMessageTooBig
    # 7-bit length above a tiny limit.
    check decodeCode(bytes("81 85 01 02 03 04"), maxPayload = 4) == CloseMessageTooBig

  test "declared frame length exactly at the maximum passes":
    let payload = repeat('m', 1000)
    let r = decodeAll(encodeBinary(payload, TestKey), maxPayload = 1000)
    check r.status == fsComplete
    check r.frame.payload == payload

  test "fragments whose total exceeds the maximum":
    check feedCode([text("12345", fin = false), cont("67890", fin = false), cont("1")],
                   maxMessageSize = 10) == CloseMessageTooBig
    check feedCode([text("12345", fin = false), cont("678901")],
                   maxMessageSize = 10) == CloseMessageTooBig

  test "assembled size exactly at the maximum passes":
    var a = initMessageAssembler(10)
    check a.feed(text("12345", fin = false)).status == asNone
    let m = a.feed(cont("67890"))
    check m.status == asMessage
    check m.message.payload == "1234567890"
    check feedCode([text("12345678901")], maxMessageSize = 10) == CloseMessageTooBig
    check feedCode([text("1234567890")], maxMessageSize = 10) == 0

  test "assembler drops the partial message after an error":
    var a = initMessageAssembler(10)
    expect NeelFrameError:
      discard a.feed(text("12345", fin = false))
      discard a.feed(cont("6789012"))
    check not a.inProgress
    check a.feed(text("fresh")).message.payload == "fresh"

suite "websocket close handshake":
  test "close with code and reason round-trips":
    let wire = encodeClose(CloseNormal, "bye")
    check hex(wire) == bytes("88 05 03 e8 62 79 65").hex
    let f = decodeAll(wire, frClient).frame
    check f.opcode == opClose
    check decodeClose(f) == CloseInfo(code: CloseNormal, reason: "bye")

  test "close with no payload round-trips":
    let wire = encodeClose(CloseNoStatus)
    check hex(wire) == "8800"
    check decodeClose(decodeAll(wire, frClient).frame) == CloseInfo(code: CloseNoStatus)
    check decodeClose("") == CloseInfo(code: CloseNoStatus, reason: "")

  test "default close is 1000 with no reason":
    check hex(encodeClose()) == bytes("88 02 03 e8").hex

  test "masked close round-trips":
    let wire = encodeClose(CloseGoingAway, "navigating", TestKey)
    let r = decodeAll(wire)
    check r.status == fsComplete
    check r.frame.masked
    check decodeClose(r.frame) == CloseInfo(code: CloseGoingAway, reason: "navigating")

  test "echo-close helper":
    check encodeCloseReply(CloseInfo(code: CloseGoingAway, reason: "x")) ==
      encodeClose(CloseGoingAway)
    check encodeCloseReply(CloseInfo(code: 4000)) == encodeClose(4000)
    check encodeCloseReply(CloseInfo(code: CloseNoStatus)) == encodeClose(CloseNormal)
    check encodeCloseReply(CloseInfo(code: CloseNoStatus), TestKey) ==
      encodeClose(CloseNormal, "", TestKey)
    check decodeClose(decodeAll(encodeCloseReply(decodeClose("")), frClient).frame).code ==
      CloseNormal

  test "encoder refuses codes and reasons that must not go on the wire":
    check encodeCloseCode(CloseNoStatus, "x") == CloseInternalError
    check encodeCloseCode(CloseAbnormal) == CloseInternalError
    check encodeCloseCode(CloseTlsHandshake) == CloseInternalError
    check encodeCloseCode(999) == CloseInternalError
    check encodeCloseCode(CloseNormal, repeat('r', 124)) == CloseInternalError
    check encodeCloseCode(CloseNormal, repeat('r', 123)) == 0
    check encodeCloseCode(CloseNormal, "\xff") == CloseInternalError
    check encodeCloseCode(4999, "custom") == 0

  test "encoder refuses invalid control frames":
    expect NeelFrameError:
      discard encodeFrame(opPing, "", fin = false)
    expect NeelFrameError:
      discard encodePing(repeat('p', 126))
    check encodePing(repeat('p', 125)).len == 127
