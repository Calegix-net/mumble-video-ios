// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

// Checks the media crypto against the vectors in ../test-vectors, which an independent implementation
// (generate.py there) produced. Any change to the bytes on the wire fails here.

#include "CoreTest.h"

#include "Mumble.pb.h"
#include "VideoTransport.h"
#include "crypto/CryptStateOCB2.h"
#include "mumble-core/MumbleCore.h"

#include <nlohmann/json.hpp>

#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

namespace {

using Bytes = std::vector< std::uint8_t >;

nlohmann::json loadVectors(const char *name) {
	// MUMBLE_CORE_TEST_VECTORS overrides the build-time path, for running the test somewhere else (a phone).
	const char *dir = std::getenv("MUMBLE_CORE_TEST_VECTORS");
	std::ifstream file(std::string(dir ? dir : MUMBLE_CORE_TEST_VECTORS_DIR) + "/" + name);
	if (!file) {
		return nlohmann::json();
	}
	return nlohmann::json::parse(file)["cases"];
}

Bytes fromHex(const std::string &hex) {
	Bytes bytes;
	for (std::size_t i = 0; i + 1 < hex.size(); i += 2) {
		bytes.push_back(static_cast< std::uint8_t >(std::stoul(hex.substr(i, 2), nullptr, 16)));
	}
	return bytes;
}

Bytes hexField(const nlohmann::json &object, const char *field) {
	return fromHex(object[field].get< std::string >());
}

std::string asString(const Bytes &bytes) {
	return std::string(bytes.begin(), bytes.end());
}

class SequencedVideoCryptState : public Mumble::Protocol::VideoCryptState {
public:
	void setNextSequence(std::uint32_t sequence) { m_nextSequence = sequence; }
};

} // namespace

CORE_TEST(ocb2KnownAnswers) {
	const nlohmann::json cases = loadVectors("ocb2-aes128.json");
	CHECK(cases.size() >= 10);

	for (const nlohmann::json &c : cases) {
		const Bytes key   = hexField(c, "key");
		const Bytes nonce = hexField(c, "nonce");
		const Bytes plain = hexField(c, "plaintext");

		CryptStateOCB2 cs;
		CHECK(cs.setRawKey(asString(key)));

		Bytes encrypted(plain.size());
		std::uint8_t tag[AES_BLOCK_SIZE];
		CHECK(cs.ocb_encrypt(plain.data(), encrypted.data(), static_cast< unsigned int >(plain.size()), nonce.data(),
							 tag));
		CHECK(encrypted == hexField(c, "ciphertext"));
		CHECK(Bytes(tag, tag + AES_BLOCK_SIZE) == hexField(c, "tag"));
	}
}

CORE_TEST(audioDatagramKnownAnswers) {
	const nlohmann::json cases = loadVectors("audio-datagram.json");
	CHECK(!cases.empty());

	for (const nlohmann::json &c : cases) {
		const Bytes key = hexField(c, "key");
		const Bytes iv  = hexField(c, "encryptIv");

		CryptStateOCB2 sender;
		CHECK(sender.setKey(asString(key), asString(iv), asString(Bytes(AES_BLOCK_SIZE))));
		CryptStateOCB2 receiver;
		CHECK(receiver.setKey(asString(key), asString(Bytes(AES_BLOCK_SIZE)), asString(iv)));

		CHECK_EQ(c["plaintexts"].size(), c["datagrams"].size());
		for (std::size_t i = 0; i < c["plaintexts"].size(); i++) {
			const Bytes plain    = fromHex(c["plaintexts"][i].get< std::string >());
			const Bytes expected = fromHex(c["datagrams"][i].get< std::string >());

			Bytes datagram(plain.size() + 5);
			datagram[0] = Mumble::Protocol::MEDIA_CHANNEL_AUDIO;
			CHECK(sender.encrypt(plain.data(), datagram.data() + 1, static_cast< unsigned int >(plain.size())));
			CHECK(datagram == expected);

			Bytes decrypted(plain.size());
			CHECK(receiver.decrypt(expected.data() + 1, decrypted.data(),
								   static_cast< unsigned int >(expected.size() - 1)));
			CHECK(decrypted == plain);
		}
	}
}

