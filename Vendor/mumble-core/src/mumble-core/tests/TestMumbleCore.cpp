// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#include "CoreTest.h"

#include "ByteSwap.h"
#include "CoreLog.h"
#include "MumbleProtocol.h"
#include "Timer.h"
#include "VersionNumber.h"
#include "VolumeAdjustment.h"
#include "crypto/CryptStateOCB2.h"
#include "crypto/CryptographicRandom.h"
#include "crypto/Digest.h"

#include <array>
#include <bit>
#include <cstring>
#include <string>
#include <vector>

namespace {
std::string asString(const unsigned char *data, std::size_t size) {
	return std::string(reinterpret_cast< const char * >(data), size);
}
} // namespace

// The vectors from draft-krovetz-ocb-00.txt, as in TestCrypt.
CORE_TEST(ocb2MatchesTheDraftVectors) {
	const unsigned char rawkey[AES_BLOCK_SIZE] = { 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
												   0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f };
	CryptStateOCB2 cs;
	const std::string key = asString(rawkey, AES_BLOCK_SIZE);
	CHECK(cs.setKey(key, key, key));

	unsigned char tag[AES_BLOCK_SIZE];
	CHECK(cs.ocb_encrypt(nullptr, nullptr, 0, rawkey, tag));
	const unsigned char blanktag[AES_BLOCK_SIZE] = { 0xBF, 0x31, 0x08, 0x13, 0x07, 0x73, 0xAD, 0x5E,
													 0xC7, 0x0E, 0xC6, 0x9E, 0x78, 0x75, 0xA7, 0xB0 };
	CHECK(std::memcmp(tag, blanktag, AES_BLOCK_SIZE) == 0);

	unsigned char source[40];
	unsigned char crypt[40];
	for (unsigned char i = 0; i < 40; i++) {
		source[i] = i;
	}
	CHECK(cs.ocb_encrypt(source, crypt, 40, rawkey, tag));
	const unsigned char longtag[AES_BLOCK_SIZE] = { 0x9D, 0xB0, 0xCD, 0xF8, 0x80, 0xF7, 0x3E, 0x3E,
													0x10, 0xD4, 0xEB, 0x32, 0x17, 0x76, 0x66, 0x88 };
	const unsigned char crypted[40]             = { 0xF7, 0x5D, 0x6B, 0xC8, 0xB4, 0xDC, 0x8D, 0x66, 0xB8, 0x36,
													0xA2, 0xB0, 0x8B, 0x32, 0xA6, 0x36, 0x9F, 0x1C, 0xD3, 0xC5,
													0x22, 0x8D, 0x79, 0xFD, 0x6C, 0x26, 0x7F, 0x5F, 0x6A, 0xA7,
													0xB2, 0x31, 0xC7, 0xDF, 0xB9, 0xD5, 0x99, 0x51, 0xAE, 0x9C };
	CHECK(std::memcmp(tag, longtag, AES_BLOCK_SIZE) == 0);
	CHECK(std::memcmp(crypt, crypted, sizeof(crypted)) == 0);
}

CORE_TEST(audioPacketsRoundTrip) {
	CryptStateOCB2 sender;
	sender.genKey();
	CryptStateOCB2 receiver;
	CHECK(receiver.setKey(sender.getRawKey(), sender.getDecryptIV(), sender.getEncryptIV()));

	const unsigned char secret[] = "the quick brown fox";
	for (int i = 0; i < 300; i++) {
		unsigned char encrypted[sizeof(secret) + 4];
		unsigned char decrypted[sizeof(secret)];
		CHECK(sender.encrypt(secret, encrypted, sizeof(secret)));
		CHECK(receiver.decrypt(encrypted, decrypted, sizeof(encrypted)));
		CHECK(std::memcmp(secret, decrypted, sizeof(secret)) == 0);
	}
	CHECK_EQ(receiver.m_statsLocal.good, 300u);
	CHECK_EQ(receiver.m_statsLocal.lost, 0u);
}

CORE_TEST(tamperedAudioPacketIsRejected) {
	CryptStateOCB2 sender;
	sender.genKey();
	CryptStateOCB2 receiver;
	CHECK(receiver.setKey(sender.getRawKey(), sender.getDecryptIV(), sender.getEncryptIV()));

	const unsigned char secret[] = "abcdefghi";
	unsigned char encrypted[sizeof(secret) + 4];
	unsigned char decrypted[sizeof(secret)];
	CHECK(sender.encrypt(secret, encrypted, sizeof(secret)));
	encrypted[6] ^= 0x01;
	CHECK(!receiver.decrypt(encrypted, decrypted, sizeof(encrypted)));
}

