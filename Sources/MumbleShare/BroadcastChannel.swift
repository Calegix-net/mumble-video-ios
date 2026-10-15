import Darwin
import Foundation

/// The pipe between the screen-sharing broadcast extension and the app, through a Unix socket in the
/// shared App Group container. The extension captures and encodes (H.264); the app, which holds the server
/// connection, sends. Messages are length-prefixed:
///
///     u32 length (big-endian) | u8 kind | body
///
/// extension → app: `frame` (u8 keyframe, u16 width, u16 height, u64 timestamp µs, Annex B bytes), `ended`
/// app → extension: `configure` (u32 bitrate, the server's limit applied), `keyframe` (a viewer needs
/// one), `stop` (the user stopped sharing in the app)
public enum BroadcastMessage: Equatable, Sendable {
    case frame(H264Frame)
    case ended
    case configure(bitrate: UInt32)
    case keyframe
    case stop

    public static func == (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case let (.frame(x), .frame(y)): x.data == y.data && x.isKeyframe == y.isKeyframe && x.width == y.width && x.height == y.height
        case let (.configure(x), .configure(y)): x == y
        case (.ended, .ended), (.keyframe, .keyframe), (.stop, .stop): true
        default: false
        }
    }

    func encoded() -> Data {
        var body = Data()
        switch self {
        case let .frame(f):
            body.append(1)
            body.append(f.isKeyframe ? 1 : 0)
            body.append(contentsOf: withUnsafeBytes(of: UInt16(f.width).bigEndian, Array.init))
            body.append(contentsOf: withUnsafeBytes(of: UInt16(f.height).bigEndian, Array.init))
            body.append(contentsOf: withUnsafeBytes(of: f.timestampUsec.bigEndian, Array.init))
            body.append(f.data)
        case .ended: body.append(2)
        case .keyframe: body.append(3)
        case .stop: body.append(4)
        case let .configure(bitrate):
            body.append(5)
            body.append(contentsOf: withUnsafeBytes(of: bitrate.bigEndian, Array.init))
        }
        return withUnsafeBytes(of: UInt32(body.count).bigEndian, { Data($0) }) + body
    }

    /// Parses complete messages off the front of `buffer`, leaving any partial one.
    static func parse(_ buffer: inout Data) -> [BroadcastMessage] {
        var out: [BroadcastMessage] = []
        while buffer.count >= 4 {
            let b = [UInt8](buffer.prefix(4))
            let n = Int(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
            guard buffer.count >= 4 + n, n >= 1 else { break }
            let body = Data(buffer.dropFirst(4).prefix(n))
            buffer.removeFirst(4 + n)
            let bytes = [UInt8](body)
            switch bytes[0] {
            case 1 where bytes.count >= 14:
                let w = Int(UInt16(bytes[2]) << 8 | UInt16(bytes[3]))
                let h = Int(UInt16(bytes[4]) << 8 | UInt16(bytes[5]))
                let ts = bytes[6 ..< 14].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                out.append(.frame(H264Frame(data: Data(bytes[14...]), isKeyframe: bytes[1] == 1, width: w, height: h, timestampUsec: ts)))
            case 2: out.append(.ended)
            case 3: out.append(.keyframe)
            case 4: out.append(.stop)
            case 5 where bytes.count >= 5:
                out.append(.configure(bitrate: bytes[1 ..< 5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }))
            default: break
            }
        }
        return out
    }
}

public enum BroadcastChannel {
    public static let appGroup = "group.com.calegix.mumblevideo"

    /// The socket path inside the App Group container (or `directory` for tests). Kept short: sun_path is
    /// 104 bytes.
    public static func socketPath(directory: URL? = nil) -> String? {
        let dir = directory ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        return dir?.appendingPathComponent("bcast.sock").path
    }
}

/// One connected stream socket with message framing; reads on its own queue.
public final class BroadcastConnection: @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "mumble.broadcast.conn")
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private let writeLock = NSLock()
    public var onMessage: ((BroadcastMessage) -> Void)?
    public var onClose: (() -> Void)?
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Connects to the app's socket (from the extension).
    public static func connect(path: String) -> BroadcastConnection? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un.make(path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { Darwin.close(fd); return nil }
        return BroadcastConnection(fd: fd)
    }

    public func start() {
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        s.setEventHandler { [weak self] in self?.readAvailable() }
        s.setCancelHandler { [fd] in Darwin.close(fd) }
        source = s
        s.resume()
    }

    public func send(_ message: BroadcastMessage) {
        let data = message.encoded()
        writeLock.withLock {
            data.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                    if n <= 0 { break }
                    sent += n
                }
            }
        }
    }

    public func close() {
        queue.async { [self] in finish() }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        let n = read(fd, &chunk, chunk.count)
        guard n > 0 else { finish(); return }
        buffer.append(contentsOf: chunk[0 ..< n])
        for m in BroadcastMessage.parse(&buffer) { onMessage?(m) }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        source?.cancel()
        onClose?()
    }
}

/// The app's end: listens on the socket and accepts the extension's connection.
public final class BroadcastListener: @unchecked Sendable {
    private let fd: Int32
    private let path: String
    private let queue = DispatchQueue(label: "mumble.broadcast.listen")
    private var source: DispatchSourceRead?
    public var onConnection: ((BroadcastConnection) -> Void)?

    public init?(path: String) {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un.make(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 2) == 0 else { Darwin.close(fd); return nil }
        self.fd = fd
        self.path = path
    }

    public func start() {
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            onConnection?(BroadcastConnection(fd: client))
        }
        s.setCancelHandler { [fd, path] in Darwin.close(fd); unlink(path) }
        source = s
        s.resume()
    }

    public func stop() { source?.cancel() }
}

extension sockaddr_un {
    static func make(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(103))
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return addr
    }
}
