# Copyright The Mumble Developers. All rights reserved.
# Use of this source code is governed by a BSD-style license
# that can be found in the LICENSE file at the root of the
# Mumble source tree or at <https://www.mumble.info/LICENSE>.

# The protocol core: wire formats, crypto and media framing, with no Qt and no sockets. The desktop
# client and server get it through `shared`. It also builds on its own (point CMake at this
# directory), which is how a non-Qt host such as the Android app consumes it, and how CI proves that
# nothing in here has picked up a Qt dependency.

cmake_minimum_required(VERSION 3.23...4.2)

if(MUMBLE_CORE_IN_MUMBLE_TREE)
	# In the main tree src/CMakeLists.txt has already found OpenSSL and Protobuf and set the compiler
	# flags, the version is Mumble's own, and the desktop always keeps the legacy format.
	set(MUMBLE_CORE_3RDPARTY_DIR "${3RDPARTY_DIR}")
	set(MUMBLE_CORE_VERSION_MAJOR ${CMAKE_PROJECT_VERSION_MAJOR})
	set(MUMBLE_CORE_VERSION_MINOR ${CMAKE_PROJECT_VERSION_MINOR})
	set(MUMBLE_CORE_VERSION_PATCH ${CMAKE_PROJECT_VERSION_PATCH})
	set(MUMBLE_CORE_VERSION ${CMAKE_PROJECT_VERSION})
	set(MUMBLE_CORE_LEGACY_UDP ON)
	set(MUMBLE_CORE_TESTS ${tests})
