import CMumbleBridge
import Foundation

/// mumble-core's version string (the protocol version this client speaks, e.g. "1.10.0").
public var coreVersion: String { String(cString: mv_core_version()) }

/// One decoded voice packet from the media session.
public struct AudioPacket: Sendable {
    public var senderSession: UInt32
    public var frameNumber: UInt64
    /// 0 normal, 1 shout, 2 whisper, 3 listen.
    public var context: UInt32
    public var opus: Data
    public var isLastFrame: Bool
    public var volumeFactor: Float

    public init(senderSession: UInt32, frameNumber: UInt64, context: UInt32, opus: Data, isLastFrame: Bool, volumeFactor: Float) {
        self.senderSession = senderSession
        self.frameNumber = frameNumber
        self.context = context
        self.opus = opus
        self.isLastFrame = isLastFrame
        self.volumeFactor = volumeFactor
    }
}

/// One reassembled, decrypted video unit (a whole VP8/VP9 frame, or one part of an H.264 frame).
public struct VideoUnit: Sendable {
    public var senderSession: UInt32
    public var streamID: UInt32
    public var frameNumber: UInt64
    public var unitID: UInt32
    public var isKeyframe: Bool
    public var isFrameEnd: Bool
    public var captureTimestampUsec: UInt64
    public var x, y, width, height: UInt32
    public var payload: Data

    public init(senderSession: UInt32, streamID: UInt32, frameNumber: UInt64, unitID: UInt32, isKeyframe: Bool, isFrameEnd: Bool,
                captureTimestampUsec: UInt64, x: UInt32, y: UInt32, width: UInt32, height: UInt32, payload: Data) {
        self.senderSession = senderSession
        self.streamID = streamID
        self.frameNumber = frameNumber
        self.unitID = unitID
        self.isKeyframe = isKeyframe
        self.isFrameEnd = isFrameEnd
        self.captureTimestampUsec = captureTimestampUsec
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.payload = payload
    }
}

/// Everything one call into the media session produced. The host must act on every list.
public struct MediaEvents: Sendable {
    public var audio: [AudioPacket] = []
    public var video: [VideoUnit] = []
    public var pongs: [UInt64] = []
    public var videoNacksForUs: [Data] = []
    public var datagramsToSend: [Data] = []
    /// Already framed for the control channel.
    public var controlToSend: [Data] = []
}

public struct MediaStats: Sendable, Equatable {
    public var audioGood, audioLate, audioLost, audioResync: UInt32
    public var videoReplays, videoTooOld, videoAuthFailures: UInt64
}

/// The UDP side of one connection: crypt state, voice and video datagrams, pings. Not thread-safe; use it
/// from one queue.
public final class MediaSession {
    private let handle: OpaquePointer

    public init() {
        handle = mv_session_create()
    }

    deinit {
        mv_session_destroy(handle)
    }

    public func setServerVersion(_ versionV2: UInt64) {
        mv_session_set_server_version(handle, versionV2)
    }

    /// true when the server advertised video: media datagrams then carry the leading channel byte.
    public func setChannelFraming(_ channelByte: Bool) {
        mv_session_set_channel_framing(handle, channelByte)
    }

    public var isKeyed: Bool { mv_session_is_keyed(handle) }

