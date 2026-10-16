#!/bin/bash
# Builds the iPhone app and packages it as build/MumbleVideo.ipa for sideloading (Sideloadly, AltStore).
#
# Not signed for distribution: the sideloading tool signs it with the installer's own Apple ID. The app and
# the broadcast extension get an ad-hoc signature carrying their entitlements, so the tool knows to register
# the App Group that screen sharing needs. Needs Frameworks/MumbleNative.xcframework (tools/build-deps.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build"
rm -rf "$OUT" && mkdir -p "$OUT"

tools/gen-project.sh >/dev/null
xcodebuild archive -project MumbleVideo.xcodeproj -scheme MumbleVideo -configuration Release \
	-destination generic/platform=iOS -archivePath "$OUT/MumbleVideo.xcarchive" \
	CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -quiet

APP="$OUT/MumbleVideo.xcarchive/Products/Applications/MumbleVideo.app"
APPEX="$APP/PlugIns/MumbleVideoBroadcast.appex"
[ -d "$APPEX" ] || { echo "broadcast extension missing from the app" >&2; exit 1; }
codesign --force --sign - --entitlements Broadcast/Broadcast.entitlements "$APPEX"
codesign --force --sign - --entitlements App/MumbleVideo.entitlements "$APP"
codesign -d --entitlements - "$APPEX" 2>/dev/null | grep -q group.com.calegix.mumblevideo

mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"
(cd "$OUT" && zip -qry MumbleVideo.ipa Payload)
rm -rf "$OUT/Payload"
echo "$OUT/MumbleVideo.ipa ($(du -h "$OUT/MumbleVideo.ipa" | cut -f1))"
