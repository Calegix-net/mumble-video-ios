#!/usr/bin/env python3
# Copyright The Mumble Developers. All rights reserved.
# Use of this source code is governed by a BSD-style license
# that can be found in the LICENSE file at the root of the
# Mumble source tree or at <https://www.mumble.info/LICENSE>.

"""Writes the known-answer vectors in this directory.

This is a second, independent implementation of the media crypto, written from the C++ rather than
linked to it: OCB2-AES128 (as CryptStateOCB2 implements it, including the XEX* countermeasure), the
audio datagram, the video datagram and the video key derivation. TestMumbleCore checks the C++
against the files this writes, and any other implementation (the Android client, say) can check
itself against the same files.

Needs the `cryptography` package. Run it from anywhere; it writes next to itself.
"""

import hashlib
import json
import os
import struct

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

BLOCK = 16


def aes(key, block):
    enc = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
    return enc.update(block) + enc.finalize()


def xor(a, b):
    return bytes(x ^ y for x, y in zip(a, b))


def times2(block):
    # Doubling in GF(2^128), big-endian, as S2 in CryptStateOCB2.cpp.
    v = int.from_bytes(block, "big")
    carry = v >> 127
    v = ((v << 1) & ((1 << 128) - 1)) ^ (carry * 0x87)
    return v.to_bytes(16, "big")


def times3(block):
    return xor(block, times2(block))


def ocb2_encrypt(key, nonce, plain):
    """Returns (ciphertext, tag) exactly as CryptStateOCB2::ocb_encrypt with the countermeasure on."""
    delta = aes(key, nonce)
    checksum = bytes(BLOCK)
    out = b""
    rest = plain
    while len(rest) > BLOCK:
        block = rest[:BLOCK]
        # https://eprint.iacr.org/2019/311 section 9: the second to last block may not be all zero but for
        # its last byte, so its first bit is flipped (which also changes what the receiver decrypts).
        if len(rest) - BLOCK <= BLOCK and not any(block[:BLOCK - 1]):
            block = bytes([block[0] ^ 1]) + block[1:]
        delta = times2(delta)
        out += xor(delta, aes(key, xor(delta, block)))
        checksum = xor(checksum, block)
        rest = rest[BLOCK:]

    delta = times2(delta)
    length = bytes(8) + struct.pack(">Q", len(rest) * 8)
    pad = aes(key, xor(length, delta))
    tmp = rest + pad[len(rest):]
    checksum = xor(checksum, tmp)
    out += xor(pad, tmp)[:len(rest)]

    delta = times3(delta)
    tag = aes(key, xor(delta, checksum))
    return out, tag


def audio_datagrams(key, encrypt_iv, plaintexts):
    """CryptStateOCB2::encrypt, then the channel byte ServerHandler puts in front."""
    iv = bytearray(encrypt_iv)
    datagrams = []
    for plain in plaintexts:
        for i in range(BLOCK):
            iv[i] = (iv[i] + 1) & 0xFF
            if iv[i]:
                break
        ciphertext, tag = ocb2_encrypt(key, bytes(iv), plain)
        datagrams.append(bytes([0x00, iv[0]]) + tag[:3] + ciphertext)
    return datagrams


def video_datagram(key, nonce_base, sequence, plain):
    """VideoCryptState::encrypt."""
    seq = struct.pack(">I", sequence)
    ciphertext, tag = ocb2_encrypt(key, nonce_base + seq, plain)
    return bytes([0x01]) + seq + tag[:3] + ciphertext


