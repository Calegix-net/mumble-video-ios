import MumbleKit
import SwiftUI

struct SessionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            NavigationStack { ChannelsView() }.tabItem { Label("Channels", systemImage: "person.3") }
            NavigationStack { ChatView() }.tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            if model.state.capabilities.video {
                NavigationStack { VideoListView() }.tabItem { Label("Video", systemImage: "play.rectangle") }
            }
        }
        .safeAreaInset(edge: .bottom) { VoiceBar().padding(.bottom, 52) }
    }
}

/// Mute, deafen and push-to-talk, always in reach.
struct VoiceBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            Button { model.toggleMute() } label: {
                Image(systemName: model.muted ? "mic.slash.fill" : "mic.fill")
            }
            .accessibilityLabel(model.muted ? "Unmute" : "Mute")
            Button { model.toggleDeafen() } label: {
                Image(systemName: model.deafened ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .accessibilityLabel(model.deafened ? "Undeafen" : "Deafen")
            Spacer()
            if model.pushToTalk {
                Text("Hold to talk")
                    .font(.headline)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(model.selfTalking ? Color.green : Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in model.setPushToTalk(pressed: true) }
                        .onEnded { _ in model.setPushToTalk(pressed: false) })
                    .accessibilityLabel("Push to talk")
            } else if model.selfTalking {
                Label("Talking", systemImage: "waveform").foregroundStyle(.green)
            }
        }
        .font(.title3)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.bar)
    }
}

struct ChannelsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ChannelRows(id: .root, depth: 0)
        }
        .listStyle(.plain)
        .navigationTitle(model.state.server.channels[.root]?.name ?? "Server")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Push to talk", isOn: Binding(get: { model.pushToTalk }, set: { model.pushToTalk = $0 }))
                    Button("Disconnect", role: .destructive) { model.disconnect() }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }
}

/// One channel, its users, then its sub-channels, indented.
struct ChannelRows: View {
    @Environment(AppModel.self) private var model
    let id: ChannelID
    let depth: Int

    var body: some View {
        let server = model.state.server
        if let channel = server.channels[id] {
            Button { model.client.joinChannel(id) } label: {
                Label(channel.name.isEmpty ? "Root" : channel.name, systemImage: "number")
                    .fontWeight(server.selfUser?.channel == id ? .bold : .regular)
            }
            .padding(.leading, CGFloat(depth) * 16)
            ForEach(server.users(in: id)) { user in
                UserRow(user: user, isSelf: user.id == server.selfSession)
                    .padding(.leading, CGFloat(depth + 1) * 16)
            }
            ForEach(server.children(of: id)) { child in
                ChannelRows(id: child.id, depth: depth + 1)
            }
        }
    }
}

struct UserRow: View {
    @Environment(AppModel.self) private var model
    let user: User
    let isSelf: Bool

    var body: some View {
        let talking = isSelf ? model.selfTalking : model.talking.contains(user.id.raw)
        HStack {
            Image(systemName: talking ? "person.wave.2.fill" : "person.fill")
                .foregroundStyle(talking ? .green : .secondary)
            Text(user.name).fontWeight(isSelf ? .semibold : .regular)
            Spacer()
            if model.state.videoStreams.contains(where: { $0.key.session == user.id.raw }) {
                Image(systemName: "video.fill").foregroundStyle(.red)
            }
            if user.selfDeaf || user.deaf {
                Image(systemName: "speaker.slash")
            } else if user.selfMute || user.mute || user.suppress {
                Image(systemName: "mic.slash")
            }
        }
        .font(.subheadline)
    }
}

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""

    var body: some View {
        let state = model.state
        let here = state.server.selfUser?.channel
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(state.messages.filter { $0.isPrivate || here == nil || $0.channels.contains(here!) || $0.trees.contains(here!) || $0.channels.isEmpty }) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.senderName + (m.isPrivate ? " (private)" : "")).font(.caption).foregroundStyle(.secondary)
                        Text(plain(m.body))
                    }
                    .id(m.id)
                }
                .listStyle(.plain)
                .onChange(of: state.messages.count) { if let last = state.messages.last { proxy.scrollTo(last.id) } }
            }
            HStack {
                TextField("Message", text: $draft).textFieldStyle(.roundedBorder).onSubmit(send)
                Button("Send", action: send).disabled(draft.isEmpty || here == nil)
            }
            .padding()
            .padding(.bottom, 56)
        }
        .navigationTitle(here.flatMap { state.server.channels[$0]?.name } ?? "Chat")
    }

    private func send() {
        guard !draft.isEmpty, let here = model.state.server.selfUser?.channel else { return }
        model.client.sendMessage(draft, to: .channel(here))
        draft = ""
    }

    /// Mumble chat is HTML; show it as text.
    private func plain(_ html: String) -> String {
        html.replacingOccurrences(of: "<br />", with: "\n").replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
    }
}

struct VideoListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let streams = model.state.videoStreams.filter { $0.codec.isPicture }
        ScrollView {
            if streams.isEmpty {
                ContentUnavailableView("Nobody is sharing video", systemImage: "video.slash",
                                       description: Text("Shares from people on this server appear here."))
            }
            LazyVStack(spacing: 16) {
                ForEach(streams) { stream in
                    VideoTile(stream: stream)
                }
            }
            .padding()
            .padding(.bottom, 56)
        }
        .navigationTitle("Video")
    }
}

struct VideoTile: View {
    @Environment(AppModel.self) private var model
    let stream: RemoteVideoStream

    var body: some View {
        let name = model.state.server.users[UserSession(stream.key.session)]?.name ?? "Someone"
        let watching = model.watching.contains(stream.key)
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(.black)
                if let frame = model.frames[stream.key] {
                    Image(decorative: frame, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else if watching {
                    ProgressView().tint(.white)
                } else if stream.denied {
                    Text("Not allowed to watch").foregroundStyle(.white)
                } else {
                    Label("Watch", systemImage: "play.fill").foregroundStyle(.white)
                }
            }
            .aspectRatio(CGFloat(max(stream.width, 1)) / CGFloat(max(stream.height, 1)), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture { watching ? model.stopWatching(stream.key) : model.watch(stream) }
            Text("\(name) · \(stream.source == .camera ? "camera" : "screen")\(stream.sourceName.isEmpty ? "" : " · \(stream.sourceName)")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
