// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#ifndef MUMBLE_CORE_MUMBLECORE_H_
#define MUMBLE_CORE_MUMBLECORE_H_

// The public face of mumble-core: what a host that is not the desktop client (the Android app, through
// JNI) calls. Nothing here exposes Protobuf, OpenSSL or the internal headers, so this is the only header
// such a host needs.
//
// The core never touches a socket. The host owns the TLS connection and the UDP socket, and moves bytes:
//
//   TLS bytes read      -> ControlReader::feed()       -> ControlMessage (type + Protobuf payload)
//   message to send     -> frameControlMessage()       -> bytes to write to TLS
//   UDP datagram read   -> MediaSession::receiveDatagram() -> MediaEvents
//   CryptSetup message  -> MediaSession::handleCryptSetup() (keys the UDP crypto)
//   audio/ping to send  -> MediaSession::makeAudio()/makePing() -> datagram for sendto()
//
// Control messages are left to the host to parse: Mumble.proto is in this directory, and the host
// generates its own bindings from it. The one exception is CryptSetup, which the session needs itself.
//
// Times are microseconds on a monotonic clock the host chooses, used only to compare against each other.
//
// Nothing here is thread safe. A host either calls a MediaSession from one thread, or serialises the calls.

#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <vector>

namespace MumbleCore {

using Bytes    = std::vector< std::uint8_t >;
using ByteView = std::span< const std::uint8_t >;

/// The protocol version the core speaks, as a string, e.g. "1.7.0": what goes in the Version message's
/// version_v2 (as numbers) and what upstream peers gate features on. Not the fork's release number.
const char *version();

/// How bad a log message is. Fatal is followed by abort(), whatever the handler does.
enum class LogLevel { Info, Warning, Fatal };

using LogHandler = void (*)(LogLevel level, const char *message);

/// Where the core's log messages go (Android: logcat). nullptr, the default, writes them to stderr. Safe
/// to call from any thread; the handler may be called from any thread that calls into the core.
void setLogHandler(LogHandler handler);

/// Control message types, as on the wire (Mumble.proto names them). Append-only, never renumbered.
namespace ControlType {
	constexpr std::uint16_t Version                = 0;
	constexpr std::uint16_t UDPTunnel              = 1;
	constexpr std::uint16_t Authenticate           = 2;
	constexpr std::uint16_t Ping                   = 3;
	constexpr std::uint16_t Reject                 = 4;
	constexpr std::uint16_t ServerSync             = 5;
	constexpr std::uint16_t ChannelRemove          = 6;
	constexpr std::uint16_t ChannelState           = 7;
	constexpr std::uint16_t UserRemove             = 8;
	constexpr std::uint16_t UserState              = 9;
	constexpr std::uint16_t BanList                = 10;
	constexpr std::uint16_t TextMessage            = 11;
	constexpr std::uint16_t PermissionDenied       = 12;
	constexpr std::uint16_t ACL                    = 13;
	constexpr std::uint16_t QueryUsers             = 14;
	constexpr std::uint16_t CryptSetup             = 15;
	constexpr std::uint16_t ContextActionModify    = 16;
	constexpr std::uint16_t ContextAction          = 17;
	constexpr std::uint16_t UserList               = 18;
	constexpr std::uint16_t VoiceTarget            = 19;
	constexpr std::uint16_t PermissionQuery        = 20;
	constexpr std::uint16_t CodecVersion           = 21;
	constexpr std::uint16_t UserStats              = 22;
	constexpr std::uint16_t RequestBlob            = 23;
	constexpr std::uint16_t ServerConfig           = 24;
	constexpr std::uint16_t SuggestConfig          = 25;
	constexpr std::uint16_t PluginDataTransmission = 26;
	constexpr std::uint16_t VideoState             = 27;
	constexpr std::uint16_t VideoSubscribe         = 28;
	constexpr std::uint16_t FileTransfer           = 29;
} // namespace ControlType

// ---- Control channel (TLS) ----

struct ControlMessage {
	std::uint16_t type = 0;
	/// The serialised Protobuf message.
	Bytes payload;
};

/// One control message as it goes on the TLS stream: 2-byte type and 4-byte length, both big-endian, then
/// the payload. Empty if the payload is longer than the protocol allows.
Bytes frameControlMessage(std::uint16_t type, ByteView payload);

/// Splits what is read from the TLS stream back into messages. Feed it whatever the socket returned, in
/// any pieces.
class ControlReader {
public:
	ControlReader();
	~ControlReader();
	ControlReader(const ControlReader &)            = delete;
	ControlReader &operator=(const ControlReader &) = delete;

	/// False once the peer has announced a message longer than the protocol allows. Disconnect then: the
	/// stream can no longer be framed.
	bool feed(ByteView bytes);

