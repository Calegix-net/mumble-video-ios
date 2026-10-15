# mumble-core

The protocol code of mumble-video with no Qt and no sockets: the wire formats, the UDP crypto, video
fragmentation and reassembly, and the control-stream framing. The desktop client and server link it
through `shared`. Other hosts (the Android app, over JNI) use it on its own.

## Building it on its own

```sh
cmake -S src/mumble-core -B build-core -DCMAKE_BUILD_TYPE=Release
cmake --build build-core
ctest --test-dir build-core
```

It needs OpenSSL (libcrypto) and Protobuf, and nothing else. The options are:

- `MUMBLE_CORE_LEGACY_UDP` (default `ON`) keeps the pre-1.5 UDP format. Leave it off for a client that only
  ever talks to current servers. In the main tree it is always on.
- `MUMBLE_CORE_VERSION` is the version string the core reports.
- `MUMBLE_CORE_TESTS` builds `TestMumbleCore` (on by default only when the core is the top-level project).

CI builds it exactly this way, in a configure that never looks for Qt. That is the check that nothing in
here has started to need Qt.

## Android

`android/` has two scripts:

```sh
export ANDROID_NDK_ROOT=~/Android/Sdk/ndk/25.1.8937393
src/mumble-core/android/build-deps.sh arm64-v8a ~/mumble-core-deps/arm64-v8a
src/mumble-core/android/build-core.sh arm64-v8a ~/mumble-core-deps/arm64-v8a build-core-arm64
```

- `build-deps.sh` builds static OpenSSL `libcrypto` (3.5 LTS) and the Protobuf lite runtime (with its
  Abseil) for one ABI.
  - OpenSSL's Configure needs a few Perl modules that Fedora packages separately: perl-FindBin,
    perl-IPC-Cmd, perl-File-Compare, perl-File-Copy and perl-Time-Piece.
  - Protobuf is built at the version of the `protoc` on `PATH`. The generated code only works against
    the runtime of the same version, and the cross build generates with that host `protoc`.
- `build-core.sh` is the configure an app's CMake needs to reproduce:
  - the NDK toolchain file, `ANDROID_ABI` and `ANDROID_PLATFORM` (API 29);
  - `CMAKE_FIND_ROOT_PATH` pointing at the deps prefix, and `OPENSSL_USE_STATIC_LIBS=ON`;
  - `MUMBLE_CORE_PROTOBUF_LITE=ON` and `MUMBLE_CORE_LEGACY_UDP=OFF`.

  From Gradle (`externalNativeBuild`), the JNI library's CMakeLists can `add_subdirectory()` this
  directory and link `mumble-core`. Set `MUMBLE_CORE_PROTOBUF_LITE` and `MUMBLE_CORE_LEGACY_UDP`
  before that call. `MUMBLE_CORE_PROTOC_ARGS` (`PROTOC_EXE <path>`) picks the protoc, and
  `MUMBLE_CORE_3RDPARTY_DIR` says where `3rdparty/` is if it isn't two levels up.

The tests run on a device or emulator too. Push `TestMumbleCore` and `test-vectors/`, and point
`MUMBLE_CORE_TEST_VECTORS` at the vectors.

NDK r25 (clang 14) is enough.

## For a host

Include `include/mumble-core/MumbleCore.h` and nothing else. The header comment explains how the bytes
flow. In short, the host owns the TLS connection and the UDP socket:

- `ControlReader` and `frameControlMessage()` split the TLS stream into messages and back. The host parses
  the control messages itself from `Mumble.proto`, except CryptSetup, which goes to the session.
- `MediaSession` is one connection's UDP side. Datagrams go in. Audio packets (still Opus-encoded), whole
  video units, pongs, and datagrams and control messages to send come out.

Logging goes to stderr until `MumbleCore::setLogHandler()` points it at the host's log.

## Test vectors

`test-vectors/` holds known-answer vectors as JSON, with every byte in hex:

- the OCB2 primitive
- whole audio and video datagrams
- the video key derivation

`generate.py` there writes them. It is a separate Python implementation, written from the C++ but not
linked to it. `TestMumbleCore` checks the C++ against these files, and another implementation should check
itself against them too.

## Layout

| Files | What |
| --- | --- |
| `Mumble.proto`, `MumbleUDP.proto` | the wire messages; generated code is built here |
| `MumbleProtocol`, `PacketDataStream.h` | UDP audio and ping encoding, protobuf and legacy |
| `crypto/` | OCB2-AES128 (audio), random, `Digest` (SHA-1/256) |
| `VideoTransport` | the video channel's crypt state and datagram layout |
| `VideoFragmentation` | splitting units into datagrams, reassembly, NACK bookkeeping |
| `MediaDemux` | which channel a datagram is on |
| `VideoReceiver` | decrypt, reassemble, and pace retransmission requests |
| `ControlFramer` | the 6-byte control message header |
| `CryptoSession` | both crypt states, keyed from CryptSetup |
| `MumbleCore.cpp` | the public API above |

Still in the desktop client, to come later: keyframe gating and joining H.264 units (VideoGrid), and voice
playback (Opus decode, jitter buffer, loss concealment).
