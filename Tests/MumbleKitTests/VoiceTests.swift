import Foundation
@testable import MumbleKit
import Testing

struct JitterBufferTests {
    @Test func prebuffersThenPlaysInOrder() {
        let j = JitterBuffer(prebuffer: 2)
        j.put(frame: 4, opus: Data([4]), terminator: false)
        #expect(j.take() == .idle) // one packet, target 2
        j.put(frame: 2, opus: Data([2]), terminator: false)
        #expect(j.take() == .packet(Data([2])))
        #expect(j.take() == .packet(Data([4])))
    }

    @Test func dropsLateAndDuplicatePackets() {
        let j = JitterBuffer(prebuffer: 1)
        j.put(frame: 10, opus: Data([10]), terminator: false)
        #expect(j.take() == .packet(Data([10])))
        j.put(frame: 8, opus: Data([8]), terminator: false) // late
        j.put(frame: 10, opus: Data([10]), terminator: false) // duplicate
        #expect(j.count == 0)
    }

    @Test func underrunRaisesTargetAndRebuffers() {
        let j = JitterBuffer(prebuffer: 2)
        j.put(frame: 0, opus: Data([0]), terminator: false)
        j.put(frame: 2, opus: Data([2]), terminator: false)
        #expect(j.take() == .packet(Data([0])))
        #expect(j.take() == .packet(Data([2])))
        #expect(j.take() == .gap) // underrun mid-talk
        #expect(j.target == 3)
        j.put(frame: 4, opus: Data([4]), terminator: false)
        #expect(j.take() == .gap) // rebuffering to 3
        j.put(frame: 6, opus: Data([6]), terminator: false)
        j.put(frame: 8, opus: Data([8]), terminator: false)
        #expect(j.take() == .packet(Data([4])))
    }

    @Test func terminatorEndsTheSpurt() {
        let j = JitterBuffer(prebuffer: 3)
        j.put(frame: 0, opus: Data([0]), terminator: true) // short spurt: play it without waiting
        #expect(j.take() == .packet(Data([0])))
        #expect(j.take() == .idle)
    }
}

struct VoiceMixerTests {
    @Test func mixesTwoSpeakers() throws {
        let mixer = VoiceMixer()
        let enc = try #require(Opus.Encoder(bitrate: 40_000))
        for speaker in [UInt32(1), 2] {
            for n in 0 ..< 6 {
                let pcm = (0 ..< 960).map { i in Int16(6000 * sin(Double(n * 960 + i) * 2 * .pi * (speaker == 1 ? 300 : 500) / 48000)) }
                let opus = try #require(enc.encode(pcm))
                mixer.push(AudioPacket(senderSession: speaker, frameNumber: UInt64(n * 2), context: 0, opus: opus, isLastFrame: n == 5, volumeFactor: 1))
            }
        }
        var loud = 0
        for _ in 0 ..< 10 {
            loud = max(loud, mixer.mixFrame().map { abs(Int($0)) }.max() ?? 0)
        }
        #expect(loud > 3000)
        #expect(mixer.talking() == [1, 2])
        mixer.remove(1)
        mixer.remove(2)
        #expect(mixer.mixFrame().allSatisfy { $0 == 0 })
    }

    @Test func renderFillsArbitraryBufferSizes() {
        let mixer = VoiceMixer()
        var out = [Float](repeating: 1, count: 1234)
        out.withUnsafeMutableBufferPointer { mixer.render(into: $0.baseAddress!, count: 1234) }
        #expect(out.allSatisfy { $0 == 0 })
    }
}

struct VoiceEncoderTests {
    @Test func voiceActivityStartsAndEndsWithATerminator() throws {
        let enc = try #require(VoiceEncoder())
        var sent: [(UInt64, Bool)] = []
        enc.onPacket = { _, frame, last in sent.append((frame, last)) }
        let silence = [Int16](repeating: 0, count: 960)
        let tone = (0 ..< 960).map { i in Int16(8000 * sin(Double(i) * 2 * .pi * 440 / 48000)) }
        enc.feed(silence)
        #expect(sent.isEmpty)
        enc.feed(tone)
        enc.feed(tone)
        #expect(sent.count == 2)
        for _ in 0 ..< 20 { enc.feed(silence) } // hangover, then terminator
        #expect(sent.last?.1 == true)
        #expect(sent.map(\.0) == Array(stride(from: 0, to: UInt64(sent.count * 2), by: 2)))
    }

    @Test func mutedSendsNothing() throws {
        let enc = try #require(VoiceEncoder())
        enc.muted = true
        var count = 0
        enc.onPacket = { _, _, _ in count += 1 }
        enc.feed((0 ..< 9600).map { i in Int16(8000 * sin(Double(i) * 0.05)) })
        #expect(count == 0)
    }
}
