import MumbleKit
import SwiftUI

struct ServerListView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: SavedServer?
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            List {
                if let status {
                    Section { Text(status).foregroundStyle(.secondary) }
                }
                Section("Servers") {
                    if model.servers.isEmpty {
                        Text("Add a server to get started.").foregroundStyle(.secondary)
                    }
                    ForEach(model.servers) { server in
                        Button {
                            model.connect(server)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(server.label.isEmpty ? server.host : server.label).font(.headline)
                                Text("\(server.username) @ \(server.host):\(String(server.port))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(isConnecting)
                        .swipeActions {
                            Button("Delete", role: .destructive) { model.delete(server) }
                            Button("Edit") { editing = server }
                        }
                    }
                }
            }
            .navigationTitle("Mumble Video")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = SavedServer(label: "", host: "", username: "") } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(item: $editing) { server in
                ServerEditor(server: server) { model.save($0) }
            }
        }
    }

    private var isConnecting: Bool {
        if case .connecting = model.state.connection { true } else { false }
    }

    private var status: String? {
        switch model.state.connection {
        case .connecting: "Connecting…"
        case let .disconnected(reason): reason
        case let .rejected(reason): "Rejected: \(reason)"
        default: nil
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Picker("Keep screen on", selection: $model.keepScreenAwake) {
                        ForEach(KeepScreenAwake.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text("Streaming means sending a camera or screen, or watching someone's video.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct ServerEditor: View {
    @State var server: SavedServer
    let onSave: (SavedServer) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var port = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Label", text: $server.label)
                TextField("Address", text: $server.host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("Port", text: $port).keyboardType(.numberPad)
                TextField("Username", text: $server.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            .navigationTitle(server.host.isEmpty ? "Add server" : "Edit server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        server.port = UInt16(port) ?? 64738
                        onSave(server)
                        dismiss()
                    }
                    .disabled(server.host.isEmpty || server.username.isEmpty)
                }
            }
            .onAppear { port = String(server.port) }
        }
    }
}
