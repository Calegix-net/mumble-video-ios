// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#ifndef MUMBLE_VIDEOFRAGMENTATION_H_
#define MUMBLE_VIDEOFRAGMENTATION_H_

#include "MumbleProtocol.h"
#include "VideoTransport.h"

#include <cstdint>
#include <deque>
#include <map>
#include <optional>
#include <set>
#include <span>
#include <utility>
#include <vector>

namespace Mumble {
namespace Protocol {

	// What it costs to stamp sender_session onto an already-serialised message. MumbleUDP.proto specifies
	// that the server appends an encoded field-1 varint rather than reparsing, relying on Protobuf's
	// last-wins rule for singular scalars, so the stamp is charged on top of whatever the sender already
	// encoded: one tag byte plus a five-byte varint.
	constexpr std::size_t SENDER_SESSION_STAMP_OVERHEAD = 6;

	// Upper bound on how many fragments one unit may be split into.
	//
	// This used to be dictated by the crypto layer: sharing CryptStateOCB2 with audio meant a fixed
	// 30-packet late-arrival tolerance, measured to start failing at 31 and to lose 53% of a 64-packet
	// burst delivered in reverse. Video now has its own sequence space and a VIDEO_REPLAY_WINDOW of 128
	// (see VideoTransport.h), so a whole unit arriving backwards still decrypts, and the cap is once
	// again a memory-and-latency decision rather than a workaround.
	//
	// It must stay comfortably below VIDEO_REPLAY_WINDOW, since a unit delivered in reverse needs that
	// many slots of tolerance.
	//
	// 256 (about 275 KB) rather than the original 64 (about 69 KB): screen sharing encodes whole frames
	// with VP9, and a keyframe of a 1080p screen measured 58-123 KB, more for larger screens. Only
	// keyframes come near this; ordinary frames are a few kilobytes. The server relays fragments one by one
	// and never applies this limit, so raising it needs no server change.
	constexpr std::uint32_t MAX_VIDEO_FRAGMENTS_PER_UNIT = 256;

	// How many partially received units a receiver keeps per sender.
	//
	// Sized from the default codec rather than guessed. TiledImage sends one unit per tile, and a 1080p
	// screen at 128px tiles is 135 tiles per frame, all of which can legitimately be in flight at once.
	// The previous value of 8 predated that measurement and would have evicted most of every frame.
	//
	// 512, up from 160: the sender caps one frame's burst at TiledImageEncoder::MAX_UNITS_PER_FRAME
	// (128), but two consecutive frames' worth can overlap in flight under reordering, and a 4K share
	// (510 tiles) refreshing itself was, at 160, guaranteed to have its own oldest half-received tiles
	// evicted here to make room for the newest - each one a black square on the viewer's screen until
	// the next periodic refresh, for no reason a network could be blamed for.
	constexpr std::size_t MAX_PENDING_VIDEO_UNITS_PER_SENDER = 512;

	// Backstop on the number of tracked units across all senders. Memory is bounded by the byte budget
	// below; this exists only so that the bookkeeping cannot grow without limit when units are tiny.
	constexpr std::size_t MAX_PENDING_VIDEO_UNITS_TOTAL = 4096;

	// The real memory bound, across all senders.
	//
	// Counting units is a poor proxy when unit sizes span two orders of magnitude: a measured TiledImage
	// tile ranges from about 2 KB for camera content to 21 KB for dense text. Bounding the bytes
	// actually buffered is both a tighter guarantee and one that does not need re-tuning whenever the
	// tile size or codec changes.
	//
	// 16 MB: enough for the per-sender unit cap above at the largest measured tile size, with room for
	// a second sender, rather than a bound that a single dense-text 4K share could hit on its own.
	constexpr std::size_t MAX_PENDING_VIDEO_BYTES_TOTAL = 16 * 1024 * 1024;

	// How long a partially received unit is kept before it is discarded.
	// Long enough for a lost fragment's retransmission to arrive over a lossy connection: the request rides
	// TCP, whose own retransmission timeout is 200 ms at the least.
	constexpr std::uint64_t VIDEO_REASSEMBLY_TIMEOUT_USEC = 1000 * 1000;

