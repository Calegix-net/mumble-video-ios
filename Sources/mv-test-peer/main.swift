import Foundation
import MumbleKit

// A scripted peer for trying the app: joins a server, speaks a tone and streams a synthetic VP8 picture
// (a moving bar on a coloured field) so there is someone to hear and something to watch.
//
//   swift run mv-test-peer host:port [seconds] [--sha256 HEX]
//
// Without --sha256 it trusts whatever certificate the server presents (it is a test tool).

let args = CommandLine.arguments.dropFirst()
guard let target = args.first else {
    print("usage: mv-test-peer host:port [seconds] [--sha256 HEX]")
    exit(2)
}
let parts = target.split(separator: ":")
let host = String(parts[0])
let port = parts.count > 1 ? UInt16(parts[1]) ?? 64738 : 64738
let seconds = args.dropFirst().first.flatMap { Double($0) } ?? 60

@MainActor
func run() async {
    let client = MumbleClient()
    client.connect(ConnectRequest(host: host, port: port, username: "test-peer"))
    func waitFor(_ s: Double, _ c: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(s)
        while !c() { if Date() > end { return false }; try? await Task.sleep(for: .milliseconds(100)) }
        return true
    }
    _ = await waitFor(10) { if case .certificateTrustRequired = client.state.connection { true } else { client.state.connection.isConnected } }
    if case let .certificateTrustRequired(cert) = client.state.connection { client.trust(cert) }
    guard await waitFor(15, { client.state.connection.isConnected && client.state.udpActive && client.state.capabilities.known }) else {
        print("could not connect: \(client.state.connection)")
        exit(1)
    }
    print("connected as test-peer; video \(client.state.capabilities.video)")

    let width = 640, height = 360
    let wantKey = Flag()
    client.onKeyframeRequested = { _ in wantKey.set() }
    client.announceVideo(streamID: 1, codec: .vp8, source: .camera, name: "Test pattern", width: UInt32(width), height: UInt32(height),
                         fps: 30, bitrate: 800_000)
    guard let enc = VP8Encoder(width: width, height: height), let voice = VoiceEncoder() else { exit(1) }
    voice.mode = .continuous
    voice.onPacket = { opus, frame, last in client.sendAudio(opus: opus, frameNumber: frame, isLast: last) }

    let frames = Int(seconds * 30)
    for n in 0 ..< frames {
        // ~33 ms per video frame; voice wants 20 ms packets, so feed 1600 samples (33.3 ms) of tone.
        voice.feed((0 ..< 1600).map { i in Int16(5000 * sin(Double(n * 1600 + i) * 2 * .pi * 330 / 48000)) })
        let picture = pattern(width: width, height: height, t: n)
        for (data, key) in enc.encode(picture, pts: Int64(n), forceKeyframe: n == 0 || wantKey.take()) {
            client.sendVideo(VideoUnit(senderSession: 0, streamID: 1, frameNumber: UInt64(n), unitID: 0, isKeyframe: key, isFrameEnd: true,
                                       captureTimestampUsec: UInt64(n) * 33_333, x: 0, y: 0, width: UInt32(width), height: UInt32(height), payload: data))
        }
        try? await Task.sleep(for: .milliseconds(33))
    }
    client.endVideo(streamID: 1)
    try? await Task.sleep(for: .milliseconds(300))
    client.disconnect()
}

func pattern(width: Int, height: Int, t: Int) -> I420Frame {
    var y = Data(repeating: 110, count: width * height)
    let bar = (t * 6) % width
    for row in 0 ..< height {
        for col in max(0, bar - 20) ..< min(width, bar + 20) { y[row * width + col] = 230 }
    }
    let c = ((width + 1) / 2) * ((height + 1) / 2)
    return I420Frame(width: width, height: height, y: y, u: Data(repeating: 160, count: c), v: Data(repeating: 90, count: c))
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    func set() { lock.withLock { on = true } }
    func take() -> Bool { lock.withLock { defer { on = false }; return on } }
}

await run()
