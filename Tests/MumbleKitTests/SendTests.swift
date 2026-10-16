import CoreGraphics
import CoreVideo
import Foundation
@testable import MumbleKit
@testable import MumbleShare
import Testing

/// A media session keyed with a fixed key, ready to make video datagrams.
func keyedSession() -> MediaSession {
    let session = MediaSession()
    var setup = MumbleProto_CryptSetup()
    setup.key = Data(repeating: 7, count: 16)
    setup.clientNonce = Data(repeating: 1, count: 16)
    setup.serverNonce = Data(repeating: 2, count: 16)
    session.cryptSetup(try! setup.serializedBytes())
    return session
}

func unit(stream: UInt32 = 1, frame: UInt64 = 0, size: Int) -> VideoUnit {
    VideoUnit(senderSession: 0, streamID: stream, frameNumber: frame, unitID: 0, isKeyframe: true, isFrameEnd: true, captureTimestampUsec: 0,
              x: 0, y: 0, width: 64, height: 48, payload: Data((0 ..< size).map { UInt8($0 & 0xff) }))
}

struct UnitLimitTests {
    /// The size worked out in Swift is exactly mumble-core's: a unit of that size fragments into the full
    /// 256 datagrams, one byte more is refused.
    @Test func maxUnitSizeMatchesTheCore() {
        let session = keyedSession()
        #expect(VideoUnits.maxUnitSize > 250_000)
        let full = session.makeVideo(unit(size: VideoUnits.maxUnitSize))
        #expect(full.count == 256)
        #expect(full.allSatisfy { $0.count <= 1200 })
        #expect(session.makeVideo(unit(size: VideoUnits.maxUnitSize + 1)).isEmpty)
    }

    @Test func splitsH264LikeTheDesktop() {
        let au = Data((0 ..< 2500).map { UInt8($0 & 0xff) })
        let units = VideoUnits.splitH264(au, streamID: 7, frameNumber: 42, timestampUsec: 1000, isKeyframe: true, width: 1920, height: 1080,
                                         maxUnitSize: 1000)
        #expect(units.map(\.payload.count) == [1000, 1000, 500])
        #expect(units.map(\.x) == [0, 1, 2])
        #expect(units.allSatisfy { $0.y == 3 && $0.frameNumber == 42 && $0.isKeyframe && $0.width == 1920 })
        #expect(units.map(\.isFrameEnd) == [false, false, true])
        #expect(units.map(\.unitID) == [0, 1, 2])
        #expect(units.reduce(Data()) { $0 + $1.payload } == au)
        // More than 32 parts: not sent at all.
        #expect(VideoUnits.splitH264(Data(count: 33 * 10), streamID: 0, frameNumber: 0, timestampUsec: 0, isKeyframe: true,
                                     width: 1, height: 1, maxUnitSize: 10).isEmpty)
        // And a receiver joins them back.
        let a = FrameAssembler(codec: .h264)
        var joined: Data?
        for u in units.reversed() { joined = a.add(u).frame?.data ?? joined }
        #expect(joined == au)
    }
}

struct ResendTests {
    func nack(stream: UInt32, frame: UInt64, missing: UInt64 = 0, indices: [UInt32] = []) -> MumbleUDP_VideoNack {
        var n = MumbleUDP_VideoNack()
        n.streamID = stream
        var u = MumbleUDP_VideoNack.Unit()
        u.frameNumber = frame
        u.unitID = 0
        u.missingFragments = missing
        u.missingIndices = indices
        n.units = [u]
        return n
    }

    @Test func answersWithTheFragmentsAskedFor() throws {
        let session = keyedSession()
        let h = VideoResendHistory()
        let sent = unit(stream: 4, frame: 9, size: 3000) // three fragments
        let original = session.makeVideo(sent)
        #expect(original.count == 3)
        h.record(sent, nowUsec: 1_000)

        let some = h.answer(nack(stream: 4, frame: 9, missing: 0b101), nowUsec: 2_000, encrypt: session.makeVideo)
        #expect(some.count == 2)
        #expect(some.map(\.count) == [original[0].count, original[2].count])
        #expect(some[0] != original[0]) // encrypted again under a new sequence number, not a replay

        #expect(h.answer(nack(stream: 4, frame: 9, indices: [1, 99]), nowUsec: 2_000, encrypt: session.makeVideo).count == 1)
        #expect(h.answer(nack(stream: 4, frame: 9), nowUsec: 2_000, encrypt: session.makeVideo).count == 3) // 0: all of it
        #expect(h.answer(nack(stream: 4, frame: 8), nowUsec: 2_000, encrypt: session.makeVideo).isEmpty) // never sent
        #expect(h.answer(nack(stream: 5, frame: 9), nowUsec: 2_000, encrypt: session.makeVideo).isEmpty) // another stream
        #expect(h.fragmentsResent == 6)

        h.forget(stream: 4)
        #expect(h.answer(nack(stream: 4, frame: 9), nowUsec: 2_000, encrypt: session.makeVideo).isEmpty)
    }

