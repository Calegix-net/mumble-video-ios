import Foundation
import Network
import Observation
import SwiftProtobuf

/// What the UI observes. Updated on the main thread, in the order the client produced the changes.
@MainActor @Observable
public final class ClientState {
    public internal(set) var connection: ConnectionState = .disconnected(reason: nil)
    public internal(set) var server = ServerState()
    public internal(set) var capabilities = ServerCapabilities()
    public internal(set) var messages: [ChatMessage] = []
    /// Round-trip times in milliseconds, nil until measured.
    public internal(set) var tcpPingMs: Double?
    public internal(set) var udpPingMs: Double?
    /// true once a UDP ping came back; voice then goes over UDP instead of the TCP tunnel.
    public internal(set) var udpActive = false
    public internal(set) var serverRelease: String = ""
    /// Streams other users are sending. Empty until the server's capabilities say it speaks video.
    public internal(set) var videoStreams: [RemoteVideoStream] = []

    public init() {}
}

/// Receives media the client decoded off the wire (voice for the audio engine, video units for decoders).
public protocol MediaSink: AnyObject, Sendable {
    func audio(_ packet: AudioPacket)
    func video(_ unit: VideoUnit)
    func senderRemoved(_ session: UserSession)
}

/// One connection to a Mumble Video server: the TLS control channel, the UDP media socket and the
/// mumble-core media session. All work happens on one serial queue; state is published to `state`.
public final class MumbleClient: @unchecked Sendable {
    public let state: ClientState
    public weak var media: MediaSink?

    private let queue = DispatchQueue(label: "mumble.client")
    private var request: ConnectRequest?
    private var link: TLSLink?
    private var reader = ControlReader()
    private var session = MediaSession()
    private var udp: NWConnection?
    private var server = ServerState()
    private var capabilities = ServerCapabilities()
    private var seenServerConfig = false
    private var serverVersionV2: UInt64 = 0
    private var serverRelease = ""
    private var timers: [DispatchSourceTimer] = []
    private var lastHeard = Date()
    private var udpVerified = false
    private var udpPingsUnanswered = 0
    private let started = DispatchTime.now()
    private var videoStreams: [StreamKey: RemoteVideoStream] = [:]
    private var lastKeyframeRequest: [StreamKey: Date] = [:]
    private var resendHistory = VideoResendHistory()
    /// Called on the client queue when a viewer asks for a keyframe of one of our streams.
    public var onKeyframeRequested: ((UInt32) -> Void)?
    /// Ids for our outgoing streams (VideoSender takes them from here).
    public let videoStreamIDs = VideoStreamIDs()

    @MainActor public init(state: ClientState = ClientState()) {
        self.state = state
    }

    // MARK: - Commands

    public func connect(_ request: ConnectRequest) {
        queue.async { [self] in
            teardown()
            self.request = request
            publish { $0.connection = .connecting; $0.server = ServerState(); $0.capabilities = ServerCapabilities(); $0.udpActive = false; $0.videoStreams = [] }
            let identity = request.identityPKCS12.flatMap(loadIdentity)
            link = TLSLink(host: request.host, port: request.port, identity: identity,
                           trustedSHA256: request.trustedCertificateSHA256, queue: queue) { [weak self] event in
                self?.handle(event)
            }
            link?.start()
        }
    }

    /// Accept the certificate the server presented and connect again.
    public func trust(_ cert: CertificateInfo) {
        queue.async { [self] in
            guard var r = request else { return }
            r.trustedCertificateSHA256 = cert.sha256
            connect(r)
        }
    }

    public func disconnect() {
        queue.async { [self] in
            teardown()
            publish { $0.connection = .disconnected(reason: nil) }
        }
    }

    public func joinChannel(_ id: ChannelID) {
        queue.async { [self] in
            guard let me = server.selfSession else { return }
            var m = MumbleProto_UserState()
            m.session = me.raw
            m.channelID = id.raw
            send(MumbleCoreType.userState, m)
        }
    }

    public func setSelf(muted: Bool, deafened: Bool) {
        queue.async { [self] in
            var m = MumbleProto_UserState()
            m.selfMute = muted || deafened
            m.selfDeaf = deafened
            send(MumbleCoreType.userState, m)
        }
    }

