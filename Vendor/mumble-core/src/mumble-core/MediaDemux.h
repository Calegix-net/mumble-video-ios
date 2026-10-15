// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#ifndef MUMBLE_MEDIADEMUX_H_
#define MUMBLE_MEDIADEMUX_H_

#include "VideoTransport.h"

#include <cstdint>
#include <span>

namespace Mumble {
namespace Protocol {

	enum class MediaChannel {
		/// Too short to be anything, or a channel byte nobody uses. Drop it.
		Unknown,
		Audio,
		Video,
	};

	struct MediaDatagram {
		MediaChannel channel = MediaChannel::Unknown;
		/// The whole datagram, as read. The video crypt state takes it like this: it checks the channel byte
		/// itself.
		std::span< const byte > datagram;
		/// What the audio crypt state takes: the datagram past the channel byte, if it has one.
		std::span< const byte > payload;
	};

	/**
	 * Works out which media channel a datagram from the UDP socket belongs to, before anything is decrypted,
	 * since audio and video hold separate crypt states and neither can decrypt the other's packets.
	 *
	 * The framing is per connection: this fork puts a channel byte in front of every datagram (MEDIA_CHANNEL_*
	 * in VideoTransport.h), while stock Mumble sends the bare OCB2 payload and only ever audio.
	 */
	class MediaDemux {
	public:
		enum class Framing {
			/// [channel byte][crypt payload]. Every datagram between this fork's clients and server.
			ChannelByte,
			/// The bare OCB2 payload of stock Mumble: audio and pings, no video.
			Plain,
		};

		explicit MediaDemux(Framing framing = Framing::ChannelByte) : m_framing(framing) {}

		Framing framing() const { return m_framing; }
		void setFraming(Framing framing) { m_framing = framing; }

		MediaDatagram classify(std::span< const byte > datagram) const;

	private:
		Framing m_framing;
	};

} // namespace Protocol
} // namespace Mumble

#endif // MUMBLE_MEDIADEMUX_H_
