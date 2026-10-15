// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#include "VideoTransport.h"

#include "crypto/Digest.h"

#include <cstring>

namespace Mumble {
namespace Protocol {

	namespace {

		void writeBigEndian32(byte *dst, std::uint32_t value) {
			dst[0] = static_cast< byte >((value >> 24) & 0xFF);
			dst[1] = static_cast< byte >((value >> 16) & 0xFF);
			dst[2] = static_cast< byte >((value >> 8) & 0xFF);
			dst[3] = static_cast< byte >(value & 0xFF);
		}

		std::uint32_t readBigEndian32(const byte *src) {
			return (static_cast< std::uint32_t >(src[0]) << 24) | (static_cast< std::uint32_t >(src[1]) << 16)
				   | (static_cast< std::uint32_t >(src[2]) << 8) | static_cast< std::uint32_t >(src[3]);
		}

	} // namespace

	bool VideoCryptState::setKey(const std::string &key, const std::string &encryptNonceBase,
								 const std::string &decryptNonceBase) {
		m_valid = false;

		if (key.size() != AES_KEY_SIZE_BYTES || encryptNonceBase.size() != sizeof(m_encryptNonceBase)
			|| decryptNonceBase.size() != sizeof(m_decryptNonceBase)) {
			return false;
		}

		// Identical bases under one key would make the two directions produce identical nonces for the
		// same sequence number. For OCB, nonce reuse under the same key is a complete break, not a
		// degradation, so this is refused rather than merely discouraged.
		if (encryptNonceBase == decryptNonceBase) {
			return false;
		}

		if (!m_ocb.setRawKey(key)) {
			return false;
		}

		std::memcpy(m_encryptNonceBase, encryptNonceBase.data(), sizeof(m_encryptNonceBase));
		std::memcpy(m_decryptNonceBase, decryptNonceBase.data(), sizeof(m_decryptNonceBase));

		m_nextSequence    = VIDEO_FIRST_SEQUENCE;
		m_highestReceived = 0;
		m_window.reset();

		m_replays      = 0;
		m_tooOld       = 0;
		m_authFailures = 0;

		m_valid = true;

		return true;
	}

	bool VideoCryptState::deriveFromSessionKey(const std::string &sessionKey, bool isServer) {
		if (sessionKey.size() != AES_KEY_SIZE_BYTES) {
			return false;
		}

		const auto derive = [&sessionKey](const char *label, std::size_t bytes) {
			std::vector< std::uint8_t > input(sessionKey.begin(), sessionKey.end());
			input.insert(input.end(), label, label + std::strlen(label));

			const std::vector< std::uint8_t > digest = Crypto::Digest::hash(input, Crypto::DigestAlgorithm::Sha256);

			return std::string(reinterpret_cast< const char * >(digest.data()), bytes);
		};

		// Three independent labels: one for the key, one for each direction's nonce base. The server
		// takes "s2c" as its outgoing base and the client takes "c2s", so the two ends agree without
		// exchanging anything and never share a base.
		const std::string videoKey       = derive("mumble-video-key", AES_KEY_SIZE_BYTES);
		const std::string serverToClient = derive("mumble-video-nonce-s2c", sizeof(m_encryptNonceBase));
		const std::string clientToServer = derive("mumble-video-nonce-c2s", sizeof(m_encryptNonceBase));

		if (isServer) {
			return setKey(videoKey, serverToClient, clientToServer);
		}

		return setKey(videoKey, clientToServer, serverToClient);
	}

	bool VideoCryptState::encrypt(std::span< const byte > plaintext, std::vector< byte > &datagram) {
		if (!m_valid || plaintext.empty() || plaintext.size() > MAX_VIDEO_PLAINTEXT_SIZE) {
			return false;
		}

		// The sequence is the nonce. Wrapping it would repeat a nonce under the same key, so the state
		// stops rather than wrapping and the connection must rekey. At a sustained 30k packets per
		// second this is roughly forty hours of continuous streaming.
		if (m_nextSequence == 0xFFFFFFFFu) {
			return false;
		}

		const std::uint32_t sequence = m_nextSequence;

		unsigned char nonce[AES_BLOCK_SIZE];
		std::memcpy(nonce, m_encryptNonceBase, sizeof(m_encryptNonceBase));
		writeBigEndian32(reinterpret_cast< byte * >(nonce) + sizeof(m_encryptNonceBase), sequence);

		datagram.resize(VIDEO_HEADER_SIZE + plaintext.size());

		datagram[0] = MEDIA_CHANNEL_VIDEO;
		writeBigEndian32(datagram.data() + VIDEO_SEQUENCE_OFFSET, sequence);

		unsigned char tag[AES_BLOCK_SIZE];

		if (!m_ocb.ocb_encrypt(plaintext.data(), datagram.data() + VIDEO_HEADER_SIZE,
							   static_cast< unsigned int >(plaintext.size()), nonce, tag)) {
			datagram.clear();

			return false;
		}

		std::memcpy(datagram.data() + VIDEO_TAG_OFFSET, tag, VIDEO_TAG_SIZE);

		m_nextSequence++;

		return true;
	}

