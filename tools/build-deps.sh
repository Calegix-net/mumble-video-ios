#!/bin/bash
# Builds the client's native code as static libraries for each Apple platform slice and packages them as
# Frameworks/MumbleNative.xcframework: OpenSSL libcrypto, Abseil + protobuf-lite (mumble-core's runtime),
# Opus, libvpx and mumble-core itself, merged into one library per slice.
#
# Runs on macOS with Xcode. Needs cmake and ninja on PATH (pip install --user cmake ninja is enough).
#
#   tools/build-deps.sh                 iPhone + this Mac's simulator and macOS slices
#   SLICES="ios-arm64" tools/build-deps.sh   (what an iPhone build needs; CI's release build)
#
# Slices: ios-arm64, sim-x86_64, sim-arm64, mac-x86_64, mac-arm64. An xcframework holds one library per
# platform, so pick one simulator and one macOS architecture (the defaults follow the host).
#
# Sources and per-slice builds are cached under $WORK; delete a slice's directory to rebuild it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=versions.sh
. "$ROOT/tools/versions.sh"
WORK="${WORK:-$HOME/.cache/mumble-video-ios/deps}"
HOST_ARCH="$(uname -m)"
SLICES="${SLICES:-ios-arm64 sim-$HOST_ARCH mac-$HOST_ARCH}"
JOBS="$(sysctl -n hw.ncpu)"
CORE_SRC="$ROOT/Vendor/mumble-core/src/mumble-core"
mkdir -p "$WORK/src" "$WORK/tools"

fetch() { # url sha256 file
	local url=$1 sha=$2 out="$WORK/src/$3"
	if [ ! -f "$out" ]; then
		curl -fL --retry 5 -o "$out.part" "$url"
		mv "$out.part" "$out"
	fi
	if [ -n "$sha" ]; then
		echo "$sha  $out" | shasum -a 256 -c - >/dev/null || { echo "checksum mismatch for $out" >&2; exit 1; }
	fi
}

unpack() { # archive dir
	local dir="$WORK/src/$2"
	[ -d "$dir" ] || { mkdir -p "$dir.tmp" && tar -xzf "$WORK/src/$1" -C "$dir.tmp" --strip-components 1 && mv "$dir.tmp" "$dir"; }
	echo "$dir"
}

host_tools() {
	fetch "$PROTOC_URL" "$PROTOC_SHA256" protoc.zip
	[ -x "$WORK/tools/protoc/bin/protoc" ] || { rm -rf "$WORK/tools/protoc" && unzip -q "$WORK/src/protoc.zip" -d "$WORK/tools/protoc"; }
	PROTOC="$WORK/tools/protoc/bin/protoc"
	"$PROTOC" --version
	case "$SLICES" in *x86_64*) ;; *) return ;; esac
	fetch "$NASM_URL" "" nasm.zip
	[ -x "$WORK/tools/nasm/nasm" ] || { rm -rf "$WORK/tools/nasm" "$WORK/tools/nasm-$NASM_VERSION" && unzip -q "$WORK/src/nasm.zip" -d "$WORK/tools" && mv "$WORK/tools/nasm-$NASM_VERSION" "$WORK/tools/nasm"; }
	export PATH="$WORK/tools/nasm:$PATH"
	nasm -v
}

