import Foundation
@testable import MumbleKit
import Testing

/// Against a real Mumble Video server: MUMBLE_TEST_SERVER=host:port swift test. Skipped otherwise.
@MainActor
struct LiveServerTests {
    nonisolated static let server: (String, UInt16)? = {
        guard let v = ProcessInfo.processInfo.environment["MUMBLE_TEST_SERVER"] else { return nil }
        let parts = v.split(separator: ":")
        return (String(parts[0]), parts.count > 1 ? UInt16(parts[1]) ?? 64738 : 64738)
    }()

    @Test(.enabled(if: server != nil)) func connectsSyncsAndVerifiesUDP() async throws {
        let (host, port) = try #require(Self.server)
        let client = MumbleClient()
        let name = "ios-test-\(Int.random(in: 1000 ... 9999))"
        client.connect(ConnectRequest(host: host, port: port, username: name))

        // Self-signed test server: accept its certificate once, as the user would.
        try await waitFor(10) {
            if case .certificateTrustRequired = client.state.connection { return true }
            return client.state.connection.isConnected
        }
        if case let .certificateTrustRequired(cert) = client.state.connection {
            #expect(cert.sha256.count == 64)
            client.trust(cert)
        }
        try await waitFor(15) { client.state.connection.isConnected }

        let s = client.state.server
        #expect(s.selfSession != nil)
        #expect(s.channels[.root] != nil)
        #expect(s.selfUser?.name == name)

        try await waitFor(10) { client.state.capabilities.known }
        #expect(client.state.capabilities.video)

        try await waitFor(15) { client.state.udpActive }
        #expect((client.state.udpPingMs ?? 999) < 500)

        client.sendMessage("hello from the iOS client test", to: .channel(s.selfUser!.channel))
        try await waitFor(5) { client.state.messages.contains { $0.isOwn } }

        client.disconnect()
        try await waitFor(5) { if case .disconnected = client.state.connection { true } else { false } }
    }

    /// Two clients in the same channel: one speaks (Opus through mumble-core's makeAudio, over UDP once
    /// verified), the other must receive the packets back through the server and mumble-core's decrypt.
    @Test(.enabled(if: server != nil)) func voiceReachesAnotherClient() async throws {
        let (host, port) = try #require(Self.server)
        let speaker = MumbleClient(), listener = MumbleClient()
        let sink = CountingSink()
        listener.media = sink
        for (client, name) in [(speaker, "ios-speaker"), (listener, "ios-listener")] {
            client.connect(ConnectRequest(host: host, port: port, username: "\(name)-\(Int.random(in: 1000 ... 9999))"))
            try await waitFor(10) {
                if case .certificateTrustRequired = client.state.connection { return true }
                return client.state.connection.isConnected
            }
            if case let .certificateTrustRequired(cert) = client.state.connection { client.trust(cert) }
            try await waitFor(15) { client.state.connection.isConnected }
            try await waitFor(15) { client.state.udpActive }
        }
        #expect(speaker.state.server.selfUser?.channel == listener.state.server.selfUser?.channel)

        let enc = try #require(VoiceEncoder())
        enc.mode = .continuous
        enc.onPacket = { opus, frame, last in speaker.sendAudio(opus: opus, frameNumber: frame, isLast: last) }
        for n in 0 ..< 50 { // one second of tone
            enc.feed((0 ..< 960).map { i in Int16(8000 * sin(Double(n * 960 + i) * 2 * .pi * 440 / 48000)) })
            try await Task.sleep(for: .milliseconds(20))
        }
        // Other clients may be talking on a shared test server; count only ours.
        let fromSpeaker = speaker.state.server.selfSession!.raw
        try await waitFor(5) { sink.packets.filter { $0.senderSession == fromSpeaker }.count >= 40 }
        #expect(sink.senders.contains(fromSpeaker))

        // Decoded, it is still a tone.
        let mixer = VoiceMixer()
        for p in sink.packets where p.senderSession == fromSpeaker { mixer.push(p) }
        let loud = (0 ..< 20).map { _ in mixer.mixFrame().map { abs(Int($0)) }.max() ?? 0 }.max() ?? 0
        #expect(loud > 3000)

        speaker.disconnect()
        listener.disconnect()
    }
}

final class CountingSink: MediaSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _packets: [AudioPacket] = []
    var packets: [AudioPacket] { lock.withLock { _packets } }
    var count: Int { packets.count }
    var senders: Set<UInt32> { Set(packets.map(\.senderSession)) }
    func audio(_ packet: AudioPacket) { lock.withLock { _packets.append(packet) } }
    func video(_ unit: VideoUnit) {}
    func senderRemoved(_ session: UserSession) {}
}

@MainActor
func waitFor(_ seconds: Double, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { throw TimeoutError() }
        try await Task.sleep(for: .milliseconds(100))
    }
}

struct TimeoutError: Error {}
