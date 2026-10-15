# Mumble Video for iOS

Native iOS client for [Mumble Video](https://github.com/Calegix-net/mumble-video): voice, chat and video.
The protocol, crypto and media transport come from the same `mumble-core` the desktop and Android clients
use; the app adds TLS, audio, codecs and a SwiftUI interface.

## Layout

- `Vendor/mumble-core`: `mumble-core` from the desktop repo, vendored by `tools/sync-core.sh` (see
  `CORE_REVISION`).
- `tools/build-deps.sh`: builds OpenSSL libcrypto, Abseil + protobuf-lite, Opus, libvpx and mumble-core
  for iPhone, the Intel simulator and macOS, and packages them as `Frameworks/MumbleNative.xcframework`.
  Pins are in `tools/versions.sh` (OpenSSL, Protobuf, Abseil and Opus match the Android client).
- `Sources/CMumbleBridge`: a small C surface over mumble-core, Opus and libvpx, so Swift imports it as-is.
- `Sources/MumbleKit`: the Swift client core.

## Building

On a Mac with Xcode 26 (the last release that runs on Intel):

```sh
pip3 install --user cmake ninja
tools/build-deps.sh
swift test          # MumbleKit on macOS
```
