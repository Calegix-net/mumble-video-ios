import ReplayKit
import SwiftUI

/// Starts the system broadcast picker for our extension. The picker has no public trigger, so its own
/// button sits under ours and gets our tap.
struct ScreenShareButton: View {
    let enabled: Bool
    @State private var picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))

    var body: some View {
        Button {
            picker.subviews.compactMap { $0 as? UIButton }.first?.sendActions(for: .touchUpInside)
        } label: {
            Label("Share screen", systemImage: "rectangle.on.rectangle")
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
        .background(PickerHost(picker: picker).frame(width: 1, height: 1).opacity(0.01))
        .onAppear {
            picker.preferredExtension = (Bundle.main.bundleIdentifier ?? "com.calegix.mumblevideo.ios") + ".broadcast"
            picker.showsMicrophoneButton = false
        }
    }
}

private struct PickerHost: UIViewRepresentable {
    let picker: RPSystemBroadcastPickerView
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView { picker }
    func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {}
}
