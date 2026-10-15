import CoreGraphics
import ImageIO
import CoreVideo
import Foundation
@testable import MumbleKit
import MumbleShare
import Testing

/// Sending through VideoSender against a live server (MUMBLE_TEST_SERVER), watched by a second client.
@MainActor
struct LiveSendTests {
    func connectPair() async throws -> (MumbleClient, MumbleClient) {
        let (host, port) = try #require(LiveServerTests.server)
        let sender = MumbleClient(), watcher = MumbleClient()
        for (client, name) in [(sender, "ios-send"), (watcher, "ios-view")] {
            client.connect(ConnectRequest(host: host, port: port, username: "\(name)-\(Int.random(in: 1000 ... 9999))"))
            try await waitFor(10) {
                if case .certificateTrustRequired = client.state.connection { return true }
                return client.state.connection.isConnected
            }
            if case let .certificateTrustRequired(cert) = client.state.connection { client.trust(cert) }
            try await waitFor(15) { client.state.connection.isConnected && client.state.udpActive && client.state.capabilities.known }
        }
        return (sender, watcher)
    }

    /// The camera path: VP8 from I420 pictures. The watcher decodes the right colour; when the picture
    /// changes size (the phone turned) a new stream replaces the old one.
    @Test(.enabled(if: LiveServerTests.server != nil)) func cameraStreamAndRotation() async throws {
        let (client, watcher) = try await connectPair()
        let receiver = VideoReceiver()
        let hub = MediaHub(mixer: VoiceMixer(), video: receiver)
        watcher.media = hub
        let sender = VideoSender(client: client, codec: .vp8, source: .camera, name: "Test camera", bitrate: 600_000)
        client.onKeyframeRequested = { id in sender.keyframeRequested(streamID: id) }
        let me = try #require(client.state.server.selfSession).raw
        let frames = FrameCollector()
        receiver.onFrame = { _, img in frames.add(img) }
        receiver.onKeyframeNeeded = { k in watcher.requestKeyframe(k) }

        func run(width: Int, height: Int, frames count: Int, from start: Int) async throws {
            for n in start ..< start + count {
                sender.send(testFrame(width: width, height: height, y: 81, u: 90, v: 240, bar: n), timestampUsec: UInt64(n) * 33_334)
                try await Task.sleep(for: .milliseconds(33))
            }
        }
        func watchOurStream(width: UInt32) async throws -> StreamKey {
            try await waitFor(5) { watcher.state.videoStreams.contains { $0.key.session == me && $0.width == width } }
            let s = try #require(watcher.state.videoStreams.first { $0.key.session == me && $0.width == width })
            #expect(s.codec == .vp8 && s.source == .camera && s.sourceName == "Test camera")
            receiver.watch(s)
            watcher.subscribe(s.key)
            return s.key
        }

        try await run(width: 320, height: 240, frames: 1, from: 0) // announces the stream
        let first = try await watchOurStream(width: 320)
        try await run(width: 320, height: 240, frames: 45, from: 1)
        try await waitFor(5) { frames.count >= 15 }
        #expect(frames.last?.width == 320)

        try await run(width: 240, height: 320, frames: 1, from: 46) // turned to portrait
        try await waitFor(5) { !watcher.state.videoStreams.contains { $0.key == first } }
        let second = try await watchOurStream(width: 240)
        #expect(second.streamID != first.streamID)
        let before = frames.count
        try await run(width: 240, height: 320, frames: 45, from: 47)
        try await waitFor(5) { frames.count >= before + 15 }
        let img = try #require(frames.last)
        #expect(img.width == 240 && img.height == 320)
        let (r, g, b) = pixel(img, 200, 160)
        #expect(r > 200 && g < 60 && b < 60)
        #expect(sender.framesDropped == 0)

        sender.stop()
        try await waitFor(5) { !watcher.state.videoStreams.contains { $0.key.session == me } }
        client.disconnect()
        watcher.disconnect()
        withExtendedLifetime(hub) {}
    }