    @Test func forgetsAfterASecond() {
        let session = keyedSession()
        let h = VideoResendHistory()
        h.record(unit(frame: 1, size: 100), nowUsec: 0)
        h.record(unit(frame: 2, size: 100), nowUsec: 1_500_000) // evicts frame 1
        #expect(h.answer(nack(stream: 1, frame: 1), nowUsec: 1_500_000, encrypt: session.makeVideo).isEmpty)
        #expect(h.answer(nack(stream: 1, frame: 2), nowUsec: 1_500_000, encrypt: session.makeVideo).count == 1)
    }

    @Test func capsResendsAtOneMegabytePerSecond() {
        let session = keyedSession()
        let h = VideoResendHistory()
        for f in 0 ..< 8 { h.record(unit(frame: UInt64(f), size: 200_000), nowUsec: 0) }
        var n = MumbleUDP_VideoNack()
        n.streamID = 1
        n.units = (0 ..< 8).map { f in var u = MumbleUDP_VideoNack.Unit(); u.frameNumber = UInt64(f); return u }
        let out = h.answer(n, nowUsec: 10, encrypt: session.makeVideo)
        let bytes = out.reduce(0) { $0 + $1.count }
        #expect(bytes <= VideoResendHistory.maxResendBytesPerSecond)
        #expect(bytes > VideoResendHistory.maxResendBytesPerSecond - 2 * 1200)
        // A new second, a new budget.
        #expect(!h.answer(n, nowUsec: 1_100_000, encrypt: session.makeVideo).isEmpty)
    }
}

struct PixelConversionTests {
    func buffer(_ format: OSType, width: Int, height: Int, fill: (UnsafeMutableRawPointer, Int, Int) -> Void) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, format, nil, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        if CVPixelBufferIsPlanar(pb!) {
            for p in 0 ..< CVPixelBufferGetPlaneCount(pb!) {
                fill(CVPixelBufferGetBaseAddressOfPlane(pb!, p)!, CVPixelBufferGetBytesPerRowOfPlane(pb!, p) * CVPixelBufferGetHeightOfPlane(pb!, p), p)
            }
        } else {
            fill(CVPixelBufferGetBaseAddress(pb!)!, CVPixelBufferGetDataSize(pb!), 0)
        }
        CVPixelBufferUnlockBaseAddress(pb!, [])
        return pb!
    }

    @Test func nv12VideoRangeIsCopied() throws {
        let pb = buffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width: 64, height: 48) { p, n, plane in
            if plane == 0 { memset(p, 81, n) } else {
                let b = p.assumingMemoryBound(to: UInt8.self)
                for i in stride(from: 0, to: n, by: 2) { b[i] = 90; b[i + 1] = 240 }
            }
        }
        let f = try #require(I420Frame(pixelBuffer: pb))
        #expect(f.width == 64 && f.height == 48)
        #expect(f.y.allSatisfy { $0 == 81 } && f.u.allSatisfy { $0 == 90 } && f.v.allSatisfy { $0 == 240 })
        let (r, g, b) = pixel(try #require(f.cgImage()), 10, 10)
        #expect(r > 200 && g < 60 && b < 60)
    }

    @Test func bgraBecomesTheSameColour() throws {
        let pb = buffer(kCVPixelFormatType_32BGRA, width: 63, height: 47) { p, n, _ in
            let b = p.assumingMemoryBound(to: UInt8.self)
            for i in stride(from: 0, to: n, by: 4) { b[i] = 20; b[i + 1] = 30; b[i + 2] = 230; b[i + 3] = 255 } // B G R A
        }
        let f = try #require(I420Frame(pixelBuffer: pb))
        #expect(f.width == 62 && f.height == 46) // trimmed to even
        let (r, g, b) = pixel(try #require(f.cgImage()), 10, 10)
        #expect(abs(r - 230) < 12 && abs(g - 30) < 12 && abs(b - 20) < 12)
    }
}