# Per-slice settings: SDK, ARCH, CMAKE_SYSTEM_NAME, deployment flag, OpenSSL target, libvpx target.
slice_vars() {
	case "$1" in
		ios-arm64)  SDK=iphoneos;        ARCH=arm64;  SYS=iOS;    MINFLAG="-mios-version-min=$IOS_MIN";           OSSL=ios64-xcrun;               VPXT=arm64-darwin-gcc ;;
		sim-x86_64) SDK=iphonesimulator; ARCH=x86_64; SYS=iOS;    MINFLAG="-mios-simulator-version-min=$IOS_MIN"; OSSL=iossimulator-x86_64-xcrun; VPXT=x86_64-iphonesimulator-gcc ;;
		sim-arm64)  SDK=iphonesimulator; ARCH=arm64;  SYS=iOS;    MINFLAG="-mios-simulator-version-min=$IOS_MIN"; OSSL=iossimulator-arm64-xcrun;  VPXT=generic-gnu ;;
		mac-x86_64) SDK=macosx;          ARCH=x86_64; SYS=Darwin; MINFLAG="-mmacosx-version-min=$MACOS_MIN";       OSSL=darwin64-x86_64-cc;        VPXT=x86_64-darwin20-gcc ;;
		mac-arm64)  SDK=macosx;          ARCH=arm64;  SYS=Darwin; MINFLAG="-mmacosx-version-min=$MACOS_MIN";       OSSL=darwin64-arm64-cc;         VPXT=arm64-darwin20-gcc ;;
		*) echo "unknown slice $1" >&2; exit 2 ;;
	esac
	SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
	CC="$(xcrun --sdk "$SDK" --find clang)"
	CXX="$(xcrun --sdk "$SDK" --find clang++)"
	PREFIX="$WORK/$1/prefix"
	BUILD="$WORK/$1/build"
	mkdir -p "$PREFIX" "$BUILD"
}

cmake_slice() { # name srcdir [cmake args...]
	local name=$1 src=$2; shift 2
	cmake -S "$src" -B "$BUILD/$name" -G Ninja -Wno-dev \
		-DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME="$SYS" -DCMAKE_OSX_SYSROOT="$SYSROOT" \
		-DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_C_FLAGS="$MINFLAG" -DCMAKE_CXX_FLAGS="$MINFLAG" \
		-DCMAKE_OSX_DEPLOYMENT_TARGET="$( [ "$SYS" = Darwin ] && echo "$MACOS_MIN" || echo "$IOS_MIN")" \
		-DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_FIND_ROOT_PATH="$PREFIX" \
		-DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON "$@" >/dev/null
	cmake --build "$BUILD/$name" -j"$JOBS" >/dev/null
	[ "$name" = mumble-core ] || cmake --install "$BUILD/$name" >/dev/null
}

build_openssl() {
	[ -f "$PREFIX/lib/libcrypto.a" ] && return
	local src; src=$(unpack openssl.tar.gz openssl)
	rm -rf "$BUILD/openssl" && cp -R "$src" "$BUILD/openssl"
	(cd "$BUILD/openssl" &&
		CC="$CC" CFLAGS="-isysroot $SYSROOT $MINFLAG" ./Configure "$OSSL" --prefix="$PREFIX" --libdir=lib \
			no-shared no-tests no-apps no-docs no-engine no-dso no-module no-legacy no-ui-console \
			no-ssl no-tls no-dtls no-quic >/dev/null &&
		make -j"$JOBS" build_libs >/dev/null && make install_dev >/dev/null)
	rm -f "$PREFIX/lib/libssl.a"
}

build_abseil_protobuf() {
	[ -f "$PREFIX/lib/libprotobuf-lite.a" ] && return
	cmake_slice abseil "$(unpack abseil.tar.gz abseil)" -DABSL_PROPAGATE_CXX_STD=ON -DABSL_BUILD_TESTING=OFF \
		-DCMAKE_CXX_STANDARD=17
	cmake_slice protobuf "$(unpack protobuf.tar.gz protobuf)" -Dprotobuf_BUILD_TESTS=OFF \
		-Dprotobuf_BUILD_PROTOC_BINARIES=OFF -Dprotobuf_BUILD_LIBUPB=OFF -Dprotobuf_ABSL_PROVIDER=package \
		-Dprotobuf_INSTALL=ON -DCMAKE_CXX_STANDARD=17
}

build_opus() {
	[ -f "$PREFIX/lib/libopus.a" ] && return
	cmake_slice opus "$(unpack opus.tar.gz opus)" -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF \
		-DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF -DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF
}