    /// Handles a CryptSetup payload (full key, server nonce resync, or the server asking for our nonce).
    @discardableResult
    public func cryptSetup(_ payload: Data) -> (ok: Bool, events: MediaEvents) {
        let ok = payload.withUnsafeBytes { mv_session_crypt_setup(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        return (ok, drain())
    }

    public func receiveDatagram(_ datagram: Data, nowUsec: UInt64) -> MediaEvents {
        datagram.withUnsafeBytes { mv_session_receive_datagram(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, nowUsec) }
        return drain()
    }

    /// A UDPTunnel payload that arrived over the control channel.
    public func receiveTunnelled(_ payload: Data) -> MediaEvents {
        payload.withUnsafeBytes { mv_session_receive_tunnelled(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        return drain()
    }

    public func makePing(timestamp: UInt64) -> Data? {
        var out = [UInt8](repeating: 0, count: 256)
        let n = mv_session_make_ping(handle, timestamp, &out, out.count)
        return n > 0 ? Data(out[0 ..< n]) : nil
    }

    /// target: 0 normal speech, 1-30 a voice target, 31 server loopback.
    public func makeAudio(opus: Data, frameNumber: UInt64, target: UInt32 = 0, isLast: Bool) -> Data? {
        var out = [UInt8](repeating: 0, count: opus.count + 128)
        let n = opus.withUnsafeBytes {
            mv_session_make_audio(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, frameNumber, target, isLast, &out, out.count)
        }
        return n > 0 ? Data(out[0 ..< n]) : nil
    }

    /// Fragments and encrypts one video unit into datagrams (empty if not keyed or framing is plain).
    public func makeVideo(_ unit: VideoUnit) -> [Data] {
        final class Out { var datagrams: [Data] = [] }
        let out = Out()
        unit.payload.withUnsafeBytes { p in
            var u = mv_video_unit(sender_session: 0, stream_id: unit.streamID, frame_number: unit.frameNumber, unit_id: unit.unitID,
                                  is_keyframe: unit.isKeyframe, is_frame_end: unit.isFrameEnd, capture_timestamp_usec: unit.captureTimestampUsec,
                                  x: unit.x, y: unit.y, width: unit.width, height: unit.height,
                                  payload: p.bindMemory(to: UInt8.self).baseAddress, payload_len: p.count)
            _ = mv_session_make_video(handle, &u, Unmanaged.passUnretained(out).toOpaque()) { ctx, b, n in
                guard let ctx, let b else { return }
                Unmanaged<Out>.fromOpaque(ctx).takeUnretainedValue().datagrams.append(Data(bytes: b, count: n))
            }
        }
        return out.datagrams
    }

    public func removeSender(_ session: UInt32) {
        mv_session_remove_sender(handle, session)
    }

    public var stats: MediaStats {
        let s = mv_session_stats(handle)
        return MediaStats(audioGood: s.audio_good, audioLate: s.audio_late, audioLost: s.audio_lost, audioResync: s.audio_resync,
                          videoReplays: s.video_replays, videoTooOld: s.video_too_old, videoAuthFailures: s.video_auth_failures)
    }

    private func drain() -> MediaEvents {
        let box = EventBox()
        var sink = mv_sink()
        sink.ctx = Unmanaged.passUnretained(box).toOpaque()
        sink.audio = { ctx, p in
            guard let ctx, let p else { return }
            let e = p.pointee
            EventBox.from(ctx).events.audio.append(AudioPacket(
                senderSession: e.sender_session, frameNumber: e.frame_number, context: e.context,
                opus: Data(bytes: e.opus, count: e.opus_len), isLastFrame: e.is_last_frame, volumeFactor: e.volume_factor))
        }
        sink.video = { ctx, u in
            guard let ctx, let u else { return }
            let v = u.pointee
            EventBox.from(ctx).events.video.append(VideoUnit(
                senderSession: v.sender_session, streamID: v.stream_id, frameNumber: v.frame_number, unitID: v.unit_id,
                isKeyframe: v.is_keyframe, isFrameEnd: v.is_frame_end, captureTimestampUsec: v.capture_timestamp_usec,
                x: v.x, y: v.y, width: v.width, height: v.height, payload: Data(bytes: v.payload, count: v.payload_len)))
        }
        sink.pong = { ctx, t in
            guard let ctx else { return }
            EventBox.from(ctx).events.pongs.append(t)
        }
        sink.nack_for_us = { ctx, b, n in
            guard let ctx, let b else { return }
            EventBox.from(ctx).events.videoNacksForUs.append(Data(bytes: b, count: n))
        }
        sink.datagram = { ctx, b, n in
            guard let ctx, let b else { return }
            EventBox.from(ctx).events.datagramsToSend.append(Data(bytes: b, count: n))
        }
        sink.control = { ctx, b, n in
            guard let ctx, let b else { return }
            EventBox.from(ctx).events.controlToSend.append(Data(bytes: b, count: n))
        }
        withExtendedLifetime(box) { mv_session_drain(handle, &sink) }
        return box.events
    }
}

private final class EventBox {
    var events = MediaEvents()

    static func from(_ ctx: UnsafeMutableRawPointer) -> EventBox {
        Unmanaged<EventBox>.fromOpaque(ctx).takeUnretainedValue()
    }
}

/// Splits the TLS byte stream into control messages.
public final class ControlReader {
    private let handle: OpaquePointer

    public init() {
        handle = mv_control_reader_create()
    }

    deinit {
        mv_control_reader_destroy(handle)
    }

    /// Feeds bytes and returns every complete message. nil means the peer announced an oversize message.
    public func feed(_ bytes: Data) -> [(type: UInt16, payload: Data)]? {
        let ok = bytes.withUnsafeBytes { mv_control_reader_feed(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        guard ok else { return nil }
        let box = MessageBox()
        withExtendedLifetime(box) {
            mv_control_reader_drain(handle, Unmanaged.passUnretained(box).toOpaque()) { ctx, type, payload, len in
                guard let ctx else { return }
                Unmanaged<MessageBox>.fromOpaque(ctx).takeUnretainedValue()
                    .messages.append((type, payload.map { Data(bytes: $0, count: len) } ?? Data()))
            }
        }
        return box.messages
    }

    /// Frames one outgoing control message.
    public static func frame(type: UInt16, payload: Data) -> Data {
        var out = [UInt8](repeating: 0, count: payload.count + 6)
        let n = payload.withUnsafeBytes { mv_frame_control(type, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &out) }
        return Data(out[0 ..< n])
    }
}

private final class MessageBox {
    var messages: [(type: UInt16, payload: Data)] = []
}