struct H264SendTests {
    /// The broadcast extension's path, offline: VideoToolbox H.264, split into units, joined and decoded
    /// by the receiving side's decoder.
    @Test func encodesSplitsAndDecodes() throws {
        let w = 640, h = 360
        let enc = try #require(H264Encoder(width: w, height: h, fps: 30, bitrate: 1_000_000))
        let assembler = FrameAssembler(codec: .h264)
        let dec = H264FrameDecoder()
        var image: CGImage?
        var keyframes = 0
        for n in 0 ..< 10 {
            let pb = PixelConversionTests().buffer(kCVPixelFormatType_32BGRA, width: w, height: h) { p, size, _ in
                let b = p.assumingMemoryBound(to: UInt8.self)
                for i in stride(from: 0, to: size, by: 4) { b[i] = 20; b[i + 1] = 30; b[i + 2] = 230; b[i + 3] = 255 }
                for i in stride(from: (n * 16) * 4, to: size, by: w * 4) { b[i] = 255; b[i + 1] = 255; b[i + 2] = 255 } // a moving line
            }
            for f in enc.encode(pb, timestampUsec: UInt64(n) * 33_333) {
                if f.isKeyframe {
                    keyframes += 1
                    #expect(f.data.prefix(4) == Data([0, 0, 0, 1]) && f.data.dropFirst(4).first.map { $0 & 0x1f } == 7) // SPS first
                }
                for u in VideoUnits.splitH264(f.data, streamID: 1, frameNumber: UInt64(n), timestampUsec: f.timestampUsec,
                                              isKeyframe: f.isKeyframe, width: w, height: h, maxUnitSize: 700) {
                    if let frame = assembler.add(u).frame { image = dec.decode(frame) ?? image }
                }
            }
        }
        #expect(keyframes >= 1)
        let img = try #require(image)
        #expect(img.width == w && img.height == h)
        let (r, g, b) = pixel(img, 600, 300)
        #expect(r > 180 && g < 80 && b < 80)
    }
}

struct BroadcastChannelTests {
    @Test func messagesSurviveTheSocket() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mvb-\(Int.random(in: 1000 ... 9999))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try #require(BroadcastChannel.socketPath(directory: dir))
        let listener = try #require(BroadcastListener(path: path))
        let atApp = MessageLog(), atExtension = MessageLog()
        let accepted = ConnectionBox()
        listener.onConnection = { c in
            c.onMessage = { atApp.add($0) }
            c.start()
            accepted.set(c)
        }
        listener.start()

        let ext = try #require(BroadcastConnection.connect(path: path))
        ext.onMessage = { atExtension.add($0) }
        ext.start()
        let big = H264Frame(data: Data((0 ..< 400_000).map { UInt8($0 % 251) }), isKeyframe: true, width: 1280, height: 590, timestampUsec: 123_456_789)
        ext.send(.frame(big))
        ext.send(.frame(H264Frame(data: Data([1, 2, 3]), isKeyframe: false, width: 1280, height: 590, timestampUsec: 5)))
        ext.send(.ended)
        try await waitUntil { atApp.count == 3 }
        #expect(atApp.all == [.frame(big), .frame(H264Frame(data: Data([1, 2, 3]), isKeyframe: false, width: 1280, height: 590, timestampUsec: 5)), .ended])
        if case let .frame(f) = atApp.all[0] { #expect(f.timestampUsec == 123_456_789) }

        let app = try #require(accepted.get())
        app.send(.configure(bitrate: 2_000_000))
        app.send(.keyframe)
        app.send(.stop)
        try await waitUntil { atExtension.count == 3 }
        #expect(atExtension.all == [.configure(bitrate: 2_000_000), .keyframe, .stop])

        let closed = MessageLog()
        app.onClose = { closed.add(.ended) }
        ext.close()
        try await waitUntil { closed.count == 1 }
        listener.stop()
    }

    @Test func parsesAcrossPartialReads() {
        let bytes = BroadcastMessage.keyframe.encoded() + BroadcastMessage.configure(bitrate: 7).encoded()
        var buffer = Data(bytes.prefix(6))
        #expect(BroadcastMessage.parse(&buffer) == [.keyframe])
        buffer += bytes.dropFirst(6)
        #expect(BroadcastMessage.parse(&buffer) == [.configure(bitrate: 7)])
        #expect(buffer.isEmpty)
    }
}

final class MessageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [BroadcastMessage] = []
    func add(_ m: BroadcastMessage) { lock.withLock { items.append(m) } }
    var all: [BroadcastMessage] { lock.withLock { items } }
    var count: Int { all.count }
}

final class ConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var c: BroadcastConnection?
    func set(_ v: BroadcastConnection) { lock.withLock { c = v } }
    func get() -> BroadcastConnection? { lock.withLock { c } }
}

func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { throw TimeoutError() }
        try await Task.sleep(for: .milliseconds(20))
    }
}

struct AppGroupTests {
    @Test func findsTheGroupAfterSideloading() {
        #expect(BroadcastChannel.appGroupCandidates(info: [:], bundleID: "com.calegix.mumblevideo.ios") == ["group.com.calegix.mumblevideo"])
        // A tool that suffixed the bundle id (team id), seen from the app and from the extension.
        let suffixed = ["group.com.calegix.mumblevideo", "group.com.calegix.mumblevideo.ABCDE12345"]
        #expect(BroadcastChannel.appGroupCandidates(info: [:], bundleID: "com.calegix.mumblevideo.ios.ABCDE12345") == suffixed)
        #expect(BroadcastChannel.appGroupCandidates(info: [:], bundleID: "com.calegix.mumblevideo.ios.ABCDE12345.broadcast") == suffixed)
        // AltStore says where it put it.
        #expect(BroadcastChannel.appGroupCandidates(info: ["ALTAppGroups": ["group.x.Y"]], bundleID: "other").first == "group.x.Y")
    }
}
