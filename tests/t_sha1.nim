## t_sha1.nim - RFC 3174 digest vectors and the RFC 6455 handshake key.

import std/[unittest, strutils, sequtils]
import neel/sha1

suite "sha1":
  # RFC 3174 section 7.3 test vectors (TEST1..TEST4). The RFC prints them in
  # uppercase; Neel renders lowercase.
  test "RFC 3174 vector 1: abc":
    check $sha1("abc") == "a9993e364706816aba3e25717850c26c9cd0d89d"

  test "RFC 3174 vector 2: 56-byte message (padding forces a second block)":
    check $sha1("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
      "84983e441c3bd26ebaae4aa1f95129e5e54670f1"

  test "RFC 3174 vector 3: one million 'a'":
    check $sha1(repeat('a', 1_000_000)) ==
      "34aa973cd4c4daa4f61eeb2bdbad27316534016f"

  test "RFC 3174 vector 4: 640 bytes (exactly ten blocks)":
    let msg = repeat("01234567", 80)
    check msg.len == 640
    check $sha1(msg) == "dea356a2cddd90c7a7ecedc5ebb563934f460452"

  # Block-boundary lengths around the 55/56 padding split and the 64-byte
  # block size. Reference values generated with `shasum -a 1` (macOS, Perl
  # Digest::SHA); the empty-string digest is also the FIPS 180 published value.
  test "empty message":
    check $sha1("") == "da39a3ee5e6b4b0d3255bfef95601890afd80709"

  test "block-boundary lengths of 'a'":
    const vectors = [
      (55, "c1c8bbdc22796e28c0e15163d20899b65621d65a"),  # last length that pads in one block
      (56, "c2db330f6083854c99d4b5bfb6e8f29f201be699"),  # first length needing a second block
      (63, "03f09f5b158a7a8cdad920bddc29b81c18a551f5"),
      (64, "0098ba824b5c16427bd7a1122a5a442a25ec644d"),  # exactly one block
      (65, "11655326c708d70319be2610e8a57d9a5b959d3b"),
      (119, "ee971065aaa017e0632a8ca6c77bb3bf8b1dfc56"),
      (120, "f34c1488385346a55709ba056ddd08280dd4c6d6"),
      (128, "ad5b3fdbcb526778c2839d2f151ea753995e26a0"),  # exactly two blocks
    ]
    for (n, expected) in vectors:
      check $sha1(repeat('a', n)) == expected

  test "openArray[byte] input matches string input":
    let bytes = "abc".mapIt(byte(it))
    check sha1(bytes) == sha1("abc")
    check $sha1([0x61'u8, 0x62, 0x63]) == "a9993e364706816aba3e25717850c26c9cd0d89d"
    var empty: seq[byte]
    check sha1(empty) == sha1("")

  test "digest equality and hex rendering":
    check sha1("abc") == sha1("abc")
    check not (sha1("abc") == sha1("abd"))
    check ($sha1("abc")).len == 40
    check ($sha1("abc")).allCharsInSet({'0'..'9', 'a'..'f'})

suite "webSocketAccept":
  # RFC 6455 section 1.3 / 4.2.2 worked example.
  test "RFC 6455 example key":
    check webSocketAccept("dGhlIHNhbXBsZSBub25jZQ==") ==
      "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

  test "RFC 6455 example intermediate digest":
    check $sha1("dGhlIHNhbXBsZSBub25jZQ==" & WebSocketGuid) ==
      "b37a4f2cc0624f1690f64606cf385945b2bec4ea"

  test "key is used as received (no trimming)":
    check webSocketAccept(" dGhlIHNhbXBsZSBub25jZQ==") !=
      "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
