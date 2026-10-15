// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#include "VideoFragmentation.h"

#include <algorithm>
#include <cassert>
#include <limits>
#include <tuple>

namespace Mumble {
namespace Protocol {

	bool operator==(const VideoUnitHeader &lhs, const VideoUnitHeader &rhs) {
		return lhs.senderSession == rhs.senderSession && lhs.streamID == rhs.streamID
			   && lhs.frameNumber == rhs.frameNumber && lhs.unitID == rhs.unitID && lhs.isKeyframe == rhs.isKeyframe
			   && lhs.isFrameEnd == rhs.isFrameEnd && lhs.captureTimestampUsec == rhs.captureTimestampUsec
			   && lhs.x == rhs.x && lhs.y == rhs.y && lhs.width == rhs.width && lhs.height == rhs.height;
	}

	bool operator!=(const VideoUnitHeader &lhs, const VideoUnitHeader &rhs) {
		return !(lhs == rhs);
	}


	std::size_t VideoFragmenter::maxPayloadPerFragment() {
		// Computed once. The result depends only on compile-time constants and on how Protobuf encodes a
		// worst-case message, neither of which changes at runtime.
		static const std::size_t maxPayload = [] {
			MumbleUDP::Video probe;

			// Give every field its widest encoding. Protobuf omits fields holding their default value, so
			// maximal values here really do produce the largest possible metadata. sender_session is
			// included even though a client leaves it unset, because the server stamps it when relaying
			// and the packet must still fit afterwards.
			probe.set_sender_session(std::numeric_limits< std::uint32_t >::max());
			probe.set_stream_id(std::numeric_limits< std::uint32_t >::max());
			probe.set_frame_number(std::numeric_limits< std::uint64_t >::max());
			probe.set_unit_id(std::numeric_limits< std::uint32_t >::max());
			probe.set_fragment_index(std::numeric_limits< std::uint32_t >::max());
			probe.set_fragment_count(std::numeric_limits< std::uint32_t >::max());
			probe.set_is_keyframe(true);
			probe.set_is_frame_end(true);
			probe.set_capture_timestamp_usec(std::numeric_limits< std::uint64_t >::max());
			probe.set_x(std::numeric_limits< std::uint32_t >::max());
			probe.set_y(std::numeric_limits< std::uint32_t >::max());
			probe.set_width(std::numeric_limits< std::uint32_t >::max());
			probe.set_height(std::numeric_limits< std::uint32_t >::max());

			// The geometry fields are only ever set on fragment 0, but budgeting for them on every
			// fragment costs about twenty bytes and removes a whole class of off-by-one.
			const std::size_t metadataSize = probe.ByteSizeLong();

			// The payload field itself costs a one-byte tag (its index is below 16) plus a length varint.
			// Two length bytes cover any size up to 16383, comfortably more than the budget allows.
			constexpr std::size_t payloadFieldOverhead = 1 + 2;

			// The probe already counts sender_session once, which covers a sender that encoded it itself.
			// A relaying server appends a second copy without removing the first, so the worst case is
			// that the field appears twice and both copies have to fit.
			const std::size_t overhead = metadataSize + payloadFieldOverhead + SENDER_SESSION_STAMP_OVERHEAD;

			// All three terms are unsigned. If MumbleUDP::Video ever grows enough mandatory metadata to
			// exhaust the budget, an unguarded subtraction would wrap to an enormous value, which would in
			// turn make maxUnitSize() meaningless and remove the receiver's memory bound. Failing loudly
			// here is much better than that.
			assert(overhead < MAX_VIDEO_PROTOBUF_SIZE);

			if (overhead >= MAX_VIDEO_PROTOBUF_SIZE) {
				return std::size_t{ 0 };
			}

			return MAX_VIDEO_PROTOBUF_SIZE - overhead;
		}();

		return maxPayload;
	}

	std::size_t VideoFragmenter::maxUnitSize() {
		return MAX_VIDEO_FRAGMENTS_PER_UNIT * maxPayloadPerFragment();
	}

