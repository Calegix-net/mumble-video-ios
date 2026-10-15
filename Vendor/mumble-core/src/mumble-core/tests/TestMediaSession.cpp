// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#include "CoreTest.h"

#include "ControlFramer.h"
#include "CoreLog.h"
#include "MediaDemux.h"
#include "Mumble.pb.h"
#include "MumbleProtocol.h"
#include "MumbleUDP.pb.h"
#include "VideoFragmentation.h"
#include "VideoReceiver.h"
#include "VideoTransport.h"
#include "crypto/CryptStateOCB2.h"
#include "mumble-core/MumbleCore.h"

#include <cstdint>
#include <string>
#include <vector>

using namespace Mumble::Protocol;

namespace {

using Bytes = std::vector< std::uint8_t >;

const std::string SESSION_KEY = "0123456789abcdef";

// A unit as the server relays it: fragmented by the sender, stamped with its session, encrypted for us.
std::vector< Bytes > relayedUnit(VideoCryptState &serverCrypt, std::uint32_t sender, std::uint32_t stream,
								 std::uint64_t frame, std::size_t payloadSize) {
	VideoUnitHeader header;
	header.senderSession = sender;
	header.streamID      = stream;
	header.frameNumber   = frame;
	header.isKeyframe    = true;
	header.isFrameEnd    = true;
	header.width         = 64;
	header.height        = 32;

	Bytes payload(payloadSize);
	for (std::size_t i = 0; i < payload.size(); i++) {
		payload[i] = static_cast< std::uint8_t >(i * 7);
	}

	VideoFragmenter fragmenter;
	if (!fragmenter.fragment(header, payload)) {
		return {};
	}

	std::vector< Bytes > datagrams;
	for (const std::vector< byte > &packet : fragmenter.packets()) {
		Bytes datagram;
		serverCrypt.encrypt(packet, datagram);
		datagrams.push_back(std::move(datagram));
	}
	return datagrams;
}

} // namespace

CORE_TEST(demuxSplitsByChannelByte) {
	const MediaDemux demux;
	const Bytes audio = { MEDIA_CHANNEL_AUDIO, 1, 2, 3, 4 };
	const Bytes video = { MEDIA_CHANNEL_VIDEO, 1, 2, 3, 4, 5 };
	const Bytes other = { 0x7F, 1, 2, 3, 4 };
	const Bytes runt  = { MEDIA_CHANNEL_AUDIO, 1, 2, 3 };

	const MediaDatagram a = demux.classify(audio);
	CHECK(a.channel == MediaChannel::Audio);
	CHECK_EQ(a.payload.size(), 4u);
	CHECK(a.payload.data() == audio.data() + 1);

	const MediaDatagram v = demux.classify(video);
	CHECK(v.channel == MediaChannel::Video);
	CHECK_EQ(v.datagram.size(), video.size());

	CHECK(demux.classify(other).channel == MediaChannel::Unknown);
	CHECK(demux.classify(runt).channel == MediaChannel::Unknown);
}

CORE_TEST(demuxPlainFramingIsAllAudio) {
	const MediaDemux demux(MediaDemux::Framing::Plain);
	const Bytes datagram = { MEDIA_CHANNEL_VIDEO, 1, 2, 3, 4 };

	const MediaDatagram d = demux.classify(datagram);
	CHECK(d.channel == MediaChannel::Audio);
	CHECK_EQ(d.payload.size(), datagram.size());
}

CORE_TEST(controlHeaderLayout) {
	const Bytes payload = { 0xAA, 0xBB, 0xCC };
	const Bytes framed  = ControlFramer::frame(static_cast< std::uint16_t >(TCPMessageType::CryptSetup), payload);
	CHECK(framed == (Bytes{ 0x00, 0x0F, 0x00, 0x00, 0x00, 0x03, 0xAA, 0xBB, 0xCC }));

	const ControlHeader header = readControlHeader(framed.data());
	CHECK_EQ(header.type, 15);
	CHECK_EQ(header.length, 3u);
}

