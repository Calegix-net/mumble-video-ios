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
