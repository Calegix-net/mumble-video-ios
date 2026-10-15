import Foundation
import MumbleKit
import MumbleShare

/// The app's end of screen sharing. The broadcast extension captures and encodes the screen, then streams
/// H.264 to this listener through a socket in the App Group container; the app, which holds the server
/// connection, sends it as a display stream.
final class ScreenShareHost: @unchecked Sendable {
    /// Called on the main thread when a share starts or ends.
    var onSharingChanged: ((Bool) -> Void)?

    private let listener: BroadcastListener
    private let lock = NSLock()
    private var connection: BroadcastConnection?
    private var sender: VideoSender?

    /// nil when there is no App Group container (unsigned builds, the Simulator).
    init?() {
        guard let path = BroadcastChannel.socketPath(), let l = BroadcastListener(path: path) else { return nil }
        listener = l
    }

    /// Accepts the extension while connected to `client`; bitrate is clamped to the server's video limit.
    func start(client: MumbleClient) {
        listener.onConnection = { [weak self] conn in
            guard let self else { return }
            let sender = VideoSender(client: client, codec: .h264, source: .display, name: "iPhone screen", fps: 30,
                                     bitrate: 2_500_000)
            sender.onKeyframeNeeded = { [weak conn] in conn?.send(.keyframe) }
            let previous = lock.withLock { () -> BroadcastConnection? in
                defer { connection = conn; self.sender = sender }
                return connection
            }
            previous?.send(.stop) // one share at a time
            conn.onMessage = { [weak self, weak sender] m in
                switch m {
                case let .frame(f):
                    sender?.sendEncoded(f.data, isKeyframe: f.isKeyframe, width: f.width, height: f.height, timestampUsec: f.timestampUsec)
                case .ended:
                    self?.ended(conn)
                default:
                    break
                }
            }
            conn.onClose = { [weak self] in self?.ended(conn) }
            conn.start()
            conn.send(.configure(bitrate: UInt32(sender.targetBitrate)))
            DispatchQueue.main.async { self.onSharingChanged?(true) }
        }
        listener.start()
    }

    /// A viewer asked for a keyframe of one of our streams.
    func keyframeRequested(streamID: UInt32) {
        lock.withLock { sender }?.keyframeRequested(streamID: streamID)
    }

    /// Stop from the app: the extension ends the broadcast (iOS shows its own stopped message).
    func stopSharing() {
        lock.withLock { connection }?.send(.stop)
    }

    /// Disconnected from the server: end any share and stop listening.
    func shutdown() {
        stopSharing()
        listener.stop()
        if let c = lock.withLock({ connection }) { ended(c) }
    }

    private func ended(_ conn: BroadcastConnection) {
        let s = lock.withLock { () -> VideoSender? in
            guard connection === conn else { return nil }
            defer { connection = nil; sender = nil }
            return sender
        }
        guard let s else { return }
        s.stop()
        conn.close()
        DispatchQueue.main.async { self.onSharingChanged?(false) }
    }
}