CORE_TEST(controlFramerReassemblesAnySplit) {
	Bytes stream;
	for (std::uint16_t type = 0; type < 5; type++) {
		const Bytes payload(type * 100u, static_cast< std::uint8_t >(type));
		const Bytes framed = ControlFramer::frame(type, payload);
		stream.insert(stream.end(), framed.begin(), framed.end());
	}

	for (const std::size_t chunk : { std::size_t{ 1 }, std::size_t{ 5 }, std::size_t{ 7 }, stream.size() }) {
		ControlFramer framer;
		for (std::size_t i = 0; i < stream.size(); i += chunk) {
			CHECK(framer.feed(std::span< const std::uint8_t >(stream).subspan(i, std::min(chunk, stream.size() - i))));
		}
		for (std::uint16_t type = 0; type < 5; type++) {
			const std::optional< ControlMessage > message = framer.next();
			CHECK(message.has_value());
			CHECK_EQ(message->type, type);
			CHECK(message->payload == Bytes(type * 100u, static_cast< std::uint8_t >(type)));
		}
		CHECK(!framer.next().has_value());
	}
}

CORE_TEST(controlFramerRefusesOversizedMessages) {
	ControlFramer framer;
	Bytes header(CONTROL_HEADER_SIZE);
	writeControlHeader(header.data(), 1, MAX_CONTROL_PAYLOAD_SIZE + 1);
	CHECK(!framer.feed(header));
	CHECK(framer.failed());
	CHECK(!framer.feed(ControlFramer::frame(1, Bytes{ 1 })));
	CHECK(!framer.next().has_value());
}

CORE_TEST(videoReceiverReassemblesRelayedUnits) {
	VideoCryptState server;
	VideoCryptState client;
	CHECK(server.deriveFromSessionKey(SESSION_KEY, true));
	CHECK(client.deriveFromSessionKey(SESSION_KEY, false));

	VideoReceiver receiver;
	VideoReceiveEvents events;
	std::uint64_t now = 1000;
	for (const Bytes &datagram : relayedUnit(server, 7, 2, 40, 5000)) {
		receiver.receive(client, datagram, now++, events);
	}

	CHECK_EQ(events.units.size(), 1u);
	CHECK_EQ(events.units[0].header.senderSession, 7u);
	CHECK_EQ(events.units[0].header.streamID, 2u);
	CHECK_EQ(events.units[0].header.frameNumber, 40u);
	CHECK_EQ(events.units[0].payload.size(), 5000u);
	CHECK(events.packetsToSend.empty());
}

CORE_TEST(videoReceiverDropsUnstampedAndForeignPackets) {
	VideoCryptState server;
	VideoCryptState client;
	CHECK(server.deriveFromSessionKey(SESSION_KEY, true));
	CHECK(client.deriveFromSessionKey(SESSION_KEY, false));

	VideoReceiver receiver;
	VideoReceiveEvents events;
	for (const Bytes &datagram : relayedUnit(server, 0, 1, 1, 100)) {
		receiver.receive(client, datagram, 1000, events);
	}
	CHECK(events.units.empty());

	// Encrypted for the server, not for us.
	VideoCryptState otherDirection;
	CHECK(otherDirection.deriveFromSessionKey(SESSION_KEY, false));
	for (const Bytes &datagram : relayedUnit(otherDirection, 7, 1, 1, 100)) {
		receiver.receive(client, datagram, 1000, events);
	}
	CHECK(events.units.empty());
	CHECK_EQ(receiver.reassembler().pendingUnitCount(), 0u);
}

CORE_TEST(videoReceiverPassesOnRetransmissionRequests) {
	VideoCryptState server;
	VideoCryptState client;
	CHECK(server.deriveFromSessionKey(SESSION_KEY, true));
	CHECK(client.deriveFromSessionKey(SESSION_KEY, false));

	MumbleUDP::VideoNack nack;
	nack.set_sender_session(3);
	nack.set_stream_id(1);
	nack.add_units()->set_frame_number(99);
	Bytes datagram;
	CHECK(server.encrypt(encodeVideoNackPacket(nack), datagram));

	VideoReceiver receiver;
	VideoReceiveEvents events;
	receiver.receive(client, datagram, 1000, events);
	CHECK_EQ(events.nacksForUs.size(), 1u);

	MumbleUDP::VideoNack parsed;
	CHECK(parsed.ParseFromArray(events.nacksForUs[0].data(), static_cast< int >(events.nacksForUs[0].size())));
	CHECK_EQ(parsed.units(0).frame_number(), 99u);
}

