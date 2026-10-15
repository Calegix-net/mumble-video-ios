import Foundation
@testable import MumbleKit
import Testing

/// Exercise the native stack end to end: Swift → C bridge → mumble-core / Opus / libvpx.
struct NativeTests {
    @Test func coreAndCodecVersions() {
        #expect(!coreVersion.isEmpty)
        #expect(Opus.version.hasPrefix("libopus 1.5"))
    }

    /// mumble-core's own known-answer vectors (test-vectors/audio-datagram.json): keyed with the vector's key
    /// and its encrypt IV as our decrypt nonce, the session must authenticate every server datagram.
    @Test func decryptsAudioDatagramVectors() throws {
        let url = Bundle.module.url(forResource: "audio-datagram", withExtension: "json", subdirectory: "Resources")!
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let cases = doc["cases"] as! [[String: Any]]
        #expect(!cases.isEmpty)
        for c in cases {
            let session = MediaSession()
            let key = hex(c["key"] as! String)
            let serverIV = hex(c["encryptIv"] as! String)
            // CryptSetup { key = 1, client_nonce = 2, server_nonce = 3 }: our encrypt IV is arbitrary here.
            let setup = field(1, key) + field(2, Data(repeating: 0, count: 16)) + field(3, serverIV)
            #expect(session.cryptSetup(setup).ok)
            #expect(session.isKeyed)
            let datagrams = (c["datagrams"] as! [String]).map(hex)
            for d in datagrams {
                _ = session.receiveDatagram(d, nowUsec: 1)
            }
            #expect(session.stats.audioGood == UInt32(datagrams.count))
            #expect(session.stats.audioLost == 0)
        }
    }

    @Test func makesPingAndAudioOnceKeyed() {
        let session = MediaSession()
        #expect(session.makePing(timestamp: 1) == nil)
        let setup = field(1, Data(repeating: 7, count: 16)) + field(2, Data(repeating: 1, count: 16)) + field(3, Data(repeating: 2, count: 16))
        #expect(session.cryptSetup(setup).ok)
        let ping = session.makePing(timestamp: 42)
        #expect(ping?.first == 0) // audio channel byte
        let audio = session.makeAudio(opus: Data([1, 2, 3, 4]), frameNumber: 2, isLast: false)
        #expect((audio?.count ?? 0) > 4 + 4)
    }

    @Test func controlFramingRoundTrips() throws {
        let framed = ControlReader.frame(type: 11, payload: Data("hello".utf8))
        #expect(framed.count == 11)
        let reader = ControlReader()
        let first = try #require(reader.feed(framed.prefix(4)))
        #expect(first.isEmpty)
        let rest = try #require(reader.feed(framed.dropFirst(4)))
        #expect(rest.count == 1)
        #expect(rest[0].type == 11)
        #expect(rest[0].payload == Data("hello".utf8))
    }

    @Test func opusRoundTrips() throws {
        let encoder = try #require(Opus.Encoder(bitrate: 40_000))
        let decoder = try #require(Opus.Decoder())
        var loud = 0
        for frame in 0 ..< 20 {
            let pcm = (0 ..< Opus.frameSamples).map { i in Int16(8000 * sin(Double(frame * Opus.frameSamples + i) * 2 * .pi * 440 / 48000)) }
            let packet = try #require(encoder.encode(pcm))
            #expect(Opus.packetSamples(packet) == Opus.frameSamples)
            let out = decoder.decode(packet)
            #expect(out.count == Opus.frameSamples)
            loud = max(loud, out.map { abs(Int($0)) }.max() ?? 0)
        }
        #expect(loud > 2000)
        #expect(decoder.decode(nil).count == Opus.frameSamples)
    }

    @Test func vpxDecodersOpen() {
        #expect(VPXDecoder(codec: 8) != nil)
        #expect(VPXDecoder(codec: 9) != nil)
        #expect(VPXDecoder(codec: 8)?.decode(Data([0, 1, 2])) == nil)
    }
}

private func hex(_ s: String) -> Data {
    var d = Data()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        d.append(UInt8(s[i ..< j], radix: 16)!)
        i = j
    }
    return d
}

/// A length-delimited protobuf field (wire type 2) with a one-byte length.
private func field(_ number: UInt8, _ value: Data) -> Data {
    Data([number << 3 | 2, UInt8(value.count)]) + value
}
