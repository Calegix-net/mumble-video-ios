@preconcurrency import AVFoundation
import Foundation

/// Microphone and speaker for a MumbleClient: AVAudioEngine with Apple's voice processing (echo
/// cancellation, noise suppression), capture converted to 48 kHz mono for Opus, and the VoiceMixer
/// played through a source node.
///
/// Bluetooth plays as media (A2DP) rather than as a hands-free call, the same choice the Android client
/// made for cars: no call screen, no drop to call quality; the phone's microphone records.
public final class VoiceEngine: @unchecked Sendable {
    public let mixer: VoiceMixer
    public let encoder: VoiceEncoder
    private let client: MumbleClient
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let captureFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true)!
    private var running = false

    /// Plays `mixer` (which MediaHub feeds) and sends what the microphone hears through `client`.
    public init?(client: MumbleClient, mixer: VoiceMixer) {
        guard let encoder = VoiceEncoder() else { return nil }
        self.encoder = encoder
        self.client = client
        self.mixer = mixer
        encoder.onPacket = { [weak client] opus, frame, isLast in
            client?.sendAudio(opus: opus, frameNumber: frame, isLast: isLast)
        }
    }

    /// Starts playback, and capture too if `capture` (needs microphone permission).
    public func start(capture: Bool) throws {
        guard !running else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay])
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
        #endif

        let out = engine.outputNode
        let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let source = AVAudioSourceNode(format: playFormat) { [mixer] _, _, frames, buffers in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            if let data = list.first?.mData {
                mixer.render(into: data.assumingMemoryBound(to: Float.self), count: Int(frames))
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: playFormat)
        engine.connect(engine.mainMixerNode, to: out, format: nil)

        if capture {
            let input = engine.inputNode
            try? input.setVoiceProcessingEnabled(true)
            let hw = input.outputFormat(forBus: 0)
            converter = AVAudioConverter(from: hw, to: captureFormat)
            input.installTap(onBus: 0, bufferSize: 480, format: hw) { [weak self] buffer, _ in
                self?.captured(buffer)
            }
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    public func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func captured(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = captureFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity) else { return }
        nonisolated(unsafe) var consumed = false // the input block runs synchronously inside convert
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.int16ChannelData else { return }
        encoder.feed(Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength))))
    }
}
