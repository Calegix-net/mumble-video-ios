import Foundation

/// Received voice to one mono 48 kHz stream: a jitter buffer and Opus decoder per talking user, mixed
/// 10 ms at a time (the Android client's AudioPlayback, minus the output device so it can be tested).
///
/// `push` is called from the network queue; `render` from the audio thread.
public final class VoiceMixer: @unchecked Sendable {
    public static let frame = Opus.frameSamples
    /// Concealed frames in a row before giving up and rebuffering.
    static let maxConceal = 3

    private final class Speaker {
        let jitter = JitterBuffer()
        let decoder = Opus.Decoder()!
        var pcm: [Int16] = []
        var lastPacketSamples = 2 * VoiceMixer.frame
        var concealed = 0
        var level: Float = 0
    }

    private let lock = NSLock()
    private var speakers: [UInt32: Speaker] = [:]
    private var carry: [Float] = [] // mixed samples rendered but not yet handed out
    public var deafened = false
    /// Per-sender linear volume.
    public var volumes: [UInt32: Float] = [:]

    public init() {}

    public func push(_ packet: AudioPacket) {
        if deafened { return }
        let s = lock.withLock { () -> Speaker in
            if let s = speakers[packet.senderSession] { return s }
            let s = Speaker()
            speakers[packet.senderSession] = s
            return s
        }
        s.jitter.put(frame: packet.frameNumber, opus: packet.opus, terminator: packet.isLastFrame)
    }

    public func remove(_ session: UInt32) {
        lock.withLock { speakers[session] = nil }
    }

    /// Sessions heard in the last rendered frame (for talking indicators).
    public func talking() -> Set<UInt32> {
        lock.withLock { Set(speakers.filter { $0.value.level > 0.01 }.keys) }
    }

    /// One 10 ms frame of the mix as Int16.
    public func mixFrame() -> [Int16] {
        var mix = [Int32](repeating: 0, count: Self.frame)
        let current = lock.withLock { speakers }
        if !deafened {
            for (session, s) in current {
                let gain = volumes[session] ?? 1
                if fill(s) {
                    var peak: Int32 = 0
                    for i in 0 ..< Self.frame {
                        let v = Int32(Float(s.pcm[i]) * gain)
                        mix[i] += v
                        peak = max(peak, abs(v))
                    }
                    s.pcm.removeFirst(Self.frame)
                    s.level = Float(peak) / 32768
                } else {
                    s.level = 0
                }
            }
        }
        return mix.map { Int16(clamping: $0) }
    }

    /// Fills `count` Float samples (-1...1) for an audio callback, mixing as many 10 ms frames as needed.
    public func render(into out: UnsafeMutablePointer<Float>, count: Int) {
        var written = 0
        while written < count {
            if carry.isEmpty {
                carry = mixFrame().map { Float($0) / 32768 }
            }
            let n = min(count - written, carry.count)
            for i in 0 ..< n { out[written + i] = carry[i] }
            carry.removeFirst(n)
            written += n
        }
    }

    /// Makes sure the speaker has 10 ms decoded. False if it has nothing to play now.
    private func fill(_ s: Speaker) -> Bool {
        while s.pcm.count < Self.frame {
            switch s.jitter.take() {
            case let .packet(opus):
                s.concealed = 0
                let pcm = s.decoder.decode(opus)
                guard !pcm.isEmpty else { return dropPartial(s) }
                s.lastPacketSamples = pcm.count
                s.pcm += pcm
            case .gap:
                // Underrun mid-talk: conceal a little, then give up and rebuffer.
                if s.concealed >= Self.maxConceal { return dropPartial(s) }
                s.concealed += 1
                let pcm = s.decoder.decode(nil, concealSamples: s.lastPacketSamples)
                guard !pcm.isEmpty else { return dropPartial(s) }
                s.pcm += pcm
            case .idle:
                return dropPartial(s)
            }
        }
        return true
    }

    /// Play out what is left by padding the final partial frame with silence.
    private func dropPartial(_ s: Speaker) -> Bool {
        guard !s.pcm.isEmpty else { return false }
        s.pcm += [Int16](repeating: 0, count: Self.frame - s.pcm.count)
        return true
    }
}

/// Our side of the conversation: 10 ms frames of mono 48 kHz PCM in, Opus packets out, with voice
/// activity detection or push-to-talk deciding what is sent.
public final class VoiceEncoder: @unchecked Sendable {
    public enum Mode: Sendable { case voiceActivity(threshold: Float), pushToTalk, continuous }

    public var mode: Mode = .voiceActivity(threshold: 0.02)
    public var pushToTalkPressed = false
    public var muted = false
    /// 10 ms frames per packet (2 = 20 ms, as Android and desktop default).
    public let framesPerPacket: Int
    /// Called with each Opus packet and its frame number; isLast marks the end of a talk spurt.
    public var onPacket: ((Data, UInt64, Bool) -> Void)?

    private let encoder: Opus.Encoder
    private var pending: [Int16] = []
    private var frameNumber: UInt64 = 0
    private var talking = false
    private var holdFrames = 0
    /// Keep sending this long after the voice drops below the threshold (250 ms), so words are not clipped.
    static let hangoverFrames = 25

    public init?(bitrate: Int = 40_000, framesPerPacket: Int = 2) {
        guard let e = Opus.Encoder(bitrate: bitrate) else { return nil }
        encoder = e
        self.framesPerPacket = framesPerPacket
    }

    /// Feed captured PCM of any length; whole packets are encoded as they fill.
    public func feed(_ pcm: [Int16]) {
        pending += pcm
        let packetSamples = Opus.frameSamples * framesPerPacket
        while pending.count >= packetSamples {
            let chunk = Array(pending.prefix(packetSamples))
            pending.removeFirst(packetSamples)
            process(chunk)
        }
    }

    private func process(_ chunk: [Int16]) {
        let wantsToTalk: Bool
        if muted {
            wantsToTalk = false
        } else {
            switch mode {
            case .continuous: wantsToTalk = true
            case .pushToTalk: wantsToTalk = pushToTalkPressed
            case let .voiceActivity(threshold):
                let rms = (chunk.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(chunk.count)).squareRoot() / 32768
                if Float(rms) >= threshold {
                    holdFrames = Self.hangoverFrames
                } else if holdFrames > 0 {
                    holdFrames -= framesPerPacket
                }
                wantsToTalk = holdFrames > 0
            }
        }
        if wantsToTalk, let opus = encoder.encode(chunk) {
            talking = true
            onPacket?(opus, frameNumber, false)
            frameNumber += UInt64(framesPerPacket)
        } else if talking {
            // End the spurt with a terminator so receivers stop waiting.
            talking = false
            if let opus = encoder.encode([Int16](repeating: 0, count: chunk.count)) {
                onPacket?(opus, frameNumber, true)
                frameNumber += UInt64(framesPerPacket)
            }
        }
    }

    public var isTalking: Bool { talking }
}