	bool VideoFragmenter::fragment(const VideoUnitHeader &header, std::span< const byte > payload) {
		const std::size_t maxPayload = maxPayloadPerFragment();

		if (maxPayload == 0) {
			// Only reachable if the message grew past its own budget; see maxPayloadPerFragment.
			m_packets.clear();
			return false;
		}

		// Checked before the division below rather than after, so that a pathologically large span cannot
		// overflow the round-up and yield a small fragment count that silently truncates the unit.
		if (payload.size() > maxUnitSize()) {
			m_packets.clear();
			return false;
		}

		// An empty unit still produces one packet, so that a sender can signal end-of-frame without
		// having any coded bytes to go with it.
		const std::size_t fragmentCount = payload.empty() ? 1 : (payload.size() + maxPayload - 1) / maxPayload;

		if (fragmentCount > MAX_VIDEO_FRAGMENTS_PER_UNIT) {
			m_packets.clear();
			return false;
		}

		// Resized rather than cleared and refilled, so that the packet buffers from the previous call keep
		// their capacity. A steady stream fragments to the same count every frame, so after the first
		// frame this loop stops allocating entirely.
		m_packets.resize(fragmentCount);

		for (std::size_t i = 0; i < fragmentCount; ++i) {
			const std::size_t offset = i * maxPayload;
			const std::size_t chunk  = std::min(maxPayload, payload.size() - offset);

			m_message.Clear();
			m_message.set_sender_session(header.senderSession);
			m_message.set_stream_id(header.streamID);
			m_message.set_frame_number(header.frameNumber);
			m_message.set_unit_id(header.unitID);
			m_message.set_fragment_index(static_cast< std::uint32_t >(i));
			m_message.set_fragment_count(static_cast< std::uint32_t >(fragmentCount));
			m_message.set_is_keyframe(header.isKeyframe);
			m_message.set_is_frame_end(header.isFrameEnd);
			m_message.set_capture_timestamp_usec(header.captureTimestampUsec);

			if (i == 0) {
				m_message.set_x(header.x);
				m_message.set_y(header.y);
				m_message.set_width(header.width);
				m_message.set_height(header.height);
			}

			// Guarded because an empty span's data() is null, and handing that to Protobuf would mean a
			// zero-length copy from a null pointer.
			if (chunk > 0) {
				m_message.set_payload(payload.data() + offset, chunk);
			}

			const std::size_t messageSize = m_message.ByteSizeLong();

			// maxPayloadPerFragment is meant to guarantee this. Checking anyway means a mistake in that
			// calculation surfaces as a dropped frame rather than as a packet silently discarded by the
			// far end, which would be considerably harder to diagnose.
			if (messageSize > MAX_VIDEO_PROTOBUF_SIZE) {
				m_packets.clear();
				return false;
			}

			std::vector< byte > &packet = m_packets[i];
			packet.resize(messageSize + 1);
			packet[0] = static_cast< byte >(UDPMessageType::Video);

			if (!m_message.SerializeToArray(packet.data() + 1, static_cast< int >(messageSize))) {
				m_packets.clear();
				return false;
			}
		}

		return true;
	}


	bool VideoReassembler::UnitKey::operator<(const UnitKey &other) const {
		return std::tie(senderSession, streamID, frameNumber, unitID)
			   < std::tie(other.senderSession, other.streamID, other.frameNumber, other.unitID);
	}

	std::map< VideoReassembler::UnitKey, VideoReassembler::PendingUnit >::iterator
		VideoReassembler::eraseUnit(std::map< UnitKey, PendingUnit >::iterator it) {
		m_bufferedBytes -= it->second.totalBytes;

		// Drop the matching age-index entry. Several units can share a timestamp, so the right one is
		// found by key within that timestamp's range; in practice the range holds one or two entries.
		const auto range = m_byAge.equal_range(it->second.firstSeenUsec);

		for (auto ageIt = range.first; ageIt != range.second; ++ageIt) {
			if (!(ageIt->second < it->first) && !(it->first < ageIt->second)) {
				m_byAge.erase(ageIt);
				break;
			}
		}

		return m_pending.erase(it);
	}

	void VideoReassembler::expire(std::uint64_t nowUsec) {
		if (m_pending.empty()) {
			m_nextExpiryUsec = 0;
			return;
		}

		// The overwhelmingly common case: the earliest deadline is still in the future, so nothing can
		// possibly be expired and the map does not need walking at all. Without this the sweep is linear
		// in the number of tracked units on every single packet.
		if (m_nextExpiryUsec != 0 && nowUsec <= m_nextExpiryUsec) {
			return;
		}

		std::uint64_t earliest = 0;

		for (auto it = m_pending.begin(); it != m_pending.end();) {
			// Comparing against a deadline rather than subtracting keeps this correct if the caller's
			// clock ever moves backwards: the entry is simply kept until the clock catches up.
			const std::uint64_t deadline = it->second.firstSeenUsec + VIDEO_REASSEMBLY_TIMEOUT_USEC;

			if (nowUsec > deadline) {
				it = eraseUnit(it);
			} else {
				if (earliest == 0 || deadline < earliest) {
					earliest = deadline;
				}

				++it;
			}
		}

		m_nextExpiryUsec = earliest;
	}

