// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#include "CryptoSession.h"

#include "CoreLog.h"

namespace Mumble {
namespace Protocol {

	CryptoSession::SetupResult CryptoSession::applyCryptSetup(const MumbleProto::CryptSetup &message,
															  MumbleProto::CryptSetup &reply) {
		if (message.has_key() && message.has_client_nonce() && message.has_server_nonce()) {
			// The client takes the opposite role, so the two ends pick opposite nonce bases from the same
			// derivation.
			m_video.deriveFromSessionKey(message.key(), false);

			if (!m_audio.setKey(message.key(), message.client_nonce(), message.server_nonce())) {
				Core::logWarning("CryptoSession: Cipher resync failed: Invalid key/nonce from the server!");
				return SetupResult::Invalid;
			}

			return SetupResult::Keyed;
		}

		if (message.has_server_nonce()) {
			if (message.server_nonce().size() != AES_BLOCK_SIZE) {
				return SetupResult::Invalid;
			}

			m_audio.m_statsLocal.resync++;
			if (!m_audio.setDecryptIV(message.server_nonce())) {
				Core::logWarning("CryptoSession: Cipher resync failed: Invalid nonce from the server!");
				return SetupResult::Invalid;
			}

			return SetupResult::Resynced;
		}

		reply.Clear();
		reply.set_client_nonce(m_audio.getEncryptIV());

		return SetupResult::Reply;
	}

} // namespace Protocol
} // namespace Mumble