    public func sendMessage(_ body: String, to target: MessageTarget) {
        queue.async { [self] in
            var m = MumbleProto_TextMessage()
            m.message = body
            switch target {
            case let .channel(c): m.channelID = [c.raw]
            case let .tree(c): m.treeID = [c.raw]
            case let .user(u): m.session = [u.raw]
            }
            send(MumbleCoreType.textMessage, m)
            var own = ChatMessage(sender: server.selfSession, senderName: server.selfUser?.name ?? "", body: body, isOwn: true)
            if case let .channel(c) = target { own.channels = [c] }
            if case let .tree(c) = target { own.trees = [c] }
            if case let .user(u) = target { own.users = [u] }
            publish { $0.messages.appendBounded(own) }
        }
    }

    /// One Opus frame of our voice. Goes over UDP once verified, else through the TCP tunnel.
    public func sendAudio(opus: Data, frameNumber: UInt64, isLast: Bool, target: UInt32 = 0) {
        queue.async { [self] in
            guard let datagram = session.makeAudio(opus: opus, frameNumber: frameNumber, target: target, isLast: isLast) else { return }
            if udpVerified, let udp {
                udp.send(content: datagram, completion: .idempotent)
            } else {
                // The tunnel carries the UDP packet without the channel byte or the encryption.
                tunnel(opus: opus, frameNumber: frameNumber, target: target, isLast: isLast)
            }
        }
    }

    // MARK: - Video

    /// Start receiving a stream; asks the sender for a keyframe so decoding can begin.
    public func subscribe(_ key: StreamKey, preferredBandwidth: UInt32 = 0) {
        queue.async { [self] in
            lastKeyframeRequest[key] = Date()
            sendSubscribe(key, subscribe: true, keyframe: true, bandwidth: preferredBandwidth)
        }
    }

    public func unsubscribe(_ key: StreamKey) {
        queue.async { [self] in sendSubscribe(key, subscribe: false, keyframe: false, bandwidth: 0) }
    }

    /// Ask for a keyframe after unrecoverable loss; at most once a second per stream.
    public func requestKeyframe(_ key: StreamKey) {
        queue.async { [self] in
            if let last = lastKeyframeRequest[key], Date().timeIntervalSince(last) < 1 { return }
            lastKeyframeRequest[key] = Date()
            sendSubscribe(key, subscribe: true, keyframe: true, bandwidth: 0)
        }
    }

    private func sendSubscribe(_ key: StreamKey, subscribe: Bool, keyframe: Bool, bandwidth: UInt32) {
        var m = MumbleProto_VideoSubscribe()
        m.session = key.session
        m.streamID = key.streamID
        m.subscribe = subscribe
        if keyframe { m.requestKeyframe = true }
        if bandwidth > 0 { m.preferredBandwidth = bandwidth }
        send(MumbleCoreType.videoSubscribe, m)
    }

    /// Announce one of our streams (VideoState active). Every change of codec or size needs a new id.
    public func announceVideo(streamID: UInt32, codec: MumbleProto_VideoState.Codec, source: MumbleProto_VideoState.SourceKind,
                              name: String, width: UInt32, height: UInt32, fps: UInt32, bitrate: UInt32) {
        queue.async { [self] in
            var m = MumbleProto_VideoState()
            m.streamID = streamID
            m.active = true
            m.codec = codec
            m.sourceKind = source
            m.sourceName = name
            m.width = width
            m.height = height
            m.maxFramerate = fps
            m.targetBandwidth = bitrate
            send(MumbleCoreType.videoState, m)
        }
    }

    public func endVideo(streamID: UInt32) {
        queue.async { [self] in
            resendHistory.forget(stream: streamID)
            var m = MumbleProto_VideoState()
            m.streamID = streamID
            m.active = false
            send(MumbleCoreType.videoState, m)
        }
    }

    /// Send one unit of our stream. Video only goes over verified UDP. The unit is kept for a second in case
    /// a viewer asks for some of it again.
    public func sendVideo(_ unit: VideoUnit) {
        queue.async { [self] in
            guard udpVerified, let udp else { return }
            let datagrams = session.makeVideo(unit)
            guard !datagrams.isEmpty else { return }
            resendHistory.record(unit, nowUsec: nowUsec())
            for d in datagrams { udp.send(content: d, completion: .idempotent) }
        }
    }

    /// The server's capabilities as the client sees them now, from any thread but the client's queue.
    public var currentCapabilities: ServerCapabilities { queue.sync { capabilities } }