	void VideoReassembler::removeSender(std::uint32_t senderSession) {
		const UnitKey lower{ senderSession, 0, 0, 0 };
		const UnitKey upper{ senderSession, std::numeric_limits< std::uint32_t >::max(),
							 std::numeric_limits< std::uint64_t >::max(), std::numeric_limits< std::uint32_t >::max() };

		auto it        = m_pending.lower_bound(lower);
		const auto end = m_pending.upper_bound(upper);

		// Erased one at a time rather than as a range so that the buffered-byte total stays correct.
		while (it != end) {
			it = eraseUnit(it);
		}
	}

	void VideoReassembler::collectNacks(std::uint64_t nowUsec, std::vector< VideoNackRequest > &out) {
		for (auto &entry : m_pending) {
			PendingUnit &unit = entry.second;

			if (unit.nackAttempts >= VIDEO_NACK_MAX_ATTEMPTS || nowUsec < unit.firstSeenUsec + VIDEO_NACK_DELAY_USEC) {
				continue;
			}
			if (unit.nackAttempts > 0 && nowUsec < unit.lastNackUsec + VIDEO_NACK_RETRY_USEC) {
				continue;
			}

			if (unit.receivedCount >= unit.fragmentCount) {
				continue;
			}

			// A unit of up to 64 fragments names what it is missing in a 64-bit mask. A larger one - a VP9
			// keyframe - lists the missing indices instead, with an empty mask: re-sending a whole 100-fragment
			// keyframe because one fragment was lost loses another fragment as often as not under the very
			// loss that caused the request, and the picture never recovers.
			std::uint64_t missing = 0;
			std::vector< std::uint32_t > missingIndices;
			for (std::uint32_t i = 0; i < unit.fragmentCount; ++i) {
				if (unit.received[i]) {
					continue;
				}
				if (unit.fragmentCount > 64) {
					missingIndices.push_back(i);
				} else {
					missing |= std::uint64_t{ 1 } << i;
				}
			}

			++unit.nackAttempts;
			unit.lastNackUsec = nowUsec;

			VideoNackRequest request;
			request.senderSession    = entry.first.senderSession;
			request.streamID         = entry.first.streamID;
			request.frameNumber      = entry.first.frameNumber;
			request.unitID           = entry.first.unitID;
			request.missingFragments = missing;
			request.missingIndices   = std::move(missingIndices);
			out.push_back(std::move(request));
		}
	}

	void VideoReassembler::enforceSenderLimit(std::uint32_t senderSession) {
		const UnitKey lower{ senderSession, 0, 0, 0 };
		const UnitKey upper{ senderSession, std::numeric_limits< std::uint32_t >::max(),
							 std::numeric_limits< std::uint64_t >::max(), std::numeric_limits< std::uint32_t >::max() };

		auto begin = m_pending.lower_bound(lower);
		auto end   = m_pending.upper_bound(upper);

		std::size_t count = static_cast< std::size_t >(std::distance(begin, end));

		// Evict oldest-first until there is room for one more. This is a loop rather than a single
		// eviction so that lowering the limit at runtime could not leave the map permanently over it.
		//
		// The victim is found through the age index rather than by scanning the sender's range, for the
		// same reason enforceGlobalLimit uses it: with a limit of 160 units, a scan-per-eviction is up to
		// 160x160 comparisons on the thread that also carries audio.
		while (count >= MAX_PENDING_VIDEO_UNITS_PER_SENDER) {
			auto oldest = m_pending.end();

			for (auto ageIt = m_byAge.begin(); ageIt != m_byAge.end(); ++ageIt) {
				if (ageIt->second.senderSession != senderSession) {
					continue;
				}

				oldest = m_pending.find(ageIt->second);

				if (oldest != m_pending.end()) {
					break;
				}
			}

			if (oldest == m_pending.end()) {
				break;
			}

			eraseUnit(oldest);

			begin = m_pending.lower_bound(lower);
			end   = m_pending.upper_bound(upper);
			count = static_cast< std::size_t >(std::distance(begin, end));
		}
	}

