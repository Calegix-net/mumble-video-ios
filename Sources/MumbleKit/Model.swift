import Foundation

public struct ChannelID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let raw: UInt32
    public init(_ raw: UInt32) { self.raw = raw }
    public static let root = ChannelID(0)
    public static func < (a: Self, b: Self) -> Bool { a.raw < b.raw }
    public var description: String { "#\(raw)" }
}

public struct UserSession: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let raw: UInt32
    public init(_ raw: UInt32) { self.raw = raw }
    public static func < (a: Self, b: Self) -> Bool { a.raw < b.raw }
    public var description: String { "s\(raw)" }
}

public struct Channel: Identifiable, Sendable, Equatable {
    public var id: ChannelID
    public var parent: ChannelID?
    public var name: String = ""
    public var description: String = ""
    public var position: Int32 = 0
    public var temporary = false
    public var maxUsers: UInt32 = 0
}

public struct User: Identifiable, Sendable, Equatable {
    public var id: UserSession
    public var name: String = ""
    public var channel: ChannelID = .root
    /// Registered user id, if registered.
    public var userID: UInt32?
    public var mute = false
    public var deaf = false
    public var suppress = false
    public var selfMute = false
    public var selfDeaf = false
    public var prioritySpeaker = false
    public var recording = false
    public var comment: String = ""
}

/// The server as the client sees it: the channel tree and who is where.
public struct ServerState: Sendable, Equatable {
    public var channels: [ChannelID: Channel] = [:]
    public var users: [UserSession: User] = [:]
    public var selfSession: UserSession?
    public var welcomeText: String = ""

    public init() {}

    public var selfUser: User? { selfSession.flatMap { users[$0] } }

    public func children(of id: ChannelID) -> [Channel] {
        channels.values.filter { $0.parent == id }.sorted { ($0.position, $0.name.lowercased()) < ($1.position, $1.name.lowercased()) }
    }

    public func users(in id: ChannelID) -> [User] {
        users.values.filter { $0.channel == id }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}

/// What the server supports, from its first ServerConfig. Feature-gated UI must stay off until `known`.
public struct ServerCapabilities: Sendable, Equatable {
    public var known = false
    public var video = false
    public var fileTransfer = false
    public var maxBandwidth: UInt32 = 0
    public var maxVideoBandwidth: UInt32 = 0
    public var maxVideoStreamsPerChannel: UInt32 = 0
    public var messageLength: UInt32 = 0
    public var imageMessageLength: UInt32 = 0
    public var allowHTML = true
    public var recordingAllowed = true
}

public struct CertificateInfo: Sendable, Equatable {
    public var sha256: String
    public var subject: String
    public var der: Data
}

public enum ConnectionState: Sendable, Equatable {
    case disconnected(reason: String?)
    case connecting
    /// The server's certificate is not trusted by the system; the user decides (trust on first use).
    case certificateTrustRequired(CertificateInfo)
    case connected
    case rejected(reason: String)

    public var isConnected: Bool { if case .connected = self { true } else { false } }
}

public struct ChatMessage: Identifiable, Sendable, Equatable {
    public var id = UUID()
    public var sender: UserSession?
    public var senderName: String
    public var channels: [ChannelID] = []
    public var trees: [ChannelID] = []
    public var users: [UserSession] = []
    /// May contain HTML when the server allows it. Pictures are taken out (see `parts`) and the rest is
    /// cut to `ChatLimits.maxTextCharacters`, so one message can't hold megabytes.
    public var body: String
    /// The message as text and checked pictures, parsed once when it arrives.
    public var parts: [ChatPart]
    public var date = Date()
    public var isOwn = false

    public init(sender: UserSession?, senderName: String, channels: [ChannelID] = [], trees: [ChannelID] = [],
                users: [UserSession] = [], body: String, isOwn: Bool = false) {
        self.sender = sender
        self.senderName = senderName
        self.channels = channels
        self.trees = trees
        self.users = users
        parts = ChatHTML.parse(body)
        let html = body.replacingOccurrences(of: "<img\\b[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        self.body = html.count > ChatLimits.maxTextCharacters ? String(html.prefix(ChatLimits.maxTextCharacters)) : html
        self.isOwn = isOwn
    }

    public var isPrivate: Bool { channels.isEmpty && trees.isEmpty && !users.isEmpty }

    /// Roughly the memory this message holds.
    public var cost: Int {
        parts.reduce(body.utf8.count + senderName.utf8.count + 128) { total, part in
            switch part {
            case let .text(t): total + t.utf8.count
            case let .image(i): total + i.data.count
            case let .refusedImage(r): total + r.utf8.count
            }
        }
    }
}

extension [ChatMessage] {
    /// Appends a message and drops the oldest ones past `ChatLimits.maxHistoryMessages` or
    /// `ChatLimits.maxHistoryBytes`, so a flood of messages can't use up the phone's memory.
    public mutating func appendBounded(_ message: ChatMessage) {
        append(message)
        var total = reduce(0) { $0 + $1.cost }
        var drop = 0
        while count - drop > 1, count - drop > ChatLimits.maxHistoryMessages || total > ChatLimits.maxHistoryBytes {
            total -= self[drop].cost
            drop += 1
        }
        if drop > 0 { removeFirst(drop) }
    }
}

public enum MessageTarget: Sendable {
    case channel(ChannelID)
    case tree(ChannelID)
    case user(UserSession)
}

public struct ConnectRequest: Sendable {
    public var host: String
    public var port: UInt16 = 64738
    public var username: String
    public var password: String = ""
    /// PKCS#12 client identity (no password). nil connects without a certificate.
    public var identityPKCS12: Data?
    /// SHA-256 (lowercase hex) of a server certificate the user already accepted.
    public var trustedCertificateSHA256: String?
    public var accessTokens: [String] = []

    public init(host: String, port: UInt16 = 64738, username: String) {
        self.host = host
        self.port = port
        self.username = username
    }
}