	// Retransmission (MumbleProto::VideoNack). A unit still incomplete this long after its first fragment
	// arrived is asked for again: long enough that fragments merely reordered behind it have turned up,
	// short against the round trip the retransmission itself costs.
	constexpr std::uint64_t VIDEO_NACK_DELAY_USEC = 25 * 1000;
	// A unit is asked for at most this many times, this far apart: a lost retransmission gets one more try.
	// Three: with a whole-frame codec a unit that stays lost freezes the picture until a keyframe, so one
	// more try (at 325 ms) is worth far more than the few bytes it costs, and still well inside
	// VIDEO_REASSEMBLY_TIMEOUT_USEC.
	constexpr unsigned int VIDEO_NACK_MAX_ATTEMPTS = 3;
	constexpr std::uint64_t VIDEO_NACK_RETRY_USEC  = 150 * 1000;
	// Units per VideoNack message, which both ends enforce: it bounds what one request can make a sender
	// re-send.
	constexpr int MAX_VIDEO_NACK_UNITS = 32;
	// How long a sender keeps what it sent, to answer retransmission requests from, and how much of it.
	constexpr std::uint64_t VIDEO_RESEND_HISTORY_USEC = 1000 * 1000;
	constexpr std::size_t VIDEO_RESEND_HISTORY_BYTES  = 8 * 1024 * 1024;

	/// One incomplete unit a receiver would like re-sent. missingFragments: bit i = fragment i missing.
	struct VideoNackRequest {
		std::uint32_t senderSession    = 0;
		std::uint32_t streamID         = 0;
		std::uint64_t frameNumber      = 0;
		std::uint32_t unitID           = 0;
		std::uint64_t missingFragments = 0;
		// Every missing fragment by index, for a unit of more than 64 fragments; missingFragments is then 0.
		std::vector< std::uint32_t > missingIndices;
	};

	/**
	 * Describes one independently decodable unit of a video frame. This is the metadata half of a
	 * MumbleUDP::Video message; the coded bytes are carried separately.
	 */
	struct VideoUnitHeader {
		std::uint32_t senderSession        = 0;
		std::uint32_t streamID             = 0;
		std::uint64_t frameNumber          = 0;
		std::uint32_t unitID               = 0;
		bool isKeyframe                    = false;
		bool isFrameEnd                    = false;
		std::uint64_t captureTimestampUsec = 0;

		// Destination rectangle of this unit within the full frame, in pixels.
		std::uint32_t x      = 0;
		std::uint32_t y      = 0;
		std::uint32_t width  = 0;
		std::uint32_t height = 0;

		friend bool operator==(const VideoUnitHeader &lhs, const VideoUnitHeader &rhs);
		friend bool operator!=(const VideoUnitHeader &lhs, const VideoUnitHeader &rhs);
	};

	/**
	 * A fully reassembled video unit, ready to be handed to a decoder.
	 */
	struct VideoUnit {
		VideoUnitHeader header;
		std::vector< byte > payload;
	};

	/**
	 * Splits a coded video unit into MTU-sized packets.
	 *
	 * Each produced packet is a complete, unencrypted UDP payload: a one-byte UDPMessageType::Video
	 * prefix followed by a serialised MumbleUDP::Video message. Packets are guaranteed to fit within
	 * MAX_VIDEO_DATAGRAM_SIZE once the video transport header and authentication tag are added.
	 *
	 * The fragmenter is reusable; each call to fragment() replaces the previously produced packets and
	 * reuses the buffers they occupied.
	 *
	 * Not reentrant. It holds a reusable Protobuf message and packet buffers, so a single instance must
	 * only ever be touched by one thread at a time. Give each call site its own, exactly as
	 * ServerHandler keeps separate m_udpDecoder and m_tcpTunnelDecoder instances for the raw UDP and
	 * TCP-tunnelled paths.
	 *
	 * The span returned by packets() is invalidated by the next call to fragment(), so the packets must
	 * be sent, or copied, before reusing the fragmenter.
	 */
	class VideoFragmenter {
	public:
		VideoFragmenter() = default;

		/**
		 * The largest number of coded bytes that fit in a single fragment.
		 *
		 * This is computed against a worst-case message in which every metadata field takes its widest
		 * varint encoding, so it is a conservative bound that holds for any header.
		 */
		static std::size_t maxPayloadPerFragment();

		/**
		 * The largest unit this fragmenter will accept, being the point at which a unit would need more
		 * than MAX_VIDEO_FRAGMENTS_PER_UNIT fragments.
		 */
		static std::size_t maxUnitSize();