	void VideoReassembler::enforceGlobalLimit() {
		// Two separate ceilings: a byte budget, which is the actual memory bound, and a unit count, which
		// only exists so that a flood of tiny units cannot blow up the bookkeeping while staying well
		// under the byte budget.
		while (
			!m_pending.empty()
			&& (m_pending.size() >= MAX_PENDING_VIDEO_UNITS_TOTAL || m_bufferedBytes > MAX_PENDING_VIDEO_BYTES_TOTAL)) {
			if (m_byAge.empty()) {
				break;
			}

			const auto oldest = m_pending.find(m_byAge.begin()->second);

			if (oldest == m_pending.end()) {
				// The index disagrees with the map, which should not happen. Drop the stale entry rather
				// than spinning on it forever.
				m_byAge.erase(m_byAge.begin());
				continue;
			}

			eraseUnit(oldest);
		}
	}

	void VideoReassembler::enforceByteBudget(std::size_t incoming, const UnitKey &protect) {
		while (m_bufferedBytes + incoming > MAX_PENDING_VIDEO_BYTES_TOTAL) {
			auto oldest = m_pending.end();

			// Walks the age index from the front, so it stops at the first or second entry rather than
			// scanning every tracked unit.
			for (auto ageIt = m_byAge.begin(); ageIt != m_byAge.end(); ++ageIt) {
				// Skip the unit the incoming fragment belongs to; evicting it would make storing the
				// fragment pointless and would invalidate the caller's iterator.
				if (!(protect < ageIt->second) && !(ageIt->second < protect)) {
					continue;
				}

				oldest = m_pending.find(ageIt->second);

				if (oldest != m_pending.end()) {
					break;
				}
			}

			if (oldest == m_pending.end()) {
				// Nothing left to give up. The caller stores the fragment anyway: a single unit is capped
				// at maxUnitSize() regardless, so this cannot run away.
				break;
			}

			eraseUnit(oldest);
		}
	}

