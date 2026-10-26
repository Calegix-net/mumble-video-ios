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
    /// The channel a tap picked; it shows a Join button. Tapping never joins (see ChannelJoinPolicy).
    @State private var selected: ChannelID?
    @State private var tapGuard = TapGuardBox()

    var body: some View {
        List {
            ChannelRows(id: .root, depth: 0, selected: $selected, tapGuard: tapGuard)
        }
        .listStyle(.plain)
        .modifier(ScrollPhaseTracker(tapGuard: tapGuard))
        .navigationTitle(model.state.server.channels[.root]?.name ?? "Server")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Push to talk", isOn: Binding(get: { model.pushToTalk }, set: { model.pushToTalk = $0 }))
                    Picker("Keep screen on", selection: Binding(get: { model.keepScreenAwake }, set: { model.keepScreenAwake = $0 })) {
                        ForEach(KeepScreenAwake.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Button("Disconnect", role: .destructive) { model.disconnect() }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }
}

/// The list's ScrollTapGuard, held by reference: a tap is judged against the scroll state at that moment,
/// and scrolling does not re-render the list.
@MainActor final class TapGuardBox {
    var value = ScrollTapGuard()
    func acceptsTap() -> Bool { value.acceptsTap(now: ProcessInfo.processInfo.systemUptime) }
}

/// Tells the tap guard when the list moves. iOS 17 has no scroll phase to watch; there UIKit's own rule
/// (the touch that stops a flick is not delivered as a tap) is what stands between a flick and a selection.
private struct ScrollPhaseTracker: ViewModifier {
    let tapGuard: TapGuardBox

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                tapGuard.value.scrollChanged(isScrolling: phase != .idle, now: ProcessInfo.processInfo.systemUptime)
            }
        } else {
            content
        }
    }
}

/// One channel, its users, then its sub-channels, indented.
struct ChannelRows: View {
    @Environment(AppModel.self) private var model
    let id: ChannelID
    let depth: Int
    @Binding var selected: ChannelID?
    let tapGuard: TapGuardBox

    var body: some View {
        let server = model.state.server
        if let channel = server.channels[id] {
            let here = server.selfUser?.channel == id
            let isSelected = selected == id
            HStack {
                Label(channel.name.isEmpty ? "Root" : channel.name, systemImage: "number")
                    .fontWeight(here ? .bold : .regular)
                Spacer()
                if isSelected {
                    if here {
                        Text("You're here").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Button("Join") { handle(.joinButton) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
            }
            .contentShape(Rectangle())
            .padding(.leading, CGFloat(depth) * 16)
            .onTapGesture { handle(.tap) }
            .onLongPressGesture(minimumDuration: 0.5) { handle(.longPress) }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if !here {
                    Button("Join") { handle(.swipe) }.tint(.accentColor)
                }
            }
            .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : nil)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint(here ? "You are in this channel" : "Double-tap to select, then Join")
            .accessibilityActions {
                if !here { Button("Join") { handle(.swipe) } }
            }
            ForEach(server.users(in: id)) { user in
                UserRow(user: user, isSelf: user.id == server.selfSession)
                    .padding(.leading, CGFloat(depth + 1) * 16)
            }
            ForEach(server.children(of: id)) { child in
                ChannelRows(id: child.id, depth: depth + 1, selected: $selected, tapGuard: tapGuard)
            }
        }
    }

    private func handle(_ gesture: ChannelGesture) {
        let result = ChannelJoinPolicy.resolve(gesture, on: id, selfChannel: model.state.server.selfUser?.channel,
                                               tapAccepted: tapGuard.acceptsTap())
        switch result {
        case .ignore:
            break
        case .select:
            selected = selected == id ? nil : id
        case .join:
            selected = nil
            model.client.joinChannel(id)
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
                        ChatBody(parts: m.parts)
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
}

/// A message's text and pictures. Pictures were checked when the message arrived and are decoded here,
/// off the main thread and scaled down (ChatImageDecoder), only while the row is on screen.
struct ChatBody: View {
    let parts: [ChatPart]

    var body: some View {
        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
            switch part {
            case let .text(text): Text(text)
            case let .image(image): ChatPicture(image: image)
            case let .refusedImage(reason): Label(reason, systemImage: "photo").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ChatPicture: View {
    let image: ChatImage
    @State private var decoded: CGImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let decoded {
                Image(decorative: decoded, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else if failed {
                Label("Broken picture", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: maxWidth, maxHeight: 400, alignment: .leading)
        .task {
            let data = image.data
            let result = await Task.detached(priority: .utility) { ChatImageDecoder.decode(data).map(DecodedImage.init) }.value
            decoded = result?.image
            failed = result == nil
        }
    }

    private var maxWidth: CGFloat {
        CGFloat(image.displayWidth ?? min(image.pixelWidth, ChatLimits.maxDisplaySide))
    }
}

private struct DecodedImage: @unchecked Sendable {
    let image: CGImage
}

struct VideoListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let streams = model.state.videoStreams.filter { $0.codec.isPicture }
        ScrollView {
            OwnVideoPanel().padding(.horizontal).padding(.top, 8)
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

/// What we send: the camera (with a preview) and the screen.
struct OwnVideoPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ready = model.state.udpActive
        VStack(alignment: .leading, spacing: 10) {
            if model.sendingCamera {
                ZStack(alignment: .topTrailing) {
                    Rectangle().fill(.black)
                    if let preview = model.cameraPreview {
                        Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView().tint(.white)
                    }
                    Label(model.cameraIsTestPattern ? "Test pattern" : "Live", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption.bold()).padding(6).background(.red, in: Capsule()).foregroundStyle(.white).padding(8)
                }
                .aspectRatio(model.cameraPreview.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 4 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 12) {
                Button {
                    model.sendingCamera ? model.stopCamera() : model.startCamera()
                } label: {
                    Label(model.sendingCamera ? "Stop" : "Camera", systemImage: model.sendingCamera ? "video.slash.fill" : "video.fill")
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.sendingCamera ? .red : .accentColor)
                .disabled(!ready)
                if model.sendingCamera {
                    Button { model.switchCamera() } label: { Image(systemName: "arrow.triangle.2.circlepath.camera") }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Switch camera")
                }
                Spacer()
                if model.sharingScreen {
                    Button(role: .destructive) { model.stopScreenShare() } label: {
                        Label("Stop sharing", systemImage: "rectangle.on.rectangle.slash").lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                } else {
                    ScreenShareButton(enabled: ready && model.screenShareAvailable)
                }
            }
            if !ready {
                Text("Video starts once the voice connection is up.").font(.caption).foregroundStyle(.secondary)
            } else if !model.screenShareAvailable {
                Text("Screen sharing needs a signed build (App Group).").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