	VideoCryptState::Result VideoCryptState::checkSequence(std::uint32_t sequence) const {
		if (sequence == 0) {
			return Result::Malformed;
		}

		if (m_highestReceived == 0) {
			// Nothing accepted yet, so anything is new.
			return Result::Ok;
		}

		if (sequence > m_highestReceived) {
			return Result::Ok;
		}

		const std::uint32_t behind = m_highestReceived - sequence;

		if (behind >= VIDEO_REPLAY_WINDOW) {
			return Result::TooOld;
		}

		if (m_window.test(behind)) {
			return Result::Replay;
		}

		return Result::Ok;
	}

	void VideoCryptState::commitSequence(std::uint32_t sequence) {
		if (sequence > m_highestReceived) {
			const std::uint32_t advance = sequence - m_highestReceived;

			if (m_highestReceived == 0 || advance >= VIDEO_REPLAY_WINDOW) {
				// A jump larger than the window leaves nothing worth keeping.
				m_window.reset();
			} else {
				m_window <<= advance;
			}

			m_highestReceived = sequence;
			m_window.set(0);

			return;
		}

		const std::uint32_t behind = m_highestReceived - sequence;

		if (behind < VIDEO_REPLAY_WINDOW) {
			m_window.set(behind);
		}
	}

	VideoCryptState::Result VideoCryptState::decrypt(std::span< const byte > datagram, std::vector< byte > &plaintext) {
		if (!m_valid) {
			return Result::Malformed;
		}

		if (datagram.size() <= VIDEO_HEADER_SIZE || datagram.size() > MAX_VIDEO_DATAGRAM_SIZE) {
			return Result::Malformed;
		}

		if (datagram[0] != MEDIA_CHANNEL_VIDEO) {
			return Result::WrongChannel;
		}

		const std::uint32_t sequence = readBigEndian32(datagram.data() + VIDEO_SEQUENCE_OFFSET);

		// Checked before doing the work of decrypting, so a flood of replayed packets is cheap to
		// refuse, but committed only afterwards so a forgery cannot mark a sequence as seen.
		const Result sequenceCheck = checkSequence(sequence);

		if (sequenceCheck != Result::Ok) {
			if (sequenceCheck == Result::Replay) {
				m_replays++;
			} else if (sequenceCheck == Result::TooOld) {
				m_tooOld++;
			}

			return sequenceCheck;
		}

		unsigned char nonce[AES_BLOCK_SIZE];
		std::memcpy(nonce, m_decryptNonceBase, sizeof(m_decryptNonceBase));
		writeBigEndian32(reinterpret_cast< byte * >(nonce) + sizeof(m_decryptNonceBase), sequence);

		const std::size_t payloadSize = datagram.size() - VIDEO_HEADER_SIZE;

		plaintext.resize(payloadSize);

		unsigned char tag[AES_BLOCK_SIZE];

		if (!m_ocb.ocb_decrypt(datagram.data() + VIDEO_HEADER_SIZE, plaintext.data(),
							   static_cast< unsigned int >(payloadSize), nonce, tag)) {
			plaintext.clear();
			m_authFailures++;

			return Result::AuthenticationFailed;
		}

		if (std::memcmp(tag, datagram.data() + VIDEO_TAG_OFFSET, VIDEO_TAG_SIZE) != 0) {
			plaintext.clear();
			m_authFailures++;

			return Result::AuthenticationFailed;
		}

		commitSequence(sequence);

		return Result::Ok;
	}

} // namespace Protocol
} // namespace Mumble