	VideoReassemblyResult VideoReassembler::processPacket(std::span< const byte > packet, std::uint32_t senderSession,
														  std::uint64_t nowUsec, VideoUnit &unit) {
		// Deliberately after the cheap validation below rather than before it. Expiry is the most
		// expensive thing this function does, and running it first would let a peer spraying malformed
		// two-byte packets force that work on every one of them -- on the server that is a real-time
		// thread shared with audio.
		if (packet.size() < 2) {
			// One byte of message type plus at least something to parse. A Video message with every field
			// at its default would serialise to nothing, but such a message carries no payload and no
			// fragment count, so it is rejected below anyway.
			return VideoReassemblyResult::Invalid;
		}

		if (packet[0] != static_cast< byte >(UDPMessageType::Video)) {
			return VideoReassemblyResult::Invalid;
		}

		const std::size_t protobufSize = packet.size() - 1;

		if (protobufSize > MAX_VIDEO_PROTOBUF_SIZE) {
			return VideoReassemblyResult::Invalid;
		}

		m_message.Clear();

		if (!m_message.ParseFromArray(packet.data() + 1, static_cast< int >(protobufSize))) {
			return VideoReassemblyResult::Invalid;
		}

		const std::uint32_t fragmentCount = m_message.fragment_count();
		const std::uint32_t fragmentIndex = m_message.fragment_index();

		// Both bounds are checked before anything is allocated. fragment_count is attacker-controlled and
		// is what sizes the fragment table.
		if (fragmentCount == 0 || fragmentCount > MAX_VIDEO_FRAGMENTS_PER_UNIT) {
			return VideoReassemblyResult::Invalid;
		}

		if (fragmentIndex >= fragmentCount) {
			return VideoReassemblyResult::Invalid;
		}

		// A sender that fills in sender_session must agree with the caller's trusted view of who it is.
		// Rejecting the mismatch rather than quietly ignoring the field means a relay that stamps the
		// wrong session shows up as dropped video rather than as units mysteriously attributed to the
		// wrong user.
		if (m_message.sender_session() != 0 && m_message.sender_session() != senderSession) {
			return VideoReassemblyResult::Invalid;
		}

		// Keyed on the caller's authenticated session, never on the wire field. Otherwise one peer could
		// address another peer's partial units, and the per-sender memory limit would bound nothing,
		// since a single peer could mint unlimited identities.
		const UnitKey key{ senderSession, m_message.stream_id(), m_message.frame_number(), m_message.unit_id() };

		// The packet is now known to be well formed and to come from a peer we can name, so it is worth
		// spending the expiry sweep on it.
		expire(nowUsec);

		if (m_recentlyCompleted.count(key)) {
			// Already delivered: a duplicate, usually a retransmission meant for another subscriber.
			return VideoReassemblyResult::Incomplete;
		}

		auto it = m_pending.find(key);

		if (it == m_pending.end()) {
			// Sender limit first, then the global one. The other order lets a sender that is already at
			// its own quota evict a *different*, well-behaved sender's unit before trimming its own, which
			// would let one peer destroy everyone else's partial video at line rate without ever exceeding
			// its nominal allowance.
			enforceSenderLimit(key.senderSession);
			enforceGlobalLimit();

			PendingUnit fresh;
			fresh.fragmentCount = fragmentCount;
			fresh.fragments.resize(fragmentCount);
			fresh.received.assign(fragmentCount, false);
			fresh.firstSeenUsec = nowUsec;

			const std::uint64_t deadline = nowUsec + VIDEO_REASSEMBLY_TIMEOUT_USEC;

			if (m_nextExpiryUsec == 0 || deadline < m_nextExpiryUsec) {
				m_nextExpiryUsec = deadline;
			}

			fresh.header.senderSession = key.senderSession;
			fresh.header.streamID      = key.streamID;
			fresh.header.frameNumber   = key.frameNumber;
			fresh.header.unitID        = key.unitID;

			it = m_pending.emplace(key, std::move(fresh)).first;
			m_byAge.emplace(nowUsec, key);
		}

		PendingUnit &pending = it->second;

		// A sender that changes its mind about how many fragments a unit has is either broken or hostile.
		// Either way the partial unit can no longer be trusted.
		if (pending.fragmentCount != fragmentCount) {
			eraseUnit(it);
			return VideoReassemblyResult::Invalid;
		}

		if (pending.received[fragmentIndex]) {
			// A duplicate, which UDP produces routinely. Keep the copy already held.
			return VideoReassemblyResult::Incomplete;
		}

		const std::string &payload = m_message.payload();

		if (pending.totalBytes + payload.size() > VideoFragmenter::maxUnitSize()) {
			eraseUnit(it);
			return VideoReassemblyResult::Invalid;
		}

		// Checked on every stored fragment, not just on unit creation: units grow as their fragments
		// arrive, so a fixed number of them can still exceed the budget between them.
		enforceByteBudget(payload.size(), key);

		const byte *payloadBegin = reinterpret_cast< const byte * >(payload.data());

		pending.fragments[fragmentIndex].assign(payloadBegin, payloadBegin + payload.size());
		pending.received[fragmentIndex] = true;
		++pending.receivedCount;
		pending.totalBytes += payload.size();
		m_bufferedBytes += payload.size();

		// Geometry only travels on fragment 0. The remaining metadata is repeated on every fragment; once
		// fragment 0 has been seen its values stick, but before that each arriving fragment overwrites
		// them, so a sender that varies these fields across fragments gets last-writer-wins rather than
		// any guarantee. That is acceptable only because a conforming sender replicates them identically.
		if (fragmentIndex == 0 || !pending.haveGeometry) {
			pending.header.isKeyframe           = m_message.is_keyframe();
			pending.header.isFrameEnd           = m_message.is_frame_end();
			pending.header.captureTimestampUsec = m_message.capture_timestamp_usec();
		}

		if (fragmentIndex == 0) {
			pending.header.x      = m_message.x();
			pending.header.y      = m_message.y();
			pending.header.width  = m_message.width();
			pending.header.height = m_message.height();
			pending.haveGeometry  = true;
		}

		if (pending.receivedCount != pending.fragmentCount) {
			return VideoReassemblyResult::Incomplete;
		}

		unit.header = pending.header;
		unit.payload.clear();
		unit.payload.reserve(pending.totalBytes);

		for (const std::vector< byte > &fragmentPayload : pending.fragments) {
			unit.payload.insert(unit.payload.end(), fragmentPayload.begin(), fragmentPayload.end());
		}

		eraseUnit(it);
		rememberCompleted(key, nowUsec);

		return VideoReassemblyResult::Complete;
	}

	void VideoReassembler::rememberCompleted(const UnitKey &key, std::uint64_t nowUsec) {
		while (!m_completedOrder.empty()
			   && (m_completedOrder.size() >= MAX_REMEMBERED_COMPLETE
				   || nowUsec > m_completedOrder.front().first + VIDEO_REASSEMBLY_TIMEOUT_USEC)) {
			m_recentlyCompleted.erase(m_completedOrder.front().second);
			m_completedOrder.pop_front();
		}

		if (m_recentlyCompleted.insert(key).second) {
			m_completedOrder.emplace_back(nowUsec, key);
		}
	}

} // namespace Protocol
} // namespace Mumble
