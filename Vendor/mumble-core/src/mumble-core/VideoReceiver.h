// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#ifndef MUMBLE_VIDEORECEIVER_H_
#define MUMBLE_VIDEORECEIVER_H_

#include "MumbleUDP.pb.h"
#include "VideoFragmentation.h"
#include "VideoTransport.h"

#include <cstdint>
#include <span>
#include <vector>

namespace Mumble {
namespace Protocol {

	/// What one video-channel datagram turned into. Cleared by nothing: the caller passes a fresh one, or
	/// collects several datagrams' worth.
	struct VideoReceiveEvents {
		/// Units this datagram completed.
		std::vector< VideoUnit > units;
		/// Serialised MumbleUDP::VideoNack messages (without the message-type byte) that the server forwarded:
		/// a viewer asking for parts of one of our own streams again. The sending side answers them.
		std::vector< std::vector< byte > > nacksForUs;
		/// Our own retransmission requests, as plaintext video-channel packets to encrypt and send.
		std::vector< std::vector< byte > > packetsToSend;
		/// Whether this datagram triggered the periodic retransmission-request pass, and how many incomplete
		/// units that pass found (more than packetsToSend carries when the pacing cut it short).
		bool collectedNacks        = false;
		std::size_t unitsRequested = 0;
	};

	/**
	 * Receives video: decrypts video-channel datagrams, reassembles units and asks for whatever stays missing.
	 *
	 * Only the network half for now. Keyframe gating and joining the units of one H.264 frame still happen
	 * above this, in the client.
	 *
	 * Not thread safe. The crypt state is passed in rather than owned because on the desktop the same one
	 * encrypts outgoing video from another thread (its encrypt and decrypt halves are independent).
	 */
	class VideoReceiver {
	public:
		/// How often, at most, incomplete units are looked for. Driven by arriving packets, which is exactly
		/// when there is anything to ask about.
		static constexpr std::uint64_t NACK_COLLECT_INTERVAL_USEC = 10 * 1000;
		/// Retransmission requests per second, at most, so a burst of loss costs the server's rate limit for
		/// this client a bounded amount, leaving room for its subscriptions and keyframe requests.
		static constexpr unsigned int MAX_NACK_MESSAGES_PER_SECOND = 30;

		/**
		 * Feeds one datagram from the video channel, channel byte included.
		 *
		 * Anything that does not decrypt, is not video, or carries no sender stamp is dropped without a word:
		 * all of it is attacker-controlled input.
		 */
		void receive(VideoCryptState &crypt, std::span< const byte > datagram, std::uint64_t nowUsec,
					 VideoReceiveEvents &events);

		/// Drops everything held for a sender, when they leave or stop sending.
		void removeSender(std::uint32_t senderSession) { m_reassembler.removeSender(senderSession); }

		const VideoReassembler &reassembler() const { return m_reassembler; }

	private:
		VideoReassembler m_reassembler;

		/// Scratch message used to read the server's sender stamp before reassembly.
		MumbleUDP::Video m_peek;

		std::uint64_t m_lastNackCollectUsec = 0;
		std::uint64_t m_nackWindowStartUsec = 0;
		unsigned int m_nackMessagesInWindow = 0;

		void collectNacks(std::uint64_t nowUsec, VideoReceiveEvents &events);
	};

	/// A VideoNack as a plaintext video-channel packet: the message-type byte, then the message. Empty if it
	/// does not serialise.
	std::vector< byte > encodeVideoNackPacket(const MumbleUDP::VideoNack &nack);

} // namespace Protocol
} // namespace Mumble

#endif // MUMBLE_VIDEORECEIVER_H_