CORE_TEST(videoReceiverAsksForMissingFragments) {
	VideoCryptState server;
	VideoCryptState client;
	CHECK(server.deriveFromSessionKey(SESSION_KEY, true));
	CHECK(client.deriveFromSessionKey(SESSION_KEY, false));

	std::vector< Bytes > unit = relayedUnit(server, 7, 2, 40, 5000);
	CHECK(unit.size() > 2);
	unit.erase(unit.begin() + 1);

	VideoReceiver receiver;
	VideoReceiveEvents events;
	std::uint64_t now = 1'000'000;
	for (const Bytes &datagram : unit) {
		receiver.receive(client, datagram, now, events);
	}
	CHECK(events.units.empty());
	CHECK(events.packetsToSend.empty());

	// Nothing is asked for until the unit has been incomplete for VIDEO_NACK_DELAY_USEC, and the pass only
	// runs as packets arrive: here, a later unit.
	now += VIDEO_NACK_DELAY_USEC + VideoReceiver::NACK_COLLECT_INTERVAL_USEC;
	for (const Bytes &datagram : relayedUnit(server, 7, 2, 41, 100)) {
		receiver.receive(client, datagram, now, events);
	}
	CHECK(events.collectedNacks);
	CHECK_EQ(events.unitsRequested, 1u);
	CHECK_EQ(events.packetsToSend.size(), 1u);

	const Bytes &packet = events.packetsToSend[0];
	CHECK_EQ(packet[0], static_cast< std::uint8_t >(UDPMessageType::VideoNack));
	MumbleUDP::VideoNack nack;
	CHECK(nack.ParseFromArray(packet.data() + 1, static_cast< int >(packet.size() - 1)));
	CHECK_EQ(nack.sender_session(), 7u);
	CHECK_EQ(nack.stream_id(), 2u);
	CHECK_EQ(nack.units_size(), 1);
	CHECK_EQ(nack.units(0).frame_number(), 40u);
	CHECK_EQ(nack.units(0).missing_fragments(), std::uint64_t{ 1 } << 1);
}

CORE_TEST(videoReceiverPacesRetransmissionRequests) {
	VideoCryptState server;
	VideoCryptState client;
	CHECK(server.deriveFromSessionKey(SESSION_KEY, true));
	CHECK(client.deriveFromSessionKey(SESSION_KEY, false));

	// One incomplete unit on each of more streams than may be asked about in a second.
	VideoReceiver receiver;
	VideoReceiveEvents events;
	std::uint64_t now = 1'000'000;
	for (std::uint32_t stream = 1; stream <= VideoReceiver::MAX_NACK_MESSAGES_PER_SECOND + 10; stream++) {
		std::vector< Bytes > unit = relayedUnit(server, 7, stream, 1, 3000);
		receiver.receive(client, unit[0], now, events);
	}

	now += VIDEO_NACK_DELAY_USEC + VideoReceiver::NACK_COLLECT_INTERVAL_USEC;
	VideoReceiveEvents later;
	receiver.receive(client, relayedUnit(server, 7, 999, 1, 3000)[0], now, later);
	CHECK_EQ(later.unitsRequested, VideoReceiver::MAX_NACK_MESSAGES_PER_SECOND + 10);
	CHECK_EQ(later.packetsToSend.size(), VideoReceiver::MAX_NACK_MESSAGES_PER_SECOND);
}