CORE_TEST(randomFillsTheBuffer) {
	std::array< unsigned char, 64 > a{};
	std::array< unsigned char, 64 > b{};
	CryptographicRandom::fillBuffer(a.data(), static_cast< int >(a.size()));
	CryptographicRandom::fillBuffer(b.data(), static_cast< int >(b.size()));
	CHECK(a != b);
	for (int i = 0; i < 1000; i++) {
		CHECK(CryptographicRandom::uniform(10) < 10);
	}
}

CORE_TEST(byteSwapMatchesTheBuiltin) {
	constexpr std::uint64_t value = 0x0102030405060708ull;
	static_assert(Mumble::byteSwap64(value) == 0x0807060504030201ull);
	const std::uint64_t swapped = SWAP64(value);
	if constexpr (std::endian::native == std::endian::little) {
		CHECK_EQ(swapped, 0x0807060504030201ull);
	} else {
		CHECK_EQ(swapped, value);
	}
}

CORE_TEST(versionComponents) {
	CHECK_EQ(Version::fromComponents(1, 3, 5), static_cast< Version::full_t >(0x0001000300050000));
	CHECK_EQ(Version::toLegacyVersion(Version::fromComponents(1, 3, 5)), static_cast< std::uint32_t >(0x010305));
	CHECK_EQ(Version::fromLegacyVersion(0x010305), Version::fromComponents(1, 3, 5));
	CHECK_EQ(Version::getMajor(Version::get()), static_cast< Version::component_t >(MUMBLE_VERSION_MAJOR));
}

CORE_TEST(volumeAdjustmentConversions) {
	CHECK_EQ(VolumeAdjustment::toIntegerDBAdjustment(1.0f), 0);
	CHECK_EQ(VolumeAdjustment::fromDBAdjustment(6).dbAdjustment, 6);
	CHECK(VolumeAdjustment::toFactor(0) == 1.0f);
}

CORE_TEST(timerAdvances) {
	Timer timer;
	CHECK(timer.isStarted());
	const auto first = timer.elapsed();
	while (timer.elapsed() == first) {
	}
	CHECK(timer.elapsed() > first);
}

namespace {
Mumble::Core::LogLevel g_lastLevel;
std::string g_lastMessage;
void captureLog(Mumble::Core::LogLevel level, const char *message) {
	g_lastLevel   = level;
	g_lastMessage = message;
}
} // namespace

CORE_TEST(logHandlerReceivesFormattedMessages) {
	Mumble::Core::setLogHandler(captureLog);
	Mumble::Core::logWarning("%s %d", "answer", 42);
	Mumble::Core::setLogHandler(nullptr);
	CHECK(g_lastLevel == Mumble::Core::LogLevel::Warning);
	CHECK_EQ(g_lastMessage, std::string("answer 42"));
}

CORE_TEST(audioRoundTripsFromClientToServer) {
	using namespace Mumble::Protocol;

	const std::vector< byte > opus = { 0x01, 0x02, 0x03, 0x04, 0x05 };

	AudioData sent;
	sent.targetOrContext        = 3;
	sent.frameNumber            = 1234;
	sent.payload                = opus;
	sent.isLastFrame            = true;
	sent.containsPositionalData = true;
	sent.position               = { 1.0f, 2.0f, 3.0f };

	UDPAudioEncoder< Role::Client > encoder(Version::fromComponents(1, 5, 0));
	const std::span< const byte > packet = encoder.encodeAudioPacket(sent);
	CHECK(!packet.empty());
	CHECK_EQ(packet[0], static_cast< byte >(UDPMessageType::Audio));

	UDPDecoder< Role::Server > decoder(Version::fromComponents(1, 5, 0));
	CHECK(decoder.decode(packet));
	CHECK(decoder.getMessageType() == UDPMessageType::Audio);
	const AudioData received = decoder.getAudioData();
	CHECK_EQ(received.targetOrContext, 3u);
	CHECK_EQ(received.frameNumber, 1234u);
	CHECK(received.isLastFrame);
	CHECK(received.containsPositionalData);
	CHECK(received.position == sent.position);
	CHECK(std::vector< byte >(received.payload.begin(), received.payload.end()) == opus);
}

