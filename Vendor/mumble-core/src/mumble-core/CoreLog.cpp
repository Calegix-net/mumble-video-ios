// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#include "CoreLog.h"

#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>

namespace Mumble {
namespace Core {

	namespace {
		std::atomic< LogHandler > g_handler = nullptr;

		void dispatch(LogLevel level, const char *format, va_list args) {
			char message[1024];
			std::vsnprintf(message, sizeof(message), format, args);

			const LogHandler handler = g_handler.load(std::memory_order_acquire);
			if (handler) {
				handler(level, message);
			} else {
				std::fprintf(stderr, "%s\n", message);
			}
		}
	} // namespace

	void setLogHandler(LogHandler handler) {
		g_handler.store(handler, std::memory_order_release);
	}

	void logInfo(const char *format, ...) {
		va_list args;
		va_start(args, format);
		dispatch(LogLevel::Info, format, args);
		va_end(args);
	}

	void logWarning(const char *format, ...) {
		va_list args;
		va_start(args, format);
		dispatch(LogLevel::Warning, format, args);
		va_end(args);
	}

	void logFatal(const char *format, ...) {
		va_list args;
		va_start(args, format);
		dispatch(LogLevel::Fatal, format, args);
		va_end(args);

		std::abort();
	}

} // namespace Core
} // namespace Mumble