CORE_TEST(videoKeyDerivationKnownAnswers) {
	const nlohmann::json cases = loadVectors("video-key-derivation.json");
	CHECK(!cases.empty());

	for (const nlohmann::json &c : cases) {
		const std::string sessionKey = asString(hexField(c, "sessionKey"));

		// The derived state is opaque, so it is checked by what it encrypts: a client keyed from the session
		// key must produce exactly what one keyed by hand with the expected values does, and so must a server.
		for (const bool isServer : { false, true }) {
			Mumble::Protocol::VideoCryptState derived;
			CHECK(derived.deriveFromSessionKey(sessionKey, isServer));

			const Bytes ours   = hexField(c, isServer ? "nonceBaseServerToClient" : "nonceBaseClientToServer");
			const Bytes theirs = hexField(c, isServer ? "nonceBaseClientToServer" : "nonceBaseServerToClient");
			Mumble::Protocol::VideoCryptState manual;
			CHECK(manual.setKey(asString(hexField(c, "videoKey")), asString(ours), asString(theirs)));

			const Bytes plain = { 0x02, 0x10, 0x20, 0x30 };
			Bytes fromDerived;
			Bytes fromManual;
			CHECK(derived.encrypt(plain, fromDerived));
			CHECK(manual.encrypt(plain, fromManual));
			CHECK(fromDerived == fromManual);
		}
	}
}

CORE_TEST(videoDatagramKnownAnswers) {
	const nlohmann::json cases = loadVectors("video-datagram.json");
	CHECK(!cases.empty());

	for (const nlohmann::json &c : cases) {
		const bool clientToServer    = c["direction"].get< std::string >() == "clientToServer";
		const std::string sessionKey = asString(hexField(c, "sessionKey"));
		const Bytes plain            = hexField(c, "plaintext");
		const Bytes expected         = hexField(c, "datagram");

		SequencedVideoCryptState sender;
		CHECK(sender.deriveFromSessionKey(sessionKey, !clientToServer));
		sender.setNextSequence(c["sequence"].get< std::uint32_t >());

		Bytes datagram;
		CHECK(sender.encrypt(plain, datagram));
		CHECK(datagram == expected);

		Mumble::Protocol::VideoCryptState receiver;
		CHECK(receiver.deriveFromSessionKey(sessionKey, clientToServer));
		Bytes decrypted;
		CHECK(receiver.decrypt(expected, decrypted) == Mumble::Protocol::VideoCryptState::Result::Ok);
		CHECK(decrypted == plain);
	}
}

CORE_TEST(videoUnitKnownAnswers) {
	const nlohmann::json vectors = loadVectors("video-unit.json");
	CHECK(vectors.contains("units"));

	MumbleProto::CryptSetup setup;
	setup.set_key(asString(hexField(vectors, "sessionKey")));
	setup.set_client_nonce(std::string(AES_BLOCK_SIZE, '\x01'));
	setup.set_server_nonce(std::string(AES_BLOCK_SIZE, '\x02'));
	const std::string setupBytes = setup.SerializeAsString();

	MumbleCore::MediaSession session;
	MumbleCore::MediaEvents events;
	CHECK(session.handleCryptSetup(
		std::span< const std::uint8_t >(reinterpret_cast< const std::uint8_t * >(setupBytes.data()), setupBytes.size()),
		events));

	for (const nlohmann::json &c : vectors["units"]) {
		MumbleCore::VideoUnit unit;
		unit.streamID             = c["streamID"].get< std::uint32_t >();
		unit.frameNumber          = c["frameNumber"].get< std::uint64_t >();
		unit.unitID               = c["unitID"].get< std::uint32_t >();
		unit.isKeyframe           = c["isKeyframe"].get< bool >();
		unit.isFrameEnd           = c["isFrameEnd"].get< bool >();
		unit.captureTimestampUsec = c["captureTimestampUsec"].get< std::uint64_t >();
		unit.x                    = c["x"].get< std::uint32_t >();
		unit.y                    = c["y"].get< std::uint32_t >();
		unit.width                = c["width"].get< std::uint32_t >();
		unit.height               = c["height"].get< std::uint32_t >();
		unit.payload              = hexField(c, "payload");

		const std::vector< MumbleCore::Bytes > datagrams = session.makeVideo(unit);
		CHECK_EQ(datagrams.size(), c["datagrams"].size());
		for (std::size_t i = 0; i < datagrams.size(); i++) {
			CHECK(datagrams[i] == fromHex(c["datagrams"][i].get< std::string >()));
		}
	}

	// No video at all on a plainly framed connection.
	session.setUdpFraming(MumbleCore::UdpFraming::Plain);
	MumbleCore::VideoUnit unit;
	unit.payload = { 1, 2, 3 };
	CHECK(session.makeVideo(unit).empty());
}
