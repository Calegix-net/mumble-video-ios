#!/bin/bash
# Regenerates the Swift control/UDP protobuf types from the vendored protos into
# Sources/MumbleKit/Proto. Builds protoc-gen-swift at the pinned swift-protobuf version on first use and
# uses the protoc that tools/build-deps.sh fetched (same version as the C++ runtime).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tools/versions.sh"
WORK="${WORK:-$HOME/.cache/mumble-video-ios/deps}"
PROTOC="$WORK/tools/protoc/bin/protoc"
PLUGIN="$WORK/tools/swift-protobuf-$SWIFT_PROTOBUF_VERSION/.build/release/protoc-gen-swift"

if [ ! -x "$PLUGIN" ]; then
	rm -rf "$WORK/tools/swift-protobuf-$SWIFT_PROTOBUF_VERSION"
	git clone -q --depth 1 --branch "$SWIFT_PROTOBUF_VERSION" https://github.com/apple/swift-protobuf.git \
		"$WORK/tools/swift-protobuf-$SWIFT_PROTOBUF_VERSION"
	(cd "$WORK/tools/swift-protobuf-$SWIFT_PROTOBUF_VERSION" && swift build -c release --product protoc-gen-swift >/dev/null)
fi

PROTOS="$ROOT/Vendor/mumble-core/src/mumble-core"
OUT="$ROOT/Sources/MumbleKit/Proto"
rm -rf "$OUT" && mkdir -p "$OUT"
"$PROTOC" --plugin=protoc-gen-swift="$PLUGIN" --swift_out="$OUT" --swift_opt=Visibility=Public \
	-I "$PROTOS" "$PROTOS/Mumble.proto" "$PROTOS/MumbleUDP.proto"
ls "$OUT"