def varint(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def proto_field(number, value):
    """One proto3 scalar or bytes field, or nothing for the default value, as protobuf omits it."""
    if isinstance(value, bytes):
        return varint(number << 3 | 2) + varint(len(value)) + value if value else b""
    value = int(value)
    return varint(number << 3) + varint(value) if value else b""


# VideoFragmenter::maxPayloadPerFragment(): the payload bytes one fragment carries.
MAX_VIDEO_FRAGMENT_PAYLOAD = 1098


def video_unit_packets(unit, payload):
    """VideoFragmenter::fragment: MumbleUDP.Video messages behind the Video message-type byte (2)."""
    count = max(1, -(-len(payload) // MAX_VIDEO_FRAGMENT_PAYLOAD))
    packets = []
    for i in range(count):
        chunk = payload[i * MAX_VIDEO_FRAGMENT_PAYLOAD:(i + 1) * MAX_VIDEO_FRAGMENT_PAYLOAD]
        message = b"".join([
            proto_field(1, 0),  # sender_session: the server stamps it
            proto_field(2, unit["streamID"]),
            proto_field(3, unit["frameNumber"]),
            proto_field(4, unit["unitID"]),
            proto_field(5, i),
            proto_field(6, count),
            proto_field(7, chunk),
            proto_field(8, unit["isKeyframe"]),
            proto_field(9, unit["isFrameEnd"]),
            proto_field(10, unit["captureTimestampUsec"]),
        ])
        if i == 0:
            message += b"".join(proto_field(n, unit[k]) for n, k in [(16, "x"), (17, "y"), (18, "width"), (19, "height")])
        packets.append(b"\x02" + message)
    return packets


def derive(session_key, label, size):
    return hashlib.sha256(session_key + label.encode()).digest()[:size]


def video_keys(session_key):
    return {
        "videoKey": derive(session_key, "mumble-video-key", 16),
        "nonceBaseServerToClient": derive(session_key, "mumble-video-nonce-s2c", 12),
        "nonceBaseClientToServer": derive(session_key, "mumble-video-nonce-c2s", 12),
    }


def pattern(n, start=0):
    return bytes((start + i) & 0xFF for i in range(n))


def hexify(value):
    if isinstance(value, bytes):
        return value.hex()
    if isinstance(value, dict):
        return {k: hexify(v) for k, v in value.items()}
    if isinstance(value, list):
        return [hexify(v) for v in value]
    return value


def write(name, description, cases):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name)
    with open(path, "w") as f:
        json.dump({"description": description, "cases": hexify(cases)}, f, indent=2)
        f.write("\n")


def main():
    draft_key = pattern(16)

    # The two from draft-krovetz-ocb-00 (key = nonce = 000102..0f) are first; the rest cover every
    # boundary of the final-block handling and the XEX* countermeasure.
    ocb_cases = []
    for name, key, nonce, plain in [
        ("draft-krovetz-ocb-00, empty", draft_key, draft_key, b""),
        ("draft-krovetz-ocb-00, 40 bytes", draft_key, draft_key, pattern(40)),
        ("1 byte", pattern(16, 0x40), pattern(16, 0x80), b"\x5a"),
        ("15 bytes", pattern(16, 0x40), pattern(16, 0x80), pattern(15, 0x10)),
        ("one full block", pattern(16, 0x40), pattern(16, 0x80), pattern(16, 0x20)),
        ("17 bytes", pattern(16, 0x40), pattern(16, 0x80), pattern(17, 0x30)),
        ("two full blocks", pattern(16, 0x40), pattern(16, 0x80), pattern(32, 0x50)),
        ("100 bytes", pattern(16, 0x40), pattern(16, 0x80), pattern(100, 0x60)),
        ("XEX* countermeasure: zero second-to-last block", pattern(16, 0x40), pattern(16, 0x80),
         bytes(15) + b"\x80" + pattern(16, 0x70)),
        ("digital silence, 48 zero bytes", pattern(16, 0x40), pattern(16, 0x80), bytes(48)),
    ]:
        ciphertext, tag = ocb2_encrypt(key, nonce, plain)
        ocb_cases.append({"name": name, "key": key, "nonce": nonce, "plaintext": plain,
                          "ciphertext": ciphertext, "tag": tag})
    write("ocb2-aes128.json",
          "CryptStateOCB2::ocb_encrypt (OCB2-AES128 with the XEX* countermeasure of eprint 2019/311 "
          "section 9 enabled). The tag is the full 16 bytes; datagrams carry only its first 3.",
          ocb_cases)

    audio_key = bytes.fromhex("8f1c2e4d5a6b7c8d9eafb0c1d2e3f405")
    audio_cases = []
    for name, iv in [
        ("fresh IV", bytes.fromhex("00112233445566778899aabbccddeeff")),
        ("first byte about to wrap", bytes.fromhex("fe112233445566778899aabbccddeeff")),
    ]:
        plaintexts = [pattern(7, 0x01), pattern(16, 0x11), pattern(60, 0x21)]
        audio_cases.append({"name": name, "key": audio_key, "encryptIv": iv, "plaintexts": plaintexts,
                            "datagrams": audio_datagrams(audio_key, iv, plaintexts)})
    write("audio-datagram.json",
          "Audio UDP datagrams as the client and server send them: channel byte 0x00, then "
          "CryptStateOCB2::encrypt's output (low byte of the IV, 3 tag bytes, ciphertext). encryptIv is "
          "the IV before the first packet; each packet increments it first, as a little-endian counter.",
          audio_cases)

    key_cases = []
    for session_key in [bytes(16), pattern(16), bytes.fromhex("8f1c2e4d5a6b7c8d9eafb0c1d2e3f405")]:
        case = {"sessionKey": session_key}
        case.update(video_keys(session_key))
        key_cases.append(case)
    write("video-key-derivation.json",
          "VideoCryptState::deriveFromSessionKey: SHA-256 of the 16-byte CryptSetup key followed by an "
          "ASCII label, truncated. The server encrypts with the s2c nonce base and the client with c2s.",
          key_cases)

    video_cases = []
    keys = video_keys(audio_key)
    for name, sequence, plain in [
        ("first packet", 1, b"\x02" + pattern(20, 0x01)),
        ("second packet", 2, b"\x02" + pattern(33, 0x02)),
        ("sequence with every byte set", 0x01020304, b"\x02" + pattern(1191, 0x03)),
    ]:
        video_cases.append({
            "name": name, "sessionKey": audio_key, "direction": "clientToServer",
            "key": keys["videoKey"], "encryptNonceBase": keys["nonceBaseClientToServer"],
            "sequence": sequence, "plaintext": plain,
            "datagram": video_datagram(keys["videoKey"], keys["nonceBaseClientToServer"], sequence, plain),
        })
    video_cases.append({
        "name": "server to client", "sessionKey": audio_key, "direction": "serverToClient",
        "key": keys["videoKey"], "encryptNonceBase": keys["nonceBaseServerToClient"],
        "sequence": 1, "plaintext": b"\x03" + pattern(9, 0x04),
        "datagram": video_datagram(keys["videoKey"], keys["nonceBaseServerToClient"], 1, b"\x03" + pattern(9, 0x04)),
    })
    write("video-datagram.json",
          "Video UDP datagrams (VideoCryptState::encrypt): channel byte 0x01, 32-bit big-endian sequence, "
          "3 tag bytes, ciphertext. The nonce is encryptNonceBase followed by the big-endian sequence. "
          "key and encryptNonceBase are derived from sessionKey as in video-key-derivation.json.",
          video_cases)

    write_video_units(audio_key)


def write_video_units(session_key):
    keys = video_keys(session_key)
    cases = []
    sequence = 1
    for name, unit, payload in [
        ("one fragment", {"streamID": 1, "frameNumber": 7, "unitID": 0, "isKeyframe": False, "isFrameEnd": True,
                          "captureTimestampUsec": 123456789, "x": 0, "y": 0, "width": 0, "height": 0},
         pattern(300, 0x11)),
        ("keyframe in two fragments", {"streamID": 2, "frameNumber": 1, "unitID": 3, "isKeyframe": True,
                                       "isFrameEnd": True, "captureTimestampUsec": 1700000000000000,
                                       "x": 128, "y": 256, "width": 1280, "height": 720},
         pattern(1500, 0x22)),
    ]:
        datagrams = []
        for packet in video_unit_packets(unit, payload):
            datagrams.append(video_datagram(keys["videoKey"], keys["nonceBaseClientToServer"], sequence, packet))
            sequence += 1
        case = {"name": name, "payload": payload, "datagrams": datagrams}
        case.update(unit)
        cases.append(case)
    write("video-unit.json",
          "Whole video units as a client sends them (MediaSession::makeVideo, the desktop's sendVideoUnit): "
          "VideoFragmenter's MumbleUDP.Video messages, encrypted client to server on the video key derived from "
          "sessionKey. The cases are sent one after the other on a fresh session, so the first datagram has "
          "sequence 1 and the sequence carries on across cases.",
          {"sessionKey": session_key, "units": cases})


if __name__ == "__main__":
    main()