// The public API end to end, against a server played by the core's own server-side pieces.
CORE_TEST(mediaSessionTalksToAServer) {
	CryptStateOCB2 serverAudio;
	serverAudio.genKey();
	VideoCryptState serverVideo;
	CHECK(serverVideo.deriveFromSessionKey(serverAudio.getRawKey(), true));

	MumbleCore::MediaSession session;
	MumbleCore::MediaEvents events;
	CHECK(!session.isKeyed());

	MumbleProto::CryptSetup setup;
	setup.set_key(serverAudio.getRawKey());
	setup.set_client_nonce(serverAudio.getDecryptIV());
	setup.set_server_nonce(serverAudio.getEncryptIV());
	const std::string setupBytes = setup.SerializeAsString();
	CHECK(session.handleCryptSetup(
		std::span< const std::uint8_t >(reinterpret_cast< const std::uint8_t * >(setupBytes.data()), setupBytes.size()),
		events));
	CHECK(session.isKeyed());

	// Audio from another user.
	const Bytes opus = { 0xF8, 0x01, 0x02, 0x03 };
	AudioData audio;
	audio.senderSession = 5;
	audio.frameNumber   = 77;
	audio.payload       = opus;
	UDPAudioEncoder< Role::Server > audioEncoder(PROTOBUF_INTRODUCTION_VERSION);
	const std::span< const byte > audioPacket = audioEncoder.encodeAudioPacket(audio);
	Bytes datagram(audioPacket.size() + 5);
	datagram[0] = MEDIA_CHANNEL_AUDIO;
	CHECK(
		serverAudio.encrypt(audioPacket.data(), datagram.data() + 1, static_cast< unsigned int >(audioPacket.size())));
	session.receiveDatagram(datagram, 1000, events);
	CHECK_EQ(events.audio.size(), 1u);
	CHECK_EQ(events.audio[0].senderSession, 5u);
	CHECK_EQ(events.audio[0].frameNumber, 77u);
	CHECK(events.audio[0].opus == opus);

	// Our audio, as the server would read it.
	const std::optional< MumbleCore::Bytes > ours = session.makeAudio(opus, 12, 0, true);
	CHECK(ours.has_value());
	CHECK_EQ((*ours)[0], MEDIA_CHANNEL_AUDIO);
	UDPDecoder< Role::Server > serverDecoder(PROTOBUF_INTRODUCTION_VERSION);
	const std::span< byte > buffer = serverDecoder.getBuffer();
	CHECK(serverAudio.decrypt(ours->data() + 1, buffer.data(), static_cast< unsigned int >(ours->size() - 1)));
	CHECK(serverDecoder.decode(buffer.subspan(0, ours->size() - 5)));
	CHECK(serverDecoder.getMessageType() == UDPMessageType::Audio);
	CHECK_EQ(serverDecoder.getAudioData().frameNumber, 12u);
	CHECK(serverDecoder.getAudioData().isLastFrame);

	// A ping, echoed.
	const std::optional< MumbleCore::Bytes > ping = session.makePing(0xABCDEF);
	CHECK(ping.has_value());
	CHECK(serverAudio.decrypt(ping->data() + 1, buffer.data(), static_cast< unsigned int >(ping->size() - 1)));
	CHECK(serverDecoder.decode(buffer.subspan(0, ping->size() - 5)));
	CHECK(serverDecoder.getMessageType() == UDPMessageType::Ping);
	UDPPingEncoder< Role::Server > pingEncoder(PROTOBUF_INTRODUCTION_VERSION);
	const std::span< const byte > pong = pingEncoder.encodePingPacket(serverDecoder.getPingData());
	Bytes pongDatagram(pong.size() + 5);
	pongDatagram[0] = MEDIA_CHANNEL_AUDIO;
	CHECK(serverAudio.encrypt(pong.data(), pongDatagram.data() + 1, static_cast< unsigned int >(pong.size())));
	session.receiveDatagram(pongDatagram, 2000, events);
	CHECK_EQ(events.pongs.size(), 1u);
	CHECK_EQ(events.pongs[0], 0xABCDEFu);

	// Video, keyed from the same CryptSetup.
	for (const Bytes &videoDatagram : relayedUnit(serverVideo, 9, 1, 3, 4000)) {
		session.receiveDatagram(videoDatagram, 3000, events);
	}
	CHECK_EQ(events.video.size(), 1u);
	CHECK_EQ(events.video[0].senderSession, 9u);
	CHECK_EQ(events.video[0].payload.size(), 4000u);
	CHECK(events.video[0].isKeyframe);

	CHECK(events.datagramsToSend.empty());
	CHECK(events.controlToSend.empty());
	CHECK_EQ(session.stats().audioGood, 2u);
}

