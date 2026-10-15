# shellcheck shell=bash
# Pinned native dependencies, sourced by build-deps.sh. OpenSSL, Protobuf, Abseil and Opus match the
# Android client (core-native/src/main/cpp/deps/versions.cmake and its Opus FetchContent); libvpx matches
# the desktop Windows build (docker/Dockerfile.windows).

OPENSSL_VERSION=3.5.9
OPENSSL_URL=https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a

PROTOBUF_VERSION=33.5
PROTOBUF_URL=https://github.com/protocolbuffers/protobuf/releases/download/v$PROTOBUF_VERSION/protobuf-$PROTOBUF_VERSION.tar.gz
PROTOBUF_SHA256=c6c7c27fadc19d40ab2eaa23ff35debfe01f6494a8345559b9bb285ce4144dd1
# Host protoc must match the runtime exactly. Digest from the GitHub release asset.
PROTOC_URL=https://github.com/protocolbuffers/protobuf/releases/download/v$PROTOBUF_VERSION/protoc-$PROTOBUF_VERSION-osx-x86_64.zip
PROTOC_SHA256=7f31625f8bec4929082ae9209e101c1c03692624457cc6332f83736db495ee92

ABSEIL_VERSION=20250512.1
ABSEIL_URL=https://github.com/abseil/abseil-cpp/archive/refs/tags/$ABSEIL_VERSION.tar.gz
ABSEIL_SHA256=9b7a064305e9fd94d124ffa6cc358592eb42b5da588fb4e07d09254aa40086db

OPUS_VERSION=1.5.2
OPUS_URL=https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz
OPUS_SHA256=65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1

VPX_VERSION=v1.15.0
VPX_GIT=https://chromium.googlesource.com/webm/libvpx

# Assembler for libvpx's x86 code (simulator and macOS slices).
NASM_VERSION=2.16.03
NASM_URL=https://www.nasm.us/pub/nasm/releasebuilds/$NASM_VERSION/macosx/nasm-$NASM_VERSION-macosx.zip

IOS_MIN=17.0
MACOS_MIN=14.0

# Swift runtime and code generator for the control-channel protobufs (Package.swift pins the same).
SWIFT_PROTOBUF_VERSION=1.38.1
