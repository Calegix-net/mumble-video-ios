#!/bin/bash
# Generates MumbleVideo.xcodeproj from project.yml with the pinned XcodeGen (fetched on first use).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tools/versions.sh"
WORK="${WORK:-$HOME/.cache/mumble-video-ios/deps}"
BIN="$WORK/tools/xcodegen-$XCODEGEN_VERSION/xcodegen/bin/xcodegen"
if [ ! -x "$BIN" ]; then
	mkdir -p "$WORK/tools/xcodegen-$XCODEGEN_VERSION"
	curl -fL --retry 5 -o "$WORK/src/xcodegen.zip" "$XCODEGEN_URL"
	echo "$XCODEGEN_SHA256  $WORK/src/xcodegen.zip" | shasum -a 256 -c - >/dev/null
	unzip -q -o "$WORK/src/xcodegen.zip" -d "$WORK/tools/xcodegen-$XCODEGEN_VERSION"
fi
cd "$ROOT" && "$BIN" generate --spec project.yml