CORE_TEST(pingRoundTripsFromServerToClient) {
	using namespace Mumble::Protocol;

	PingData sent;
	sent.timestamp                     = 0x1122334455667788ull;
	sent.containsAdditionalInformation = true;
	sent.serverVersion                 = Version::fromComponents(1, 9, 1);
	sent.userCount                     = 7;
	sent.maxUserCount                  = 100;
	sent.maxBandwidthPerUser           = 558000;

	UDPPingEncoder< Role::Server > encoder(Version::fromComponents(1, 5, 0));
	const std::span< const byte > packet = encoder.encodePingPacket(sent);
	CHECK(!packet.empty());

	UDPDecoder< Role::Client > decoder(Version::fromComponents(1, 5, 0));
	CHECK(decoder.decode(packet));
	CHECK(decoder.getMessageType() == UDPMessageType::Ping);
	CHECK(decoder.getPingData() == sent);
}

#ifdef MUMBLE_CORE_LEGACY_UDP
// The legacy extended ping is a fixed big-endian layout, which is what the core's own byte swapping now
// produces in place of qToBigEndian.
CORE_TEST(legacyExtendedPingLayout) {
	using namespace Mumble::Protocol;

	PingData sent;
	sent.timestamp                     = 42;
	sent.containsAdditionalInformation = true;
	sent.serverVersion                 = Version::fromComponents(1, 4, 287);
	sent.userCount                     = 0x01020304;
	sent.maxUserCount                  = 0x0A0B0C0D;
	sent.maxBandwidthPerUser           = 72000;

	UDPPingEncoder< Role::Server > encoder(Version::fromComponents(1, 4, 0));
	const std::span< const byte > packet = encoder.encodePingPacket(sent);
	CHECK_EQ(packet.size(), 24u);
	const std::vector< byte > version(packet.begin(), packet.begin() + 4);
	CHECK(version == (std::vector< byte >{ 0x00, 0x01, 0x04, 0xFF }));
	const std::vector< byte > users(packet.begin() + 12, packet.begin() + 16);
	CHECK(users == (std::vector< byte >{ 0x01, 0x02, 0x03, 0x04 }));

	UDPDecoder< Role::Client > decoder(Version::fromComponents(1, 4, 0));
	CHECK(decoder.decode(packet));
	const PingData received = decoder.getPingData();
	CHECK_EQ(received.userCount, sent.userCount);
	CHECK_EQ(received.maxUserCount, sent.maxUserCount);
	CHECK_EQ(received.maxBandwidthPerUser, sent.maxBandwidthPerUser);
	CHECK_EQ(received.timestamp, sent.timestamp);
}
#else
CORE_TEST(legacyUdpIsRefusedWhenLeftOut) {
	using namespace Mumble::Protocol;

	PingData ping;
	ping.timestamp = 42;
	UDPPingEncoder< Role::Client > encoder(Version::fromComponents(1, 4, 0));
	CHECK(encoder.encodePingPacket(ping).empty());

	const std::vector< byte > legacyPing = { 0x20, 0x2A };
	UDPDecoder< Role::Server > decoder(Version::fromComponents(1, 4, 0));
	CHECK(!decoder.decode(legacyPing));
}
#endif

CORE_TEST(digestKnownAnswers) {
	using Mumble::Crypto::Digest;
	using Mumble::Crypto::DigestAlgorithm;

	const std::vector< std::uint8_t > abc    = { 'a', 'b', 'c' };
	const std::vector< std::uint8_t > sha1   = { 0xa9, 0x99, 0x3e, 0x36, 0x47, 0x06, 0x81, 0x6a, 0xba, 0x3e,
												 0x25, 0x71, 0x78, 0x50, 0xc2, 0x6c, 0x9c, 0xd0, 0xd8, 0x9d };
	const std::vector< std::uint8_t > sha256 = { 0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40,
												 0xde, 0x5d, 0xae, 0x22, 0x23, 0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17,
												 0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad };
	CHECK(Digest::hash(abc, DigestAlgorithm::Sha1) == sha1);
	CHECK(Digest::hash(abc, DigestAlgorithm::Sha256) == sha256);

	Digest incremental(DigestAlgorithm::Sha256);
	incremental.addData(std::span< const std::uint8_t >(abc).first(1));
	incremental.addData(std::span< const std::uint8_t >(abc).subspan(1));
	CHECK(incremental.result() == sha256);
	CHECK(incremental.result() == sha256);
	// Adding after the result is an error, and stays one.
	incremental.addData(abc);
	CHECK(incremental.result().empty());
}

int main() {
	return CoreTest::runAll();
}
