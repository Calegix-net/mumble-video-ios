# Copyright The Mumble Developers. All rights reserved.
# Use of this source code is governed by a BSD-style license
# that can be found in the LICENSE file at the root of the
# Mumble source tree or at <https://www.mumble.info/LICENSE>.

# Plain C++ with no test framework, so that these build anywhere the core does. They link nothing but
# mumble-core: if any of it needed Qt, this would fail to compile or to link.

add_executable(TestMumbleCore
	"CoreTest.h"
	"TestKnownAnswers.cpp"
	"TestMediaSession.cpp"
	"TestMumbleCore.cpp"
)

target_include_directories(TestMumbleCore PRIVATE "${MUMBLE_CORE_3RDPARTY_DIR}/nlohmann_json/single_include")
target_compile_definitions(TestMumbleCore
	PRIVATE "MUMBLE_CORE_TEST_VECTORS_DIR=\"${CMAKE_CURRENT_SOURCE_DIR}/../test-vectors\""
)

target_link_libraries(TestMumbleCore PRIVATE mumble-core)

if(MUMBLE_CORE_LEGACY_UDP)
	target_compile_definitions(TestMumbleCore PRIVATE "MUMBLE_CORE_LEGACY_UDP")
endif()

if(MUMBLE_CORE_IN_MUMBLE_TREE)
	set_target_properties(TestMumbleCore PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/tests")
endif()

add_test(NAME TestMumbleCore COMMAND $<TARGET_FILE:TestMumbleCore>)