    /// Fragments re-sent in answer to viewers' VideoNacks, on this connection.
    public var videoFragmentsResent: Int { queue.sync { resendHistory.fragmentsResent } }

    private func answerNacks(_ nacks: [Data]) {
        guard udpVerified, let udp else { return }
        for bytes in nacks {
            guard let nack = try? MumbleUDP_VideoNack(serializedBytes: bytes) else { continue }
            for d in resendHistory.answer(nack, nowUsec: nowUsec(), encrypt: session.makeVideo) {
                udp.send(content: d, completion: .idempotent)
            }
        }
    }

    private func handleVideoState(_ m: MumbleProto_VideoState) {
        guard m.hasSession else { return }
        let key = StreamKey(session: m.session, streamID: m.streamID)
        if m.active {
            let source: VideoSourceKind = switch m.sourceKind {
            case .camera: .camera
            case .display: .display
            case .window: .window
            case .application: .application
            default: .unknown
            }
            videoStreams[key] = RemoteVideoStream(key: key, codec: VideoCodec(m.codec), source: source, sourceName: m.sourceName,
                                                  width: m.width, height: m.height, maxFramerate: m.maxFramerate)
        } else {
            videoStreams[key] = nil
            lastKeyframeRequest[key] = nil
        }
        publishVideo()
    }

    private func handleVideoSubscribe(_ m: MumbleProto_VideoSubscribe) {
        if m.session == server.selfSession?.raw {
            // A viewer of one of our streams wants a keyframe.
            if m.requestKeyframe { onKeyframeRequested?(m.streamID) }
            return
        }
        // The server's echo of our own request: subscribe == false means it was refused.
        let key = StreamKey(session: m.session, streamID: m.streamID)
        if !m.subscribe, var s = videoStreams[key] {
            s.denied = true
            videoStreams[key] = s
            publishVideo()
        }
    }

    private func publishVideo() {
        let list = capabilities.video ? videoStreams.values.sorted { ($0.key.session, $0.key.streamID) < ($1.key.session, $1.key.streamID) } : []
        publish { $0.videoStreams = list }
    }

    // MARK: - Control channel

    private func handle(_ event: TLSLink.Event) {
        switch event {
        case .ready:
            sendVersionAndAuthenticate()
            startTimers()
        case let .data(data):
            lastHeard = Date()
            guard let messages = reader.feed(data) else {
                fail("The server sent an oversize message")
                return
            }
            for m in messages { dispatch(type: m.type, payload: m.payload) }
        case let .untrusted(cert):
            teardown()
            publish { $0.connection = .certificateTrustRequired(cert) }
        case let .closed(reason):
            fail(reason ?? "Disconnected")
        }
    }

    private func sendVersionAndAuthenticate() {
        // The Mumble protocol version this fork speaks, as the desktop and Android clients send it; which
        // client this is goes in `release`.
        let (major, minor, patch): (UInt32, UInt32, UInt32) = (1, 7, 0)
        var v = MumbleProto_Version()
        v.versionV1 = ProtocolVersion.v1(major, minor, patch)
        v.versionV2 = ProtocolVersion.v2(UInt64(major), UInt64(minor), UInt64(patch))
        v.release = "Mumble Video for iOS"
        v.os = "iOS"
        v.osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        send(MumbleCoreType.version, v)

        var a = MumbleProto_Authenticate()
        a.username = request?.username ?? ""
        if let p = request?.password, !p.isEmpty { a.password = p }
        a.tokens = request?.accessTokens ?? []
        a.opus = true
        a.features = [.video]
        send(MumbleCoreType.authenticate, a)
    }

