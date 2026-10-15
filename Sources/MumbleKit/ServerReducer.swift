import Foundation

/// Folds control messages into ServerState (the iOS counterpart of Android's SessionReducer). Messages are
/// partial updates: only fields that are present change.
enum ServerReducer {
    static func apply(_ m: MumbleProto_ChannelState, to s: inout ServerState) {
        guard m.hasChannelID else { return }
        let id = ChannelID(m.channelID)
        var c = s.channels[id] ?? Channel(id: id)
        if m.hasParent { c.parent = ChannelID(m.parent) }
        if m.hasName { c.name = m.name }
        if m.hasDescription_p { c.description = m.description_p }
        if m.hasPosition { c.position = m.position }
        if m.hasTemporary { c.temporary = m.temporary }
        if m.hasMaxUsers { c.maxUsers = m.maxUsers }
        s.channels[id] = c
    }

    static func remove(_ m: MumbleProto_ChannelRemove, from s: inout ServerState) {
        s.channels[ChannelID(m.channelID)] = nil
    }

    static func apply(_ m: MumbleProto_UserState, to s: inout ServerState) {
        guard m.hasSession else { return }
        let id = UserSession(m.session)
        var u = s.users[id] ?? User(id: id)
        if m.hasName { u.name = m.name }
        if m.hasChannelID { u.channel = ChannelID(m.channelID) }
        if m.hasUserID { u.userID = m.userID }
        if m.hasMute { u.mute = m.mute }
        if m.hasDeaf { u.deaf = m.deaf }
        if m.hasSuppress { u.suppress = m.suppress }
        if m.hasSelfMute { u.selfMute = m.selfMute }
        if m.hasSelfDeaf { u.selfDeaf = m.selfDeaf }
        if m.hasPrioritySpeaker { u.prioritySpeaker = m.prioritySpeaker }
        if m.hasRecording { u.recording = m.recording }
        if m.hasComment { u.comment = m.comment }
        s.users[id] = u
    }

    static func remove(_ m: MumbleProto_UserRemove, from s: inout ServerState) {
        s.users[UserSession(m.session)] = nil
    }

    static func message(_ m: MumbleProto_TextMessage, in s: ServerState) -> ChatMessage {
        let sender = m.hasActor ? UserSession(m.actor) : nil
        return ChatMessage(
            sender: sender,
            senderName: sender.flatMap { s.users[$0]?.name } ?? "Server",
            channels: m.channelID.map(ChannelID.init),
            trees: m.treeID.map(ChannelID.init),
            users: m.session.map(UserSession.init),
            body: m.message,
            isOwn: sender != nil && sender == s.selfSession)
    }

    /// Capabilities from a ServerConfig. `first` is the session's first one: only it is authoritative for
    /// features; later ones are partial deltas (an admin changing one setting).
    static func apply(_ m: MumbleProto_ServerConfig, first: Bool, legacyVideoPeer: Bool, to c: inout ServerCapabilities) {
        if first {
            c.known = true
            c.video = m.features.contains(.video) || (m.features.isEmpty && legacyVideoPeer)
            c.fileTransfer = m.features.contains(.fileTransfer)
        }
        if m.hasMaxBandwidth { c.maxBandwidth = m.maxBandwidth }
        if m.hasMaxVideoBandwidth { c.maxVideoBandwidth = m.maxVideoBandwidth }
        if m.hasMaxVideoStreamsPerChannel { c.maxVideoStreamsPerChannel = m.maxVideoStreamsPerChannel }
        if m.hasMessageLength { c.messageLength = m.messageLength }
        if m.hasImageMessageLength { c.imageMessageLength = m.imageMessageLength }
        if m.hasAllowHtml { c.allowHTML = m.allowHtml }
        if m.hasRecordingAllowed { c.recordingAllowed = m.recordingAllowed }
    }
}

/// Mumble's two version encodings.
enum ProtocolVersion {
    static func v2(_ major: UInt64, _ minor: UInt64, _ patch: UInt64) -> UInt64 { major << 48 | minor << 32 | patch << 16 }
    static func v1(_ major: UInt32, _ minor: UInt32, _ patch: UInt32) -> UInt32 { major << 16 | minor << 8 | min(patch, 255) }

    /// This fork's v1.7.0 to v1.9.1 releases speak video but advertise no features; they all report version
    /// 1.7.0 with release "1.7.0" (MumbleProto::isLegacyVideoPeer).
    static func isLegacyVideoPeer(versionV2: UInt64, release: String) -> Bool {
        versionV2 == v2(1, 7, 0) && release == "1.7.0"
    }
}
