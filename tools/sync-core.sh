#!/bin/sh
# Vendors mumble-core (protocol, crypto, media session) from the desktop repo into Vendor/mumble-core,
# plus the one 3rdparty file it uses. Taken from a committed ref, never the working tree; CORE_REVISION
# records which.
#
#   tools/sync-core.sh [ref] [path to mumble-video]
set -eu
ref=${1:-v1.10.0}
repo=${2:-$HOME/projects/mumble-video}
here="$(cd "$(dirname "$0")/.." && pwd)"
dst="$here/Vendor/mumble-core"
rev=$(git -C "$repo" rev-parse --short "$ref^{commit}")

rm -rf "$dst"
mkdir -p "$dst"
git -C "$repo" archive --format=tar "$rev" src/mumble-core 3rdparty/arc4random | tar -xf - -C "$dst"
# Android's build scripts are not needed here.
rm -rf "$dst/src/mumble-core/android"
printf "%s %s\n" "$rev" "$ref" > "$dst/CORE_REVISION"
echo "vendored mumble-core $rev ($ref)"
