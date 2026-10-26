import MumbleKit
import SwiftUI

@main
struct MumbleVideoApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { model.open($0) }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.state.connection {
            case .connected:
                SessionView()
            default:
                ServerListView()
            }
        }
        // The system only honours this while the app is in front, and resets it when the app goes away.
        .onChange(of: model.keepsScreenOn, initial: true) { _, on in UIApplication.shared.isIdleTimerDisabled = on }
        .alert("Trust this server?", isPresented: trustPrompt, presenting: pendingCert) { cert in
            Button("Trust and connect") { model.trust(cert) }
            Button("Cancel", role: .cancel) { model.disconnect() }
        } message: { cert in
            Text("\(cert.subject)\nSHA-256 \(cert.sha256)\n\nMost Mumble servers use self-signed certificates. Only continue if you expected this one; it will be remembered.")
        }
    }

    private var pendingCert: CertificateInfo? {
        if case let .certificateTrustRequired(c) = model.state.connection { return c }
        return nil
    }

    private var trustPrompt: Binding<Bool> {
        Binding(get: { pendingCert != nil }, set: { _ in })
    }
}
