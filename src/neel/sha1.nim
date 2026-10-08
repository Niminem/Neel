## sha1.nim - SHA-1 digest for the WebSocket opening handshake. No IO here.
##
## Neel has zero external dependencies and `std/sha1` is deprecated, so the
## digest is hand-rolled here following RFC 3174 / FIPS 180-1. Its single
## consumer is the computation of the `Sec-WebSocket-Accept` header
## (RFC 6455 section 4.2.2): SHA-1 over the client key concatenated with the
## fixed GUID, then `std/base64`.
##
## SHA-1 is not collision resistant and must not be used here for anything
## security-relevant beyond the handshake, where the protocol mandates it.

import std/base64

type
  Sha1Digest* = distinct array[20, byte]
    ## Raw 160-bit SHA-1 digest. `$` renders it as 40 lowercase hex digits.

  Sha1State = object
    ## Incremental hashing state: chaining values, a partial block, and the
    ## total number of bytes absorbed so far (needed for the length suffix).
    h: array[5, uint32]
    buf: array[64, byte]
    bufLen: int
    totalLen: uint64

const
  WebSocketGuid* = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    ## Fixed GUID appended to the client key by RFC 6455 section 1.3.

proc rol(x: uint32; n: int): uint32 {.inline.} =
  (x shl n) or (x shr (32 - n))

proc initSha1State(): Sha1State =
  result.h = [0x67452301'u32, 0xEFCDAB89'u32, 0x98BADCFE'u32,
              0x10325476'u32, 0xC3D2E1F0'u32]

proc processBlock(s: var Sha1State; blk: openArray[byte]) =
  ## Compresses one 64-byte block into the chaining values.
  assert blk.len == 64
  var w: array[80, uint32]
  for i in 0 ..< 16:
    w[i] = (uint32(blk[4 * i]) shl 24) or (uint32(blk[4 * i + 1]) shl 16) or
           (uint32(blk[4 * i + 2]) shl 8) or uint32(blk[4 * i + 3])
  for i in 16 ..< 80:
    w[i] = rol(w[i - 3] xor w[i - 8] xor w[i - 14] xor w[i - 16], 1)

  var
    a = s.h[0]
    b = s.h[1]
    c = s.h[2]
    d = s.h[3]
    e = s.h[4]
  for i in 0 ..< 80:
    var f, k: uint32
    if i < 20:
      f = (b and c) or ((not b) and d)
      k = 0x5A827999'u32
    elif i < 40:
      f = b xor c xor d
      k = 0x6ED9EBA1'u32
    elif i < 60:
      f = (b and c) or (b and d) or (c and d)
      k = 0x8F1BBCDC'u32
    else:
      f = b xor c xor d
      k = 0xCA62C1D6'u32
    let temp = rol(a, 5) + f + e + k + w[i]
    e = d
    d = c
    c = rol(b, 30)
    b = a
    a = temp

  s.h[0] += a
  s.h[1] += b
  s.h[2] += c
  s.h[3] += d
  s.h[4] += e

proc update(s: var Sha1State; data: openArray[byte]) =
  ## Absorbs `data`, compressing every completed 64-byte block.
  s.totalLen += uint64(data.len)
  var pos = 0
  if s.bufLen > 0:
    while s.bufLen < 64 and pos < data.len:
      s.buf[s.bufLen] = data[pos]
      inc s.bufLen
      inc pos
    if s.bufLen == 64:
      s.processBlock(s.buf)
      s.bufLen = 0
  while pos + 64 <= data.len:
    s.processBlock(data.toOpenArray(pos, pos + 63))
    pos += 64
  while pos < data.len:
    s.buf[s.bufLen] = data[pos]
    inc s.bufLen
    inc pos

proc finalize(s: var Sha1State): Sha1Digest =
  ## Appends the RFC 3174 padding (0x80, zeros to 56 mod 64, 64-bit big-endian
  ## bit length) and returns the digest. `s` must not be used afterwards.
  let bitLen = s.totalLen * 8
  s.update([0x80'u8])
  while s.bufLen != 56:
    s.update([0x00'u8])
  var lenBytes: array[8, byte]
  for i in 0 ..< 8:
    lenBytes[i] = byte(bitLen shr (56 - 8 * i))
  s.update(lenBytes)
  assert s.bufLen == 0
  var digest: array[20, byte]
  for i in 0 ..< 5:
    digest[4 * i] = byte(s.h[i] shr 24)
    digest[4 * i + 1] = byte(s.h[i] shr 16)
    digest[4 * i + 2] = byte(s.h[i] shr 8)
    digest[4 * i + 3] = byte(s.h[i])
  Sha1Digest(digest)

proc sha1*(data: openArray[byte]): Sha1Digest =
  ## Computes the SHA-1 digest of `data`.
  var s = initSha1State()
  s.update(data)
  s.finalize()

proc sha1*(data: string): Sha1Digest =
  ## Computes the SHA-1 digest of the bytes of `data`.
  sha1(data.toOpenArrayByte(0, data.high))

proc `==`*(a, b: Sha1Digest): bool =
  ## Byte-wise digest equality.
  array[20, byte](a) == array[20, byte](b)

proc `$`*(d: Sha1Digest): string =
  ## Renders `d` as 40 lowercase hexadecimal digits.
  const hexDigits = "0123456789abcdef"
  result = newString(40)
  for i, b in array[20, byte](d):
    result[2 * i] = hexDigits[int(b shr 4)]
    result[2 * i + 1] = hexDigits[int(b and 0x0F)]

proc webSocketAccept*(key: string): string =
  ## Computes the `Sec-WebSocket-Accept` value for a client's
  ## `Sec-WebSocket-Key` per RFC 6455 section 4.2.2: base64 of the SHA-1 of
  ## the key (as received, untrimmed) concatenated with `WebSocketGuid`.
  base64.encode(array[20, byte](sha1(key & WebSocketGuid)))
