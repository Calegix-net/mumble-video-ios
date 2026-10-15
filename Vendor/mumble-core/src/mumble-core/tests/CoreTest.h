// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#ifndef MUMBLE_CORE_TESTS_CORETEST_H_
#define MUMBLE_CORE_TESTS_CORETEST_H_

// Just enough of a test harness for the core tests, which cannot use QtTest.

#include <cstdio>
#include <functional>
#include <string>
#include <vector>

namespace CoreTest {

struct Case {
	const char *name;
	std::function< void() > run;
};

inline std::vector< Case > &cases() {
	static std::vector< Case > all;
	return all;
}

inline int &failures() {
	static int count = 0;
	return count;
}

struct Registrar {
	Registrar(const char *name, std::function< void() > run) { cases().push_back({ name, std::move(run) }); }
};

inline void fail(const char *file, int line, const std::string &what) {
	std::fprintf(stderr, "%s:%d: FAIL: %s\n", file, line, what.c_str());
	failures()++;
}

inline int runAll() {
	int failedCases = 0;
	for (const Case &c : cases()) {
		const int before = failures();
		c.run();
		const bool ok = failures() == before;
		std::printf("%s %s\n", ok ? "PASS" : "FAIL", c.name);
		if (!ok) {
			failedCases++;
		}
	}
	std::printf("%zu cases, %d failed\n", cases().size(), failedCases);
	return failedCases == 0 ? 0 : 1;
}

} // namespace CoreTest

#define CORE_TEST_CONCAT_(a, b) a##b
#define CORE_TEST_CONCAT(a, b) CORE_TEST_CONCAT_(a, b)

#define CORE_TEST(name)                                                         \
	static void name();                                                         \
	static CoreTest::Registrar CORE_TEST_CONCAT(registrar_, name)(#name, name); \
	static void name()

// Like QVERIFY/QCOMPARE, these return from the test case on failure.
#define CHECK(cond)                                    \
	do {                                               \
		if (!(cond)) {                                 \
			CoreTest::fail(__FILE__, __LINE__, #cond); \
			return;                                    \
		}                                              \
	} while (false)

#define CHECK_EQ(actual, expected)                                                     \
	do {                                                                               \
		if (!((actual) == (expected))) {                                               \
			CoreTest::fail(__FILE__, __LINE__, std::string(#actual " == " #expected)); \
			return;                                                                    \
		}                                                                              \
	} while (false)

#endif // MUMBLE_CORE_TESTS_CORETEST_H_
