// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#ifndef MUMBLE_CONTROLFRAMER_H_
#define MUMBLE_CONTROLFRAMER_H_

#include <cstdint>
#include <deque>
#include <optional>
#include <span>
#include <vector>

namespace Mumble {
namespace Protocol {

	/// Every control message on the TLS stream starts with this: a 16-bit message type and a 32-bit payload
	/// length, both big-endian.
	constexpr std::size_t CONTROL_HEADER_SIZE = 6;
	/// The longest payload either end accepts. A longer one is a reason to disconnect.
	constexpr std::uint32_t MAX_CONTROL_PAYLOAD_SIZE = 0x7fffff;

	struct ControlHeader {
		std::uint16_t type   = 0;
		std::uint32_t length = 0;
	};

	void writeControlHeader(std::uint8_t *dst, std::uint16_t type, std::uint32_t length);
	ControlHeader readControlHeader(const std::uint8_t *src);

	struct ControlMessage {
		std::uint16_t type = 0;
		std::vector< std::uint8_t > payload;
	};

	/**
	 * Splits the control stream into messages, for a host that reads the TLS socket itself. Bytes go in as
	 * they arrive, in whatever pieces; whole messages come out.
	 */
	class ControlFramer {
	public:
		/// Returns false, and keeps returning false, once the stream announces a payload longer than
		/// MAX_CONTROL_PAYLOAD_SIZE. Nothing after that point can be trusted to be framed correctly.
		bool feed(std::span< const std::uint8_t > bytes);

		std::optional< ControlMessage > next();

		bool failed() const { return m_failed; }

		/// The type and length header followed by the payload, ready to write to the stream. Empty if the
		/// payload is too long to send.
		static std::vector< std::uint8_t > frame(std::uint16_t type, std::span< const std::uint8_t > payload);

	private:
		std::vector< std::uint8_t > m_buffer;
		std::deque< ControlMessage > m_ready;
		bool m_failed = false;
	};

} // namespace Protocol
} // namespace Mumble

#endif // MUMBLE_CONTROLFRAMER_H_
