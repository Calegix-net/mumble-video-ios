import CoreGraphics
import Foundation
import MumbleKit
import Observation

struct SavedServer: Codable, Identifiable, Hashable {
    var id = UUID()
    var label: String
    var host: String
    var port: UInt16 = 64738
    var username: String
    var trustedSHA256: String?
}

/// The app's one session: client, audio and video, plus what the UI needs that the client does not keep
/// (saved servers, who is talking, the latest picture of each watched stream).
@MainActor @Observable
final class AppModel {
    let client: MumbleClient
    var state: ClientState { client.state }
    let video = VideoReceiver()
    let mixer = VoiceMixer()
    private let hub: MediaHub
    private var voice: VoiceEngine?

    var servers: [SavedServer] = []
    var current: SavedServer?
    var talking: Set<UInt32> = []
    var selfTalking = false
    var frames: [StreamKey: CGImage] = [:]
    var watching: Set<StreamKey> = []
    var pushToTalk = false { didSet { voice?.encoder.mode = pushToTalk ? .pushToTalk : .voiceActivity(threshold: 0.02) } }
    var muted = false
    var deafened = false
    var audioError: String?

    /// Our camera stream, and a small picture of it for the user.
    private(set) var sendingCamera = false
    private(set) var cameraPreview: CGImage?
    private(set) var cameraIsTestPattern = false
    private var camera: CameraSource?
    private var cameraSender: VideoSender?
    /// Screen sharing through the broadcast extension; nil where there is no App Group (Simulator).
    private(set) var sharingScreen = false
    private(set) var screenShareAvailable = false
    private var screen: ScreenShareHost?

    private var talkTimer: Timer?

    init() {
        client = MumbleClient()
        hub = MediaHub(mixer: mixer, video: video)
        client.media = hub
        servers = Self.loadServers()
        video.onFrame = { [weak self] key, image in
            DispatchQueue.main.async { self?.frames[key] = image }
        }
        let client = client
        video.onKeyframeNeeded = { key in client.requestKeyframe(key) }
        client.onKeyframeRequested = { [weak self] id in
            DispatchQueue.main.async {
                self?.cameraSender?.keyframeRequested(streamID: id)
                self?.screen?.keyframeRequested(streamID: id)
            }
        }
    }

    // MARK: Connection

    func connect(_ server: SavedServer) {
        current = server
        var r = ConnectRequest(host: server.host, port: server.port, username: server.username)
        r.trustedCertificateSHA256 = server.trustedSHA256
        client.connect(r)
        startAudio()
        startScreenShareHost()
    }

    func trust(_ cert: CertificateInfo) {
        guard var s = current else { return }
        s.trustedSHA256 = cert.sha256
        save(s)
        current = s
        client.trust(cert)
    }

    func disconnect() {
        stopCamera()
        screen?.shutdown()
        screen = nil
        screenShareAvailable = false
        client.disconnect()
        voice?.stop()
        voice = nil
        talkTimer?.invalidate()
        frames = [:]
        watching = []
    }

    private func startAudio() {
        guard voice == nil, let engine = VoiceEngine(client: client, mixer: mixer) else { return }
        voice = engine
        engine.encoder.mode = pushToTalk ? .pushToTalk : .voiceActivity(threshold: 0.02)
        do {
            if try !engine.start(capture: true) { audioError = "No microphone: listening only" }
        } catch {
            audioError = error.localizedDescription
        }
        talkTimer?.invalidate()
        talkTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.talking = self.mixer.talking()
                self.selfTalking = self.voice?.encoder.isTalking ?? false
            }
        }
    }

    /// mumble://[user@]host[:port][/channel], as every Mumble client handles: connect, saving the server.
    func open(_ url: URL) {
        guard url.scheme == "mumble", let host = url.host(), !host.isEmpty else { return }
        let port = UInt16(url.port ?? 64738)
        let user = url.user(percentEncoded: false) ?? "iPhone"
        var server = servers.first { $0.host == host && $0.port == port && $0.username == user }
            ?? SavedServer(label: host, host: host, port: port, username: user)
        server.username = user
        save(server)
        if model(isConnectedTo: server) { return }
        connect(server)
    }

    private func model(isConnectedTo s: SavedServer) -> Bool {
        current?.id == s.id && state.connection.isConnected
    }

    // MARK: Voice

    func toggleMute() {
        muted.toggle()
        if !muted { deafened = false }
        applyVoice()
    }

    func toggleDeafen() {
        deafened.toggle()
        if deafened { muted = true }
        applyVoice()
    }

    func setPushToTalk(pressed: Bool) {
        voice?.encoder.pushToTalkPressed = pressed
    }

    private func applyVoice() {
        voice?.encoder.muted = muted
        mixer.deafened = deafened
        client.setSelf(muted: muted, deafened: deafened)
    }

    // MARK: Video

    func watch(_ stream: RemoteVideoStream) {
        guard !watching.contains(stream.key) else { return }
        watching.insert(stream.key)
        video.watch(stream)
        client.subscribe(stream.key)
    }

    func stopWatching(_ key: StreamKey) {
        watching.remove(key)
        video.stop(key)
        client.unsubscribe(key)
        frames[key] = nil
    }

    // MARK: Sending video

    func startCamera() {
        guard !sendingCamera, state.capabilities.video, state.udpActive else { return }
        let source = makeCameraSource()
        let sender = VideoSender(client: client, codec: .vp8, source: .camera, name: "iPhone camera", fps: 30, bitrate: 800_000)
        source.onFrame = Self.cameraPipeline(sender: sender) { [weak self] image in self?.cameraPreview = image }
        camera = source
        cameraSender = sender
        cameraIsTestPattern = source is TestPatternCamera
        sendingCamera = true
        source.start()
    }

    /// Every picture to the encoder; every third one, as an image, to the preview on the main thread.
    nonisolated private static func cameraPipeline(sender: VideoSender, preview: @escaping @MainActor (CGImage) -> Void)
        -> @Sendable (I420Frame, UInt64) -> Void {
        let count = Counter()
        return { frame, t in
            sender.send(frame, timestampUsec: t)
            guard count.next() % 3 == 0, let image = frame.cgImage() else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { preview(image) } }
        }
    }

    func stopCamera() {
        camera?.onFrame = nil
        camera?.stop()
        cameraSender?.stop()
        camera = nil
        cameraSender = nil
        cameraPreview = nil
        sendingCamera = false
    }

    func switchCamera() { camera?.switchCamera() }

    func stopScreenShare() { screen?.stopSharing() }

    private func startScreenShareHost() {
        screen?.shutdown()
        guard let host = ScreenShareHost() else {
            screen = nil
            screenShareAvailable = false
            return
        }
        host.onSharingChanged = { [weak self] on in self?.sharingScreen = on }
        host.start(client: client)
        screen = host
        screenShareAvailable = true
    }

    // MARK: Saved servers

    func save(_ server: SavedServer) {
        if let i = servers.firstIndex(where: { $0.id == server.id }) {
            servers[i] = server
        } else {
            servers.append(server)
        }
        persist()
    }

    func delete(_ server: SavedServer) {
        servers.removeAll { $0.id == server.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(servers) { UserDefaults.standard.set(data, forKey: "servers") }
    }

    private static func loadServers() -> [SavedServer] {
        guard let data = UserDefaults.standard.data(forKey: "servers"),
              let list = try? JSONDecoder().decode([SavedServer].self, from: data) else { return [] }
        return list
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { defer { n += 1 }; return n } }
}