else()
	# On its own, or added with add_subdirectory() by some other project (the Android app). Either way
	# the options below are the host's to set, before add_subdirectory() in the second case.
	set(MUMBLE_CORE_VERSION "0.0.0" CACHE STRING "Version reported by the core when built on its own")

	project(mumble-core
		VERSION ${MUMBLE_CORE_VERSION}
		LANGUAGES C CXX
	)

	if(NOT DEFINED CMAKE_CXX_STANDARD OR CMAKE_CXX_STANDARD LESS 20)
		set(CMAKE_CXX_STANDARD 20)
	endif()
	set(CMAKE_CXX_STANDARD_REQUIRED ON)
	set(CMAKE_CXX_EXTENSIONS OFF)
	set(CMAKE_POSITION_INDEPENDENT_CODE ON)

	option(MUMBLE_CORE_TESTS "Build the core tests." ${PROJECT_IS_TOP_LEVEL})
	# Pre-1.5 servers and clients speak a UDP format of their own, encoded with PacketDataStream. The
	# desktop always keeps it; a host that only ever talks to current servers can leave it out.
	option(MUMBLE_CORE_LEGACY_UDP "Support the legacy (pre-Protobuf) UDP format." ON)
	# Android and other small hosts only need the lite runtime, which is a fraction of the size. Nothing in
	# the core uses reflection.
	option(MUMBLE_CORE_PROTOBUF_LITE "Generate and link against the Protobuf lite runtime." OFF)

	if(NOT TARGET OpenSSL::Crypto)
		find_package(OpenSSL REQUIRED COMPONENTS Crypto)
	endif()
	if(NOT TARGET protobuf::libprotobuf AND NOT TARGET protobuf::libprotobuf-lite)
		find_package(Protobuf CONFIG)
		if(NOT Protobuf_FOUND)
			find_package(Protobuf MODULE REQUIRED)
		endif()
	endif()

	# Cross-compiling (for Android), the target's Protobuf has no protoc that runs here, so the host's is
	# used. Its version has to match the target library's exactly. A host can pass its own in
	# MUMBLE_CORE_PROTOC_ARGS (PROTOC_EXE <path>).
	if(CMAKE_CROSSCOMPILING AND NOT TARGET protobuf::protoc AND NOT MUMBLE_CORE_PROTOC_ARGS)
		find_program(MUMBLE_CORE_PROTOC protoc REQUIRED)
		set(MUMBLE_CORE_PROTOC_ARGS PROTOC_EXE "${MUMBLE_CORE_PROTOC}")
	endif()

	if(MUMBLE_CORE_TESTS)
		enable_testing()
	endif()

	if(NOT MUMBLE_CORE_3RDPARTY_DIR)
		set(MUMBLE_CORE_3RDPARTY_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../3rdparty")
	endif()
	set(MUMBLE_CORE_VERSION_MAJOR ${PROJECT_VERSION_MAJOR})
	set(MUMBLE_CORE_VERSION_MINOR ${PROJECT_VERSION_MINOR})
	set(MUMBLE_CORE_VERSION_PATCH ${PROJECT_VERSION_PATCH})
	set(MUMBLE_CORE_VERSION ${PROJECT_VERSION})
endif()

add_library(mumble-core STATIC)

if(MUMBLE_CORE_PROTOBUF_LITE)
	set(MUMBLE_CORE_PROTOC_ARGS ${MUMBLE_CORE_PROTOC_ARGS} PLUGIN_OPTIONS lite)
	set(MUMBLE_CORE_PROTOBUF_TARGET protobuf::libprotobuf-lite)
else()
	set(MUMBLE_CORE_PROTOBUF_TARGET protobuf::libprotobuf)
endif()

protobuf_generate(LANGUAGE cpp TARGET mumble-core PROTOS "${CMAKE_CURRENT_SOURCE_DIR}/Mumble.proto"
	OUT_VAR BUILT_PROTO_FILES ${MUMBLE_CORE_PROTOC_ARGS})
protobuf_generate(LANGUAGE cpp TARGET mumble-core PROTOS "${CMAKE_CURRENT_SOURCE_DIR}/MumbleUDP.proto"
	OUT_VAR BUILT_UDP_PROTO_FILES ${MUMBLE_CORE_PROTOC_ARGS})

# Disable warnings for the generated source files
foreach(CURRENT_FILE IN LISTS BUILT_PROTO_FILES BUILT_UDP_PROTO_FILES)
	set_source_files_properties("${CURRENT_FILE}" PROPERTIES COMPILE_FLAGS "-w")
endforeach()

target_sources(mumble-core
	PRIVATE
		"ByteSwap.h"
		"ControlFramer.cpp"
		"ControlFramer.h"
		"CoreLog.cpp"
		"CoreLog.h"
		"CryptoSession.cpp"
		"CryptoSession.h"
		"MediaDemux.cpp"
		"MediaDemux.h"
		"MumbleCore.cpp"
		"MumbleProtocol.cpp"
		"MumbleProtocol.h"
		"PacketDataStream.h"
		"Timer.cpp"
		"Timer.h"
		"VersionNumber.h"
		"VideoFragmentation.cpp"
		"VideoFragmentation.h"
		"VideoReceiver.cpp"
		"VideoReceiver.h"
		"VideoTransport.cpp"
		"VideoTransport.h"
		"VolumeAdjustment.cpp"
		"VolumeAdjustment.h"

		"crypto/CryptographicRandom.cpp"
		"crypto/CryptographicRandom.h"
		"crypto/CryptState.cpp"
		"crypto/CryptState.h"
		"crypto/CryptStateOCB2.cpp"
		"crypto/CryptStateOCB2.h"
		"crypto/Digest.cpp"
		"crypto/Digest.h"

		"${MUMBLE_CORE_3RDPARTY_DIR}/arc4random/arc4random_uniform.cpp"
		"${MUMBLE_CORE_3RDPARTY_DIR}/arc4random/arc4random_uniform.h"
)

# The API a non-Qt host binds to. The desktop uses the internal headers directly.
target_sources(mumble-core
	PUBLIC
		FILE_SET HEADERS
		BASE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/include"
		FILES "include/mumble-core/MumbleCore.h"
)

target_compile_definitions(mumble-core
	PUBLIC
		"MUMBLE_VERSION=${MUMBLE_CORE_VERSION}"
		"MUMBLE_VERSION_MAJOR=${MUMBLE_CORE_VERSION_MAJOR}"
		"MUMBLE_VERSION_MINOR=${MUMBLE_CORE_VERSION_MINOR}"
		"MUMBLE_VERSION_PATCH=${MUMBLE_CORE_VERSION_PATCH}"
)

if(MUMBLE_CORE_LEGACY_UDP)
	target_compile_definitions(mumble-core PRIVATE "MUMBLE_CORE_LEGACY_UDP")
endif()

target_include_directories(mumble-core
	PUBLIC
		${CMAKE_CURRENT_SOURCE_DIR}
		${CMAKE_CURRENT_BINARY_DIR}
	PRIVATE
		"${MUMBLE_CORE_3RDPARTY_DIR}/arc4random"
)

target_link_libraries(mumble-core
	PUBLIC
		${MUMBLE_CORE_PROTOBUF_TARGET}
		OpenSSL::Crypto
)

if(WIN32)
	# htonl, for the 32-bit OCB2 path.
	target_link_libraries(mumble-core PUBLIC ws2_32)
endif()

if(MUMBLE_CORE_TESTS)
	add_subdirectory(tests)
endif()