    /// The screen path: H.264 encoded elsewhere (as the broadcast extension does) and sent pre-encoded.
    /// A keyframe request from the watcher reaches the encoder through onKeyframeNeeded.
    @Test(.enabled(if: LiveServerTests.server != nil)) func screenStreamAsH264() async throws {
        let (client, watcher) = try await connectPair()
        let receiver = VideoReceiver()
        let hub = MediaHub(mixer: VoiceMixer(), video: receiver)
        watcher.media = hub
        let w = 1280, h = 590
        let enc = try #require(H264Encoder(width: w, height: h, fps: 30, bitrate: 2_000_000))
        let sender = VideoSender(client: client, codec: .h264, source: .display, name: "Test screen", bitrate: 2_000_000)
        let asked = Counter()
        sender.onKeyframeNeeded = { asked.next(); enc.requestKeyframe() }
        client.onKeyframeRequested = { id in sender.keyframeRequested(streamID: id) }
        let me = try #require(client.state.server.selfSession).raw
        let frames = FrameCollector()
        receiver.onFrame = { _, img in frames.add(img) }
        receiver.onKeyframeNeeded = { k in watcher.requestKeyframe(k) }

        var subscribed = false
        for n in 0 ..< 90 {
            let pb = PixelConversionTests().buffer(kCVPixelFormatType_32BGRA, width: w, height: h) { p, size, _ in
                let b = p.assumingMemoryBound(to: UInt8.self)
                for i in stride(from: 0, to: size, by: 4) { b[i] = 230; b[i + 1] = 60; b[i + 2] = 20; b[i + 3] = 255 } // blue
                for i in stride(from: (n * 12 % w) * 4, to: size, by: w * 4) { b[i] = 255; b[i + 1] = 255; b[i + 2] = 255 }
            }
            for f in enc.encode(pb, timestampUsec: UInt64(n) * 33_334) {
                sender.sendEncoded(f.data, isKeyframe: f.isKeyframe, width: f.width, height: f.height, timestampUsec: f.timestampUsec)
            }
            if !subscribed, n >= 10, let s = watcher.state.videoStreams.first(where: { $0.key.session == me }) {
                // Joins mid-stream, after the first keyframe: has to ask for one.
                #expect(s.codec == .h264 && s.source == .display && s.width == UInt32(w))
                receiver.watch(s)
                watcher.subscribe(s.key)
                subscribed = true
            }
            try await Task.sleep(for: .milliseconds(33))
        }
        #expect(subscribed)
        try await waitFor(5) { frames.count >= 20 }
        #expect(asked.next() >= 2) // the stream start, then the watcher's request
        let img = try #require(frames.last)
        #expect(img.width == w && img.height == h)
        let (r, g, b) = pixel(img, w - 20, h / 2)
        #expect(b > 180 && r < 80 && g < 100)

        sender.stop()
        client.disconnect()
        watcher.disconnect()
        withExtendedLifetime(hub) {}
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    @discardableResult func next() -> Int { lock.withLock { defer { n += 1 }; return n } }
}

/// A manual check of another client's stream (the app in the Simulator, a phone):
/// MUMBLE_TEST_SERVER=host:port MUMBLE_WATCH_USER=name MUMBLE_WATCH_PNG=/tmp/x.png swift test --filter watchesAUser
/// Watches that user's first stream for five seconds and saves the last picture.
@MainActor
struct WatchUserTool {
    nonisolated static let user = ProcessInfo.processInfo.environment["MUMBLE_WATCH_USER"]

    @Test(.enabled(if: LiveServerTests.server != nil && user != nil)) func watchesAUser() async throws {
        let (host, port) = try #require(LiveServerTests.server)
        let watcher = MumbleClient()
        let receiver = VideoReceiver()
        let hub = MediaHub(mixer: VoiceMixer(), video: receiver)
        watcher.media = hub
        watcher.connect(ConnectRequest(host: host, port: port, username: "ios-watch-\(Int.random(in: 1000 ... 9999))"))
        try await waitFor(10) {
            if case .certificateTrustRequired = watcher.state.connection { return true }
            return watcher.state.connection.isConnected
        }
        if case let .certificateTrustRequired(cert) = watcher.state.connection { watcher.trust(cert) }
        try await waitFor(15) { watcher.state.connection.isConnected && watcher.state.udpActive }
        let session = try #require(watcher.state.server.users.values.first { $0.name == Self.user }).id.raw
        try await waitFor(10) { watcher.state.videoStreams.contains { $0.key.session == session } }
        let stream = try #require(watcher.state.videoStreams.first { $0.key.session == session })
        print("stream \(stream.key): \(stream.codec) \(stream.source) \(stream.width)x\(stream.height) \"\(stream.sourceName)\"")
        let frames = FrameCollector()
        receiver.onFrame = { _, img in frames.add(img) }
        receiver.onKeyframeNeeded = { k in watcher.requestKeyframe(k) }
        receiver.watch(stream)
        watcher.subscribe(stream.key)
        try await Task.sleep(for: .seconds(5))
        print("decoded \(frames.count) pictures in 5 s")
        let img = try #require(frames.last)
        if let path = ProcessInfo.processInfo.environment["MUMBLE_WATCH_PNG"],
           let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
        watcher.disconnect()
        withExtendedLifetime(hub) {}
    }
}
