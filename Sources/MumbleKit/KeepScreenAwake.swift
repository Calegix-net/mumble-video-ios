import Foundation

/// When the app stops the screen locking while it is in front (UIApplication.isIdleTimerDisabled), the
/// same three choices the Android and desktop clients offer.
public enum KeepScreenAwake: String, CaseIterable, Identifiable, Sendable {
    case off
    /// While sending a camera or screen, or watching someone's video.
    case whileVideo
    /// Whenever the app is open, connected or not.
    case whileOpen

    public static let defaultValue = KeepScreenAwake.whileVideo

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: "Off"
        case .whileVideo: "While video is streaming"
        case .whileOpen: "Whenever the app is open"
        }
    }

    /// The stored choice; anything unreadable is the default.
    public init(stored: String?) {
        self = stored.flatMap(KeepScreenAwake.init(rawValue:)) ?? .defaultValue
    }

    public func keepsScreenOn(connected: Bool, sendingVideo: Bool, watchingVideo: Bool) -> Bool {
        switch self {
        case .off: false
        case .whileVideo: connected && (sendingVideo || watchingVideo)
        case .whileOpen: true
        }
    }
}