    private func dispatch(type: UInt16, payload: Data) {
        do {
            switch type {
            case MumbleCoreType.version:
                let m = try MumbleProto_Version(serializedBytes: payload)
                serverVersionV2 = m.hasVersionV2 ? m.versionV2 : UInt64(m.versionV1 >> 16) << 48 | UInt64((m.versionV1 >> 8) & 0xff) << 32 | UInt64(m.versionV1 & 0xff) << 16
                serverRelease = m.release
                session.setServerVersion(serverVersionV2)
                let release = m.release
                publish { $0.serverRelease = release }
            case MumbleCoreType.reject:
                let m = try MumbleProto_Reject(serializedBytes: payload)
                let reason = m.reason.isEmpty ? "Rejected (\(m.type))" : m.reason
                teardown()
                publish { $0.connection = .rejected(reason: reason) }
            case MumbleCoreType.serverSync:
                let m = try MumbleProto_ServerSync(serializedBytes: payload)
                server.selfSession = UserSession(m.session)
                server.welcomeText = m.welcomeText
                let snapshot = server
                publish { $0.server = snapshot; $0.connection = .connected }
            case MumbleCoreType.channelState:
                ServerReducer.apply(try MumbleProto_ChannelState(serializedBytes: payload), to: &server)
                publishServer()
            case MumbleCoreType.channelRemove:
                ServerReducer.remove(try MumbleProto_ChannelRemove(serializedBytes: payload), from: &server)
                publishServer()
            case MumbleCoreType.userState:
                ServerReducer.apply(try MumbleProto_UserState(serializedBytes: payload), to: &server)
                publishServer()
            case MumbleCoreType.userRemove:
                let m = try MumbleProto_UserRemove(serializedBytes: payload)
                ServerReducer.remove(m, from: &server)
                session.removeSender(m.session)
                videoStreams = videoStreams.filter { $0.key.session != m.session }
                publishVideo()
                media?.senderRemoved(UserSession(m.session))
                publishServer()
            case MumbleCoreType.textMessage:
                let message = ServerReducer.message(try MumbleProto_TextMessage(serializedBytes: payload), in: server)
                publish { $0.messages.appendBounded(message) }
            case MumbleCoreType.cryptSetup:
                let (_, events) = session.cryptSetup(payload)
                handle(events)
                startUDPIfReady()
            case MumbleCoreType.serverConfig:
                let m = try MumbleProto_ServerConfig(serializedBytes: payload)
                let first = !seenServerConfig
                seenServerConfig = true
                ServerReducer.apply(m, first: first, legacyVideoPeer: ProtocolVersion.isLegacyVideoPeer(versionV2: serverVersionV2, release: serverRelease), to: &capabilities)
                if first { session.setChannelFraming(capabilities.video) }
                let caps = capabilities
                publish { $0.capabilities = caps }
                publishVideo()
                startUDPIfReady()
            case MumbleCoreType.udpTunnel:
                handle(session.receiveTunnelled(payload))
            case MumbleCoreType.ping:
                let m = try MumbleProto_Ping(serializedBytes: payload)
                if m.hasTimestamp {
                    let ms = Double(nowUsec() &- m.timestamp) / 1000
                    publish { $0.tcpPingMs = ms }
                }
            case MumbleCoreType.videoState:
                handleVideoState(try MumbleProto_VideoState(serializedBytes: payload))
            case MumbleCoreType.videoSubscribe:
                handleVideoSubscribe(try MumbleProto_VideoSubscribe(serializedBytes: payload))
            case MumbleCoreType.permissionDenied:
                let m = try MumbleProto_PermissionDenied(serializedBytes: payload)
                let text = m.reason.isEmpty ? "Permission denied" : m.reason
                publish { $0.messages.appendBounded(ChatMessage(sender: nil, senderName: "Server", body: text)) }
            default:
                break // not used by this client yet
            }
        } catch {
            NSLog("MumbleClient: could not parse control message %d: %@", type, "\(error)")
        }
    }

    private func send(_ type: UInt16, _ message: some SwiftProtobuf.Message) {
        guard let link, let payload: Data = try? message.serializedBytes() else { return }
        link.send(ControlReader.frame(type: type, payload: payload))
    }

    // MARK: - UDP

