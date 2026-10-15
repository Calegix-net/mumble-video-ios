// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#include "mumble-core/MumbleCore.h"

#include "ControlFramer.h"
#include "CoreLog.h"
#include "CryptoSession.h"
#include "MediaDemux.h"
#include "MumbleProtocol.h"
#include "VersionNumber.h"
#include "VideoReceiver.h"

#include <chrono>

namespace MumbleCore {

using namespace Mumble::Protocol;

#define PROCESS_MUMBLE_TCP_MESSAGE(name, value)                                            \
	static_assert(ControlType::name == static_cast< std::uint16_t >(TCPMessageType::name), \
				  "ControlType::" #name " does not match the protocol");
MUMBLE_ALL_TCP_MESSAGES
#undef PROCESS_MUMBLE_TCP_MESSAGE

const char *version() {
	return MUMTEXT(MUMBLE_VERSION);
}

static_assert(static_cast< int >(LogLevel::Info) == static_cast< int >(Mumble::Core::LogLevel::Info)
				  && static_cast< int >(LogLevel::Warning) == static_cast< int >(Mumble::Core::LogLevel::Warning)
				  && static_cast< int >(LogLevel::Fatal) == static_cast< int >(Mumble::Core::LogLevel::Fatal),
			  "LogLevel does not match the core's");

void setLogHandler(LogHandler handler) {
	// Same signature but for the enum, whose values are checked above.
	Mumble::Core::setLogHandler(reinterpret_cast< Mumble::Core::LogHandler >(handler));
}

Bytes frameControlMessage(std::uint16_t type, ByteView payload) {
	return ControlFramer::frame(type, payload);
}

struct ControlReader::Impl {
	ControlFramer framer;
};

ControlReader::ControlReader() : m_impl(std::make_unique< Impl >()) {
}

ControlReader::~ControlReader() = default;

bool ControlReader::feed(ByteView bytes) {
	return m_impl->framer.feed(bytes);
}

std::optional< ControlMessage > ControlReader::next() {
	std::optional< Mumble::Protocol::ControlMessage > message = m_impl->framer.next();
	if (!message) {
		return std::nullopt;
	}

	return ControlMessage{ message->type, std::move(message->payload) };
}

void MediaEvents::clear() {
	audio.clear();
	video.clear();
	pongs.clear();
	videoNacksForUs.clear();
	datagramsToSend.clear();
	controlToSend.clear();
}

namespace {
	// Same thresholds as the desktop client: after this long without a packet that decrypts, ask the server
	// for a fresh nonce, and no more often than this.
	constexpr std::chrono::seconds CRYPT_RESYNC_AFTER(5);

	AudioPacket toAudioPacket(const AudioData &data) {
		AudioPacket packet;
		packet.senderSession = data.senderSession;
		packet.frameNumber   = data.frameNumber;
		packet.context       = data.targetOrContext;
		packet.opus.assign(data.payload.begin(), data.payload.end());
		packet.isLastFrame  = data.isLastFrame;
		packet.hasPosition  = data.containsPositionalData;
		packet.position[0]  = data.position[0];
		packet.position[1]  = data.position[1];
		packet.position[2]  = data.position[2];
		packet.volumeFactor = data.volumeAdjustment.factor;
		return packet;
	}

	VideoUnit toVideoUnit(Mumble::Protocol::VideoUnit &&unit) {
		VideoUnit out;
		out.senderSession        = unit.header.senderSession;
		out.streamID             = unit.header.streamID;
		out.frameNumber          = unit.header.frameNumber;
		out.unitID               = unit.header.unitID;
		out.isKeyframe           = unit.header.isKeyframe;
		out.isFrameEnd           = unit.header.isFrameEnd;
		out.captureTimestampUsec = unit.header.captureTimestampUsec;
		out.x                    = unit.header.x;
		out.y                    = unit.header.y;
		out.width                = unit.header.width;
		out.height               = unit.header.height;
		out.payload              = std::move(unit.payload);
		return out;
	}
} // namespace

struct MediaSession::Impl {
	CryptoSession crypto;
	MediaDemux demux{ MediaDemux::Framing::ChannelByte };
	VideoReceiver videoReceiver;
	VideoFragmenter videoFragmenter;
	// Separate decoders for the two arrival paths, as on the desktop: a host may well read UDP and TCP on
	// different threads, even if it then serialises its calls here.
	UDPDecoder< Role::Client > udpDecoder{ PROTOBUF_INTRODUCTION_VERSION };
	UDPDecoder< Role::Client > tunnelDecoder{ PROTOBUF_INTRODUCTION_VERSION };
	UDPAudioEncoder< Role::Client > audioEncoder{ PROTOBUF_INTRODUCTION_VERSION };
	UDPPingEncoder< Role::Client > pingEncoder{ PROTOBUF_INTRODUCTION_VERSION };

	void deliver(UDPDecoder< Role::Client > &decoder, MediaEvents &events) {
		switch (decoder.getMessageType()) {
			case UDPMessageType::Audio:
				events.audio.push_back(toAudioPacket(decoder.getAudioData()));
				break;
			case UDPMessageType::Ping:
				events.pongs.push_back(decoder.getPingData().timestamp);
				break;
			case UDPMessageType::Video:
			case UDPMessageType::VideoNack:
				// Only ever on the video channel, which does not come through here.
				break;
		}
	}

	std::optional< Bytes > encryptAudioChannel(std::span< const byte > packet) {
		if (packet.empty() || !crypto.isValid()) {
			return std::nullopt;
		}

		const std::size_t channelBytes = demux.framing() == MediaDemux::Framing::ChannelByte ? 1 : 0;

		Bytes datagram(packet.size() + 4 + channelBytes);
		if (channelBytes > 0) {
			datagram[0] = MEDIA_CHANNEL_AUDIO;
		}
		if (!crypto.audio().encrypt(packet.data(), datagram.data() + channelBytes,
									static_cast< unsigned int >(packet.size()))) {
			return std::nullopt;
		}

		return datagram;
	}
};

MediaSession::MediaSession() : m_impl(std::make_unique< Impl >()) {
}

MediaSession::~MediaSession() = default;

void MediaSession::setServerVersion(std::uint64_t versionV2) {
	m_impl->udpDecoder.setProtocolVersion(versionV2);
	m_impl->tunnelDecoder.setProtocolVersion(versionV2);
	m_impl->audioEncoder.setProtocolVersion(versionV2);
	m_impl->pingEncoder.setProtocolVersion(versionV2);
}

void MediaSession::setUdpFraming(UdpFraming framing) {
	m_impl->demux.setFraming(framing == UdpFraming::Plain ? MediaDemux::Framing::Plain
														  : MediaDemux::Framing::ChannelByte);
}

bool MediaSession::handleCryptSetup(ByteView payload, MediaEvents &events) {
	MumbleProto::CryptSetup message;
	if (!message.ParseFromArray(payload.data(), static_cast< int >(payload.size()))) {
		return false;
	}

	MumbleProto::CryptSetup reply;
	switch (m_impl->crypto.applyCryptSetup(message, reply)) {
		case CryptoSession::SetupResult::Keyed:
		case CryptoSession::SetupResult::Resynced:
			return true;
		case CryptoSession::SetupResult::Reply: {
			Bytes serialized(reply.ByteSizeLong());
			if (!reply.SerializeToArray(serialized.data(), static_cast< int >(serialized.size()))) {
				return false;
			}
			events.controlToSend.push_back(frameControlMessage(ControlType::CryptSetup, serialized));
			return true;
		}
		case CryptoSession::SetupResult::Invalid:
			return false;
	}

	return false;
}

bool MediaSession::isKeyed() const {
	return m_impl->crypto.isValid();
}

void MediaSession::receiveDatagram(ByteView datagram, std::uint64_t nowUsec, MediaEvents &events) {
	Impl &d = *m_impl;

	// Shorter than OCB2's own header, so nothing at all; MediaDemux has a stricter floor of its own.
	if (datagram.size() < 4 || !d.crypto.isValid()) {
		return;
	}

	const MediaDatagram media = d.demux.classify(datagram);

	if (media.channel == MediaChannel::Video) {
		VideoReceiveEvents video;
		d.videoReceiver.receive(d.crypto.video(), media.datagram, nowUsec, video);

		for (std::vector< byte > &packet : video.packetsToSend) {
			std::vector< byte > encrypted;
			if (d.crypto.video().encrypt(packet, encrypted)) {
				events.datagramsToSend.push_back(std::move(encrypted));
			}
		}
		for (std::vector< byte > &nack : video.nacksForUs) {
			events.videoNacksForUs.push_back(std::move(nack));
		}
		for (Mumble::Protocol::VideoUnit &unit : video.units) {
			events.video.push_back(toVideoUnit(std::move(unit)));
		}

		return;
	}

	if (media.channel != MediaChannel::Audio) {
		return;
	}

	CryptStateOCB2 &audio           = d.crypto.audio();
	const std::span< byte > buffer  = d.udpDecoder.getBuffer();
	const std::size_t encryptedSize = media.payload.size();
	if (encryptedSize < 4 || buffer.size() < encryptedSize - 4) {
		return;
	}

	if (!audio.decrypt(media.payload.data(), buffer.data(), static_cast< unsigned int >(encryptedSize))) {
		if (audio.tLastGood.elapsed() > CRYPT_RESYNC_AFTER && audio.tLastRequest.elapsed() > CRYPT_RESYNC_AFTER) {
			audio.tLastRequest.restart();
			events.controlToSend.push_back(frameControlMessage(ControlType::CryptSetup, {}));
		}
		return;
	}

	if (d.udpDecoder.decode(buffer.subspan(0, encryptedSize - 4))) {
		d.deliver(d.udpDecoder, events);
	}
}

void MediaSession::receiveTunnelled(ByteView payload, MediaEvents &events) {
	if (m_impl->tunnelDecoder.decode(payload)) {
		m_impl->deliver(m_impl->tunnelDecoder, events);
	}
}

std::optional< Bytes > MediaSession::makePing(std::uint64_t timestamp) {
	PingData ping;
	ping.timestamp = timestamp;

	return m_impl->encryptAudioChannel(m_impl->pingEncoder.encodePingPacket(ping));
}

std::optional< Bytes > MediaSession::makeAudio(ByteView opusFrame, std::uint64_t frameNumber, std::uint32_t target,
											   bool isLastFrame) {
	AudioData audio;
	audio.targetOrContext = target;
	audio.usedCodec       = AudioCodec::Opus;
	audio.frameNumber     = frameNumber;
	audio.payload         = opusFrame;
	audio.isLastFrame     = isLastFrame;

	return m_impl->encryptAudioChannel(m_impl->audioEncoder.encodeAudioPacket(audio));
}

std::vector< Bytes > MediaSession::makeVideo(const VideoUnit &unit) {
	Impl &d = *m_impl;

	// A server that frames plainly does not speak video at all.
	if (!d.crypto.video().isValid() || d.demux.framing() != MediaDemux::Framing::ChannelByte) {
		return {};
	}

	VideoUnitHeader header;
	header.streamID             = unit.streamID;
	header.frameNumber          = unit.frameNumber;
	header.unitID               = unit.unitID;
	header.isKeyframe           = unit.isKeyframe;
	header.isFrameEnd           = unit.isFrameEnd;
	header.captureTimestampUsec = unit.captureTimestampUsec;
	header.x                    = unit.x;
	header.y                    = unit.y;
	header.width                = unit.width;
	header.height               = unit.height;

	if (!d.videoFragmenter.fragment(header, unit.payload)) {
		return {};
	}

	std::vector< Bytes > datagrams;
	for (const std::vector< byte > &packet : d.videoFragmenter.packets()) {
		Bytes datagram;
		if (!d.crypto.video().encrypt(packet, datagram)) {
			return {};
		}
		datagrams.push_back(std::move(datagram));
	}

	return datagrams;
}

void MediaSession::removeSender(std::uint32_t senderSession) {
	m_impl->videoReceiver.removeSender(senderSession);
}

MediaStats MediaSession::stats() const {
	const CryptoSession &crypto = m_impl->crypto;

	MediaStats stats;
	stats.audioGood         = crypto.audio().m_statsLocal.good;
	stats.audioLate         = crypto.audio().m_statsLocal.late;
	stats.audioLost         = crypto.audio().m_statsLocal.lost;
	stats.audioResync       = crypto.audio().m_statsLocal.resync;
	stats.videoReplays      = crypto.video().replayCount();
	stats.videoTooOld       = crypto.video().tooOldCount();
	stats.videoAuthFailures = crypto.video().authFailureCount();
	return stats;
}

} // namespace MumbleCore
