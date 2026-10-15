// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#ifndef MUMBLE_CRYPTOSESSION_H_
#define MUMBLE_CRYPTOSESSION_H_

#include "Mumble.pb.h"
#include "VideoTransport.h"
#include "crypto/CryptStateOCB2.h"

namespace Mumble {
namespace Protocol {

	/**
	 * The client's two UDP crypt states, audio and video, keyed together from the server's CryptSetup.
	 *
	 * The desktop client keeps these on its Connection and applies CryptSetup in MainWindow::msgCryptSetup;
	 * this is the same logic for a host without either.
	 */
	class CryptoSession {
	public:
		enum class SetupResult {
			/// A full key: both channels are (re)keyed.
			Keyed,
			/// The server sent a fresh decrypt nonce after losing sync.
			Resynced,
			/// The server asked for our encrypt nonce: send `reply` back.
			Reply,
			/// Malformed, and ignored. A full key the audio state refuses has still rekeyed video, as on the
			/// desktop.
			Invalid,
		};

		SetupResult applyCryptSetup(const MumbleProto::CryptSetup &message, MumbleProto::CryptSetup &reply);

		bool isValid() const { return m_audio.isValid(); }

		CryptStateOCB2 &audio() { return m_audio; }
		const CryptStateOCB2 &audio() const { return m_audio; }
		VideoCryptState &video() { return m_video; }
		const VideoCryptState &video() const { return m_video; }

	private:
		CryptStateOCB2 m_audio;
		VideoCryptState m_video;
	};

} // namespace Protocol
} // namespace Mumble

#endif // MUMBLE_CRYPTOSESSION_H_