build_vpx() { # slice
	[ -f "$PREFIX/lib/libvpx.a" ] && return
	[ -d "$WORK/src/libvpx" ] || git clone -q --depth 1 --branch "$VPX_VERSION" "$VPX_GIT" "$WORK/src/libvpx"
	rm -rf "$BUILD/vpx" && mkdir -p "$BUILD/vpx"
	# libvpx has no arm64 simulator target: that slice uses its portable C build (generic-gnu) with the
	# simulator SDK's compiler and flags, so no hand-written SIMD there. Fine for a simulator.
	local flags="$MINFLAG" env=()
	if [ "$VPXT" = generic-gnu ]; then
		flags="-arch $ARCH -isysroot $SYSROOT $MINFLAG"
		env=(CC="$CC" CXX="$CXX" AR="$(xcrun --find ar)" LD="$CC")
	fi
	(cd "$BUILD/vpx" &&
		env ${env[@]+"${env[@]}"} "$WORK/src/libvpx/configure" --target="$VPXT" --prefix="$PREFIX" \
			--extra-cflags="$flags" --extra-cxxflags="$flags" \
			--enable-vp8 --enable-vp9 --enable-static --disable-shared --enable-pic \
			--disable-examples --disable-tools --disable-docs --disable-unit-tests --disable-install-bins \
			--enable-realtime-only --disable-webm-io --disable-libyuv >>"$BUILD/vpx.log" 2>&1 &&
		make -j"$JOBS" >>"$BUILD/vpx.log" 2>&1 && make install >>"$BUILD/vpx.log" 2>&1) || { echo "libvpx failed for $1:" >&2; tail -40 "$BUILD/vpx.log" >&2; exit 1; }
}

build_core() {
	# mumble-core installs nothing when built standalone; the library stays in its build directory.
	[ -f "$BUILD/mumble-core/libmumble-core.a" ] && return
	local core_version; core_version=$(awk '{print $2}' "$ROOT/Vendor/mumble-core/CORE_REVISION" | sed 's/^v//')
	cmake_slice mumble-core "$CORE_SRC" -DMUMBLE_CORE_VERSION="$core_version" -DMUMBLE_CORE_PROTOBUF_LITE=ON -DMUMBLE_CORE_LEGACY_UDP=OFF \
		-DMUMBLE_CORE_TESTS=OFF -DMUMBLE_CORE_PROTOC_ARGS="PROTOC_EXE;$PROTOC" \
		-DOPENSSL_ROOT_DIR="$PREFIX" -DOPENSSL_USE_STATIC_LIBS=ON \
		-DCMAKE_CXX_FLAGS="$MINFLAG -Wall -Wextra -Wsign-conversion -Werror"
}

merge_slice() { # one static library + headers per slice
	local out="$WORK/$1/merged"
	rm -rf "$out" && mkdir -p "$out/include"
	libtool -static -o "$out/libMumbleNative.a" \
		"$BUILD/mumble-core/libmumble-core.a" "$PREFIX/lib/libprotobuf-lite.a" "$PREFIX"/lib/libabsl_*.a \
		"$PREFIX"/lib/libutf8_*.a "$PREFIX/lib/libcrypto.a" "$PREFIX/lib/libopus.a" "$PREFIX/lib/libvpx.a" 2>/dev/null
	cp -R "$CORE_SRC/include/mumble-core" "$PREFIX/include/opus" "$PREFIX/include/vpx" "$out/include/"
}

fetch "$OPENSSL_URL" "$OPENSSL_SHA256" openssl.tar.gz
fetch "$ABSEIL_URL" "$ABSEIL_SHA256" abseil.tar.gz
fetch "$PROTOBUF_URL" "$PROTOBUF_SHA256" protobuf.tar.gz
fetch "$OPUS_URL" "$OPUS_SHA256" opus.tar.gz
host_tools

args=()
for s in $SLICES; do
	echo "== $s"
	slice_vars "$s"
	build_openssl;         echo "   openssl"
	build_abseil_protobuf; echo "   abseil + protobuf-lite"
	build_opus;            echo "   opus"
	build_vpx "$s";        echo "   libvpx"
	build_core;            echo "   mumble-core"
	merge_slice "$s"
	args+=(-library "$WORK/$s/merged/libMumbleNative.a" -headers "$WORK/$s/merged/include")
done

rm -rf "$ROOT/Frameworks/MumbleNative.xcframework"
mkdir -p "$ROOT/Frameworks"
xcodebuild -create-xcframework "${args[@]}" -output "$ROOT/Frameworks/MumbleNative.xcframework"
echo "built Frameworks/MumbleNative.xcframework for: $SLICES"
