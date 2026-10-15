// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#ifndef MUMBLE_CORELOG_H_
#define MUMBLE_CORELOG_H_

// The core has no Qt and so no qWarning. It reports through a single handler instead, which the
// desktop client and server point at Qt's message handling (see CoreLogBridge in shared) and another
// host can point at its own log. Until one is set, messages go to stderr.

// MinGW's GCC checks plain "printf" against the Microsoft runtime, which has no %zu. The messages are
// formatted by the C++ library's vsnprintf, which on MinGW is the GNU-compatible one.
#if defined(__MINGW32__) && !defined(__clang__)
#	define MUMBLE_CORE_PRINTF_FORMAT(fmt, args) __attribute__((format(gnu_printf, fmt, args)))
#elif defined(__GNUC__) || defined(__clang__)
#	define MUMBLE_CORE_PRINTF_FORMAT(fmt, args) __attribute__((format(printf, fmt, args)))
#else
#	define MUMBLE_CORE_PRINTF_FORMAT(fmt, args)
#endif

namespace Mumble {
namespace Core {

	enum class LogLevel { Info, Warning, Fatal };

	using LogHandler = void (*)(LogLevel level, const char *message);

	/// Replaces the handler. nullptr restores the stderr default. Safe to call from any thread.
	void setLogHandler(LogHandler handler);

	void logInfo(const char *format, ...) MUMBLE_CORE_PRINTF_FORMAT(1, 2);
	void logWarning(const char *format, ...) MUMBLE_CORE_PRINTF_FORMAT(1, 2);
	/// Reports the message and aborts, whatever the handler does.
	[[noreturn]] void logFatal(const char *format, ...) MUMBLE_CORE_PRINTF_FORMAT(1, 2);

} // namespace Core
} // namespace Mumble

#endif // MUMBLE_CORELOG_H_