	/// The next complete message, if any. Call until empty after every feed().
	std::optional< ControlMessage > next();

private:
	struct Impl;
	std::unique_ptr< Impl > m_impl;
};

// ---- Media (UDP) ----

/// One received audio packet. The payload is a single Opus frame, still encoded.
struct AudioPacket {
	std::uint32_t senderSession = 0;
	std::uint64_t frameNumber   = 0;
	/// What kind of speech this is: 0 normal, 1 shout, 2 whisper, 3 listening (a channel listener).
	std::uint32_t context = 0;
	Bytes opus;
	/// The sender stopped talking after this frame.
	bool isLastFrame  = false;
	bool hasPosition  = false;
	float position[3] = { 0, 0, 0 };
	/// Volume the server asks this to be played at, as a linear factor.
	float volumeFactor = 1.0f;
};

/// One reassembled unit of video, ready for the decoder. A unit is a whole frame, or for tiled codecs one
/// tile of it at (x, y).
struct VideoUnit {
	std::uint32_t senderSession        = 0;
	std::uint32_t streamID             = 0;
	std::uint64_t frameNumber          = 0;
	std::uint32_t unitID               = 0;
	bool isKeyframe                    = false;
	bool isFrameEnd                    = false;
	std::uint64_t captureTimestampUsec = 0;
	std::uint32_t x                    = 0;
	std::uint32_t y                    = 0;
	std::uint32_t width                = 0;
	std::uint32_t height               = 0;
	Bytes payload;
};

/// Everything the session produced from one call. The host acts on every list, and may reuse the object
/// once it has (clear() empties it).
struct MediaEvents {
	std::vector< AudioPacket > audio;
	std::vector< VideoUnit > video;
	/// Our UDP pings, echoed back by the server: the timestamps makePing() was given.
	std::vector< std::uint64_t > pongs;
	/// Serialised MumbleUDP.VideoNack messages: a viewer asking for parts of one of our own streams again.
	std::vector< Bytes > videoNacksForUs;
	/// Datagrams to send to the server's UDP port as they are.
	std::vector< Bytes > datagramsToSend;
	/// Framed control messages to write to the TLS stream as they are.
	std::vector< Bytes > controlToSend;

	void clear();
};

/// Packet counters for a connection-quality display, as the desktop shows them.
struct MediaStats {
	std::uint32_t audioGood         = 0;
	std::uint32_t audioLate         = 0;
	std::uint32_t audioLost         = 0;
	std::uint32_t audioResync       = 0;
	std::uint64_t videoReplays      = 0;
	std::uint64_t videoTooOld       = 0;
	std::uint64_t videoAuthFailures = 0;
};

/// How datagrams are framed on this connection. mumble-video servers put a channel byte (audio or video)
/// in front of every datagram; stock Mumble servers send the bare encrypted payload and no video.
enum class UdpFraming { ChannelByte, Plain };

/// The UDP side of one connection to a server, as a client: both crypt states, the audio codec framing, and
/// video reception with its retransmission requests.
class MediaSession {
public:
	MediaSession();
	~MediaSession();
	MediaSession(const MediaSession &)            = delete;
	MediaSession &operator=(const MediaSession &) = delete;

	/// The server's protocol version, from its Version message (version_v2). Until this is called the
	/// server is assumed to be 1.5.0 or newer, which every server with video is.
	void setServerVersion(std::uint64_t versionV2);

	/// ChannelByte until told otherwise. Set Plain for a server that does not speak video, before any
	/// datagram is exchanged: the two framings cannot be told apart from the bytes.
	void setUdpFraming(UdpFraming framing);

	/// Applies a CryptSetup control message (its payload) from the server. A full key keys both audio and
	/// video; a lone server nonce resyncs audio; an empty one asks for our nonce, and the reply is queued in
	/// events.controlToSend. Returns false if the message did not parse or did not fit.
	bool handleCryptSetup(ByteView payload, MediaEvents &events);

	/// Whether a key has been set. Until then every datagram is dropped and nothing can be sent.
	bool isKeyed() const;

	/// One datagram read from the server's UDP port. Anything that fails to decrypt or parse is dropped
	/// silently, except that a long run of failures queues a CryptSetup asking the server to resync.
	void receiveDatagram(ByteView datagram, std::uint64_t nowUsec, MediaEvents &events);

	/// Audio the server tunnelled over TCP, when UDP is not getting through: a UDPTunnel message's payload.
	void receiveTunnelled(ByteView payload, MediaEvents &events);

	/// An encrypted ping carrying `timestamp`, which comes back in MediaEvents::pongs.
	std::optional< Bytes > makePing(std::uint64_t timestamp);

	/// An encrypted audio datagram carrying one Opus frame. target: 0 normal speech, 1-30 a VoiceTarget,
	/// 31 server loopback.
	std::optional< Bytes > makeAudio(ByteView opusFrame, std::uint64_t frameNumber, std::uint32_t target,
									 bool isLastFrame);

	/// Fragments and encrypts one coded unit of our own video into datagrams for sendto(), in order. It
	/// shares the video crypt state with our retransmission requests, so the connection has one sequence
	/// (nonce) space and never reuses a nonce. senderSession is ignored: the server stamps it. Empty if not
	/// keyed, if the framing is Plain (no video there), or if the unit is larger than one unit may be.
	std::vector< Bytes > makeVideo(const VideoUnit &unit);

	/// Forgets what is held for a user (their partial video units), when they leave or stop sending.
	void removeSender(std::uint32_t senderSession);

	MediaStats stats() const;

private:
	struct Impl;
	std::unique_ptr< Impl > m_impl;
};

} // namespace MumbleCore

#endif // MUMBLE_CORE_MUMBLECORE_H_