		/**
		 * Splits the given unit into packets.
		 *
		 * @param header Metadata describing the unit. Its senderSession may be left at 0 by a client, in
		 *   which case the server stamps it when relaying; the size budget accounts for that either way.
		 * @param payload The coded bytes of the unit. May be empty, which produces a single packet.
		 * @returns Whether fragmentation succeeded. It fails only if the payload exceeds maxUnitSize().
		 */
		bool fragment(const VideoUnitHeader &header, std::span< const byte > payload);

		/**
		 * The packets produced by the most recent successful call to fragment().
		 */
		const std::vector< std::vector< byte > > &packets() const { return m_packets; }

	protected:
		std::vector< std::vector< byte > > m_packets;
		MumbleUDP::Video m_message;
	};

	/**
	 * The outcome of feeding a packet to VideoReassembler.
	 */
	enum class VideoReassemblyResult {
		// The packet was accepted but its unit is still incomplete.
		Incomplete,
		// The packet completed a unit, which has been written to the caller's output parameter.
		Complete,
		// The packet was malformed, inconsistent with fragments already received for its unit, or
		// exceeded a limit. It has been discarded, along with any partial unit it belonged to.
		Invalid,
	};

	/**
	 * Reassembles video units from the packets produced by VideoFragmenter.
	 *
	 * Every input is treated as hostile: fragment counts are bounded before anything is allocated, the
	 * number of concurrently tracked units is capped both per sender and globally, and units that never
	 * complete are evicted on a timeout. There is no retransmission, so an incomplete unit is simply
	 * lost.
	 *
	 * Not reentrant, and this matters more here than it looks. The instance holds a reusable Protobuf
	 * message and a mutable map, while the two places video would arrive -- the raw UDP socket and the
	 * TCP tunnel -- run on different threads: on the server the UDP loop is a separate thread promoted
	 * to SCHED_FIFO, whereas tunnelled messages are handled on the main thread under a shared read lock,
	 * so the two genuinely run concurrently. Sharing one instance between them is not merely a race on
	 * the map; a parse on one thread can reallocate the payload string another thread is reading, which
	 * is a use-after-free on attacker-supplied data. Each arrival path therefore needs its own instance,
	 * following the existing m_udpDecoder / m_tcpTunnelDecoder precedent.
	 *
	 * Note also that expiry is driven entirely by the nowUsec a caller passes in. A caller that passes a
	 * constant will never expire anything and will simply fill up to the caps.
	 */
	class VideoReassembler {
	public:
		VideoReassembler() = default;

		/**
		 * Feeds one received packet to the reassembler.
		 *
		 * @param packet A decrypted UDP payload, including its one-byte message-type prefix.
		 * @param senderSession The session this packet is known to have come from. This must come from the
		 *   caller's own trusted context, never from the packet: a server takes it from the connection the
		 *   datagram arrived on, and a client takes it from the value the server stamped, the server being
		 *   trusted to have stamped it truthfully. It is what units are keyed on, so that one peer cannot
		 *   claim to be another and thereby corrupt that peer's partial units or evade the per-sender
		 *   memory limit. A packet whose own sender_session field contradicts it is rejected.
		 * @param nowUsec The current time on a monotonic clock, used to expire stale partial units. It is
		 *   supplied by the caller rather than read here so that the timeout is testable.
		 * @param unit Receives the reassembled unit if, and only if, Complete is returned.
		 */
		VideoReassemblyResult processPacket(std::span< const byte > packet, std::uint32_t senderSession,
											std::uint64_t nowUsec, VideoUnit &unit);

		/**
		 * Discards partial units that have not completed within VIDEO_REASSEMBLY_TIMEOUT_USEC.
		 *
		 * Called automatically by processPacket. It is exposed so that a caller which has stopped
		 * receiving entirely can still release the memory.
		 */
		void expire(std::uint64_t nowUsec);

		/**
		 * Drops all state associated with a sender, for use when that user disconnects or stops sending.
		 */
		void removeSender(std::uint32_t senderSession);

		/**
		 * Appends a retransmission request for every unit that has been incomplete for at least
		 * VIDEO_NACK_DELAY_USEC and has not been asked for VIDEO_NACK_MAX_ATTEMPTS times yet (attempts at
		 * least VIDEO_NACK_RETRY_USEC apart), and records the attempt.
		 */
		void collectNacks(std::uint64_t nowUsec, std::vector< VideoNackRequest > &out);

		/**
		 * The number of partial units currently being tracked, across all senders.
		 */
		std::size_t pendingUnitCount() const { return m_pending.size(); }