CORE_TEST(mediaSessionAnswersANonceRequest) {
	CryptStateOCB2 serverAudio;
	serverAudio.genKey();

	MumbleCore::MediaSession session;
	MumbleCore::MediaEvents events;

	MumbleProto::CryptSetup setup;
	setup.set_key(serverAudio.getRawKey());
	setup.set_client_nonce(serverAudio.getDecryptIV());
	setup.set_server_nonce(serverAudio.getEncryptIV());
	const std::string setupBytes = setup.SerializeAsString();
	CHECK(session.handleCryptSetup(
		std::span< const std::uint8_t >(reinterpret_cast< const std::uint8_t * >(setupBytes.data()), setupBytes.size()),
		events));

	// An empty CryptSetup asks for our nonce.
	CHECK(session.handleCryptSetup({}, events));
	CHECK_EQ(events.controlToSend.size(), 1u);

	MumbleCore::ControlReader reader;
	CHECK(reader.feed(events.controlToSend[0]));
	const std::optional< MumbleCore::ControlMessage > reply = reader.next();
	CHECK(reply.has_value());
	CHECK_EQ(reply->type, MumbleCore::ControlType::CryptSetup);
	MumbleProto::CryptSetup parsed;
	CHECK(parsed.ParseFromArray(reply->payload.data(), static_cast< int >(reply->payload.size())));
	CHECK_EQ(parsed.client_nonce(), serverAudio.getDecryptIV());
}

CORE_TEST(mediaSessionSpeaksPlainFraming) {
	CryptStateOCB2 serverAudio;
	serverAudio.genKey();

	MumbleCore::MediaSession session;
	MumbleCore::MediaEvents events;
	session.setUdpFraming(MumbleCore::UdpFraming::Plain);

	MumbleProto::CryptSetup setup;
	setup.set_key(serverAudio.getRawKey());
	setup.set_client_nonce(serverAudio.getDecryptIV());
	setup.set_server_nonce(serverAudio.getEncryptIV());
	const std::string setupBytes = setup.SerializeAsString();
	CHECK(session.handleCryptSetup(
		std::span< const std::uint8_t >(reinterpret_cast< const std::uint8_t * >(setupBytes.data()), setupBytes.size()),
		events));

	// No channel byte either way.
	const std::optional< MumbleCore::Bytes > ping = session.makePing(42);
	CHECK(ping.has_value());
	UDPDecoder< Role::Server > serverDecoder(PROTOBUF_INTRODUCTION_VERSION);
	const std::span< byte > buffer = serverDecoder.getBuffer();
	CHECK(serverAudio.decrypt(ping->data(), buffer.data(), static_cast< unsigned int >(ping->size())));
	CHECK(serverDecoder.decode(buffer.subspan(0, ping->size() - 4)));

	UDPPingEncoder< Role::Server > pingEncoder(PROTOBUF_INTRODUCTION_VERSION);
	const std::span< const byte > pong = pingEncoder.encodePingPacket(serverDecoder.getPingData());
	Bytes datagram(pong.size() + 4);
	CHECK(serverAudio.encrypt(pong.data(), datagram.data(), static_cast< unsigned int >(pong.size())));
	session.receiveDatagram(datagram, 1000, events);
	CHECK_EQ(events.pongs.size(), 1u);
	CHECK_EQ(events.pongs[0], 42u);
}

CORE_TEST(mediaSessionIgnoresRunts) {
	CryptStateOCB2 serverAudio;
	serverAudio.genKey();

	MumbleCore::MediaSession session;
	MumbleCore::MediaEvents events;
	MumbleProto::CryptSetup setup;
	setup.set_key(serverAudio.getRawKey());
	setup.set_client_nonce(serverAudio.getDecryptIV());
	setup.set_server_nonce(serverAudio.getEncryptIV());
	const std::string setupBytes = setup.SerializeAsString();
	CHECK(session.handleCryptSetup(
		std::span< const std::uint8_t >(reinterpret_cast< const std::uint8_t * >(setupBytes.data()), setupBytes.size()),
		events));

	for (const MumbleCore::UdpFraming framing :
		 { MumbleCore::UdpFraming::ChannelByte, MumbleCore::UdpFraming::Plain }) {
		session.setUdpFraming(framing);
		for (std::size_t size = 0; size < 6; size++) {
			const Bytes runt(size, 0);
			session.receiveDatagram(runt, 1000, events);
		}
	}
	CHECK(events.audio.empty());
	CHECK(events.pongs.empty());
}

namespace {
int g_publicLogCalls = 0;
void countPublicLog(MumbleCore::LogLevel level, const char *) {
	if (level == MumbleCore::LogLevel::Warning) {
		g_publicLogCalls++;
	}
}
} // namespace

CORE_TEST(publicLogHandlerGetsCoreMessages) {
	MumbleCore::setLogHandler(countPublicLog);
	Mumble::Core::logWarning("from the core");
	MumbleCore::setLogHandler(nullptr);
	CHECK_EQ(g_publicLogCalls, 1);
}
