// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#include "ControlFramer.h"

#include <cstring>

namespace Mumble {
namespace Protocol {

	void writeControlHeader(std::uint8_t *dst, std::uint16_t type, std::uint32_t length) {
		dst[0] = static_cast< std::uint8_t >(type >> 8);
		dst[1] = static_cast< std::uint8_t >(type & 0xFF);
		dst[2] = static_cast< std::uint8_t >(length >> 24);
		dst[3] = static_cast< std::uint8_t >((length >> 16) & 0xFF);
		dst[4] = static_cast< std::uint8_t >((length >> 8) & 0xFF);
		dst[5] = static_cast< std::uint8_t >(length & 0xFF);
	}

	ControlHeader readControlHeader(const std::uint8_t *src) {
		ControlHeader header;
		header.type   = static_cast< std::uint16_t >((src[0] << 8) | src[1]);
		header.length = (static_cast< std::uint32_t >(src[2]) << 24) | (static_cast< std::uint32_t >(src[3]) << 16)
						| (static_cast< std::uint32_t >(src[4]) << 8) | static_cast< std::uint32_t >(src[5]);
		return header;
	}

	bool ControlFramer::feed(std::span< const std::uint8_t > bytes) {
		if (m_failed) {
			return false;
		}

		m_buffer.insert(m_buffer.end(), bytes.begin(), bytes.end());

		std::size_t offset = 0;
		while (m_buffer.size() - offset >= CONTROL_HEADER_SIZE) {
			const ControlHeader header = readControlHeader(m_buffer.data() + offset);

			if (header.length > MAX_CONTROL_PAYLOAD_SIZE) {
				m_failed = true;
				m_buffer.clear();
				return false;
			}

			if (m_buffer.size() - offset - CONTROL_HEADER_SIZE < header.length) {
				break;
			}

			const auto begin = m_buffer.begin() + static_cast< std::ptrdiff_t >(offset + CONTROL_HEADER_SIZE);
			m_ready.push_back({ header.type, std::vector< std::uint8_t >(begin, begin + header.length) });
			offset += CONTROL_HEADER_SIZE + header.length;
		}

		m_buffer.erase(m_buffer.begin(), m_buffer.begin() + static_cast< std::ptrdiff_t >(offset));

		return true;
	}

	std::optional< ControlMessage > ControlFramer::next() {
		if (m_ready.empty()) {
			return std::nullopt;
		}

		ControlMessage message = std::move(m_ready.front());
		m_ready.pop_front();
		return message;
	}

	std::vector< std::uint8_t > ControlFramer::frame(std::uint16_t type, std::span< const std::uint8_t > payload) {
		if (payload.size() > MAX_CONTROL_PAYLOAD_SIZE) {
			return {};
		}

		std::vector< std::uint8_t > framed(CONTROL_HEADER_SIZE + payload.size());
		writeControlHeader(framed.data(), type, static_cast< std::uint32_t >(payload.size()));
		if (!payload.empty()) {
			std::memcpy(framed.data() + CONTROL_HEADER_SIZE, payload.data(), payload.size());
		}

		return framed;
	}

} // namespace Protocol
} // namespace Mumble