		/**
		 * The number of payload bytes currently buffered across all partial units. This is the quantity
		 * MAX_PENDING_VIDEO_BYTES_TOTAL bounds.
		 */
		std::size_t bufferedBytes() const { return m_bufferedBytes; }

	protected:
		struct UnitKey {
			std::uint32_t senderSession;
			std::uint32_t streamID;
			std::uint64_t frameNumber;
			std::uint32_t unitID;

			bool operator<(const UnitKey &other) const;
		};

		struct PendingUnit {
			VideoUnitHeader header;
			std::uint32_t fragmentCount = 0;
			// Indexed by fragment index. Sized to fragmentCount, which is bounded by
			// MAX_VIDEO_FRAGMENTS_PER_UNIT before this is allocated.
			std::vector< std::vector< byte > > fragments;
			// Entry i is set once fragment i has been stored; receivedCount reaching fragmentCount means the
			// unit is complete. A unit can have more fragments than a 64-bit mask holds (a VP9 keyframe of
			// a whole screen runs to well over a hundred), so this is no longer a single integer.
			std::vector< bool > received;
			std::uint32_t receivedCount = 0;
			std::size_t totalBytes      = 0;
			std::uint64_t firstSeenUsec = 0;
			// Whether the geometry fields have been filled in, which only happens once fragment 0 arrives.
			bool haveGeometry = false;
			// Retransmission requests already made for this unit, and when the last one was.
			unsigned int nackAttempts  = 0;
			std::uint64_t lastNackUsec = 0;
		};

		std::map< UnitKey, PendingUnit > m_pending;

		// Units completed within the last VIDEO_REASSEMBLY_TIMEOUT_USEC (at most MAX_REMEMBERED_COMPLETE).
		// A fragment of one of these is a duplicate - typically a retransmission the server relays to every
		// subscriber although only one asked - and must not start a new partial unit: that unit would never
		// complete, would be asked for again, and the answer would reach every other subscriber in turn,
		// a feedback loop between viewers.
		static constexpr std::size_t MAX_REMEMBERED_COMPLETE = 4096;
		std::set< UnitKey > m_recentlyCompleted;
		std::deque< std::pair< std::uint64_t, UnitKey > > m_completedOrder;
		void rememberCompleted(const UnitKey &key, std::uint64_t nowUsec);

		// Units keyed by their creation time, so that "which is the oldest" is the front of this rather
		// than a scan of m_pending. Measured: without it, admitting one fragment while the pool is full
		// costs about 10 microseconds, because every admission walks every tracked unit. That is far too
		// much for a thread that also carries audio.
		std::multimap< std::uint64_t, UnitKey > m_byAge;

		// The earliest deadline among all tracked units, so that the common case -- nothing is due to
		// expire yet -- costs a comparison instead of a walk over the whole map. Zero means "unknown",
		// which forces a full sweep and recomputes it.
		std::uint64_t m_nextExpiryUsec = 0;

		// Sum of totalBytes over every tracked unit, maintained incrementally so the memory bound can be
		// checked without walking the map.
		std::size_t m_bufferedBytes = 0;

		MumbleUDP::Video m_message;

		/**
		 * Evicts the oldest partial unit belonging to the given sender if that sender is already at the
		 * per-sender limit.
		 */
		void enforceSenderLimit(std::uint32_t senderSession);

		/**
		 * Evicts the oldest partial units, from any sender, until there is room for one more within both
		 * MAX_PENDING_VIDEO_UNITS_TOTAL and MAX_PENDING_VIDEO_BYTES_TOTAL.
		 */
		void enforceGlobalLimit();

		/**
		 * Makes room for `incoming` further payload bytes within MAX_PENDING_VIDEO_BYTES_TOTAL by evicting
		 * the oldest partial units, never touching the one identified by `protect`.
		 *
		 * Enforcing the budget only when a unit is created would not bound anything: a bounded number of
		 * units can each keep growing as their fragments arrive, so the check has to happen on every
		 * fragment stored.
		 */
		void enforceByteBudget(std::size_t incoming, const UnitKey &protect);

		/**
		 * Erases a tracked unit, keeping the buffered-byte total in step. Every removal must go through
		 * this rather than calling erase directly, or the byte accounting drifts and the memory bound
		 * stops holding.
		 */
		std::map< UnitKey, PendingUnit >::iterator eraseUnit(std::map< UnitKey, PendingUnit >::iterator it);
	};

} // namespace Protocol
} // namespace Mumble

#endif // MUMBLE_VIDEOFRAGMENTATION_H_