    /// UDP starts once keyed and once the framing is known (the first ServerConfig). Until then voice goes
    /// through the TCP tunnel, which needs no framing.
    private func startUDPIfReady() {
        guard udp == nil, session.isKeyed, seenServerConfig, let request else { return }
        let params = NWParameters.udp
        params.serviceClass = .interactiveVoice
        let conn = NWConnection(host: NWEndpoint.Host(request.host), port: NWEndpoint.Port(rawValue: request.port)!, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.sendUDPPing() }
        }
        udp = conn
        conn.start(queue: queue)
        receiveUDP(conn)
    }

    private func receiveUDP(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.udp === conn else { return }
            if let data, !data.isEmpty {
                lastHeard = Date()
                handle(session.receiveDatagram(data, nowUsec: nowUsec()))
            }
            if error == nil { receiveUDP(conn) }
        }
    }

    private func sendUDPPing() {
        guard let udp, let ping = session.makePing(timestamp: nowUsec()) else { return }
        udpPingsUnanswered += 1
        if udpVerified && udpPingsUnanswered > 3 {
            udpVerified = false
            publish { $0.udpActive = false }
        }
        udp.send(content: ping, completion: .idempotent)
    }

    private func handle(_ events: MediaEvents) {
        for c in events.controlToSend { link?.send(c) }
        if let udp {
            for d in events.datagramsToSend { udp.send(content: d, completion: .idempotent) }
        }
        if let t = events.pongs.last {
            udpPingsUnanswered = 0
            let ms = Double(nowUsec() &- t) / 1000
            if !udpVerified {
                udpVerified = true
            }
            publish { $0.udpActive = true; $0.udpPingMs = ms }
        }
        if !events.videoNacksForUs.isEmpty { answerNacks(events.videoNacksForUs) }
        if let media {
            for a in events.audio { media.audio(a) }
            for v in events.video { media.video(v) }
        }
    }

    private func tunnel(opus: Data, frameNumber: UInt64, target: UInt32, isLast: Bool) {
        var audio = MumbleUDP_Audio()
        audio.target = target
        audio.frameNumber = frameNumber
        audio.opusData = opus
        audio.isTerminator = isLast
        guard let body: Data = try? audio.serializedBytes() else { return }
        // UDP message type byte (Audio = 0) then the protobuf, as the server expects inside UDPTunnel.
        link?.send(ControlReader.frame(type: MumbleCoreType.udpTunnel, payload: Data([0]) + body))
    }

    // MARK: - Lifecycle

    private func startTimers() {
        lastHeard = Date()
        let tcp = DispatchSource.makeTimerSource(queue: queue)
        tcp.schedule(deadline: .now() + 1, repeating: 15)
        tcp.setEventHandler { [weak self] in self?.tcpPing() }
        let udpTimer = DispatchSource.makeTimerSource(queue: queue)
        udpTimer.schedule(deadline: .now() + 5, repeating: 5)
        udpTimer.setEventHandler { [weak self] in self?.sendUDPPing() }
        timers = [tcp, udpTimer]
        timers.forEach { $0.resume() }
    }

    private func tcpPing() {
        if Date().timeIntervalSince(lastHeard) > 35 {
            fail("The server stopped responding")
            return
        }
        var p = MumbleProto_Ping()
        p.timestamp = nowUsec()
        let s = session.stats
        p.good = s.audioGood
        p.late = s.audioLate
        p.lost = s.audioLost
        p.resync = s.audioResync
        send(MumbleCoreType.ping, p)
    }

    private func fail(_ reason: String) {
        teardown()
        publish { $0.connection = .disconnected(reason: reason); $0.udpActive = false }
    }

    private func teardown() {
        timers.forEach { $0.cancel() }
        timers = []
        link?.close()
        link = nil
        udp?.cancel()
        udp = nil
        reader = ControlReader()
        session = MediaSession()
        server = ServerState()
        capabilities = ServerCapabilities()
        seenServerConfig = false
        videoStreams = [:]
        lastKeyframeRequest = [:]
        resendHistory = VideoResendHistory()
        udpVerified = false
        udpPingsUnanswered = 0
        serverVersionV2 = 0
        serverRelease = ""
    }

    private func publishServer() {
        let snapshot = server
        publish { $0.server = snapshot }
    }

    private func publish(_ change: @escaping @MainActor (ClientState) -> Void) {
        let state = state
        DispatchQueue.main.async { MainActor.assumeIsolated { change(state) } }
    }

    private func nowUsec() -> UInt64 {
        (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1000
    }
}

/// Control message type numbers (mumble-core's ControlType).
enum MumbleCoreType {
    static let version: UInt16 = 0
    static let udpTunnel: UInt16 = 1
    static let authenticate: UInt16 = 2
    static let ping: UInt16 = 3
    static let reject: UInt16 = 4
    static let serverSync: UInt16 = 5
    static let channelRemove: UInt16 = 6
    static let channelState: UInt16 = 7
    static let userRemove: UInt16 = 8
    static let userState: UInt16 = 9
    static let textMessage: UInt16 = 11
    static let permissionDenied: UInt16 = 12
    static let cryptSetup: UInt16 = 15
    static let serverConfig: UInt16 = 24
    static let videoState: UInt16 = 27
    static let videoSubscribe: UInt16 = 28
}
