import Foundation

/// Joining a channel from the channel list has to be deliberate. A single tap used to join, so a finger
/// that only meant to stop the list scrolling, or landed a row off, moved you out of your conversation.
///
/// Now (the same on Android): a tap selects a channel and shows its Join button; the button, a swipe or a
/// long press joins. Taps while the list is moving, and just after it stops, are ignored.
public enum ChannelGesture: Sendable {
    case tap
    case joinButton
    case longPress
    case swipe
}

public enum ChannelGestureResult: Sendable, Equatable {
    case ignore
    case select
    case join
}

public enum ChannelJoinPolicy {
    /// What a gesture on `channel` does. `tapAccepted` is ScrollTapGuard's verdict for taps; a long press
    /// or a swipe cannot happen by brushing a moving list, so they do not need one.
    public static func resolve(_ gesture: ChannelGesture, on channel: ChannelID, selfChannel: ChannelID?,
                               tapAccepted: Bool) -> ChannelGestureResult {
        let canJoin = channel != selfChannel
        switch gesture {
        case .tap:
            return tapAccepted ? .select : .ignore
        case .joinButton:
            return tapAccepted && canJoin ? .join : .ignore
        case .longPress, .swipe:
            return canJoin ? .join : .ignore
        }
    }
}

/// Whether a tap on a scrolling list is a real one. The touch that stops a flick lands on whatever row is
/// under it, so taps count only while the list is still and `quietAfterScroll` has passed since it moved.
public struct ScrollTapGuard: Sendable, Equatable {
    public static let quietAfterScroll: TimeInterval = 0.4

    public private(set) var scrolling = false
    private var stoppedAt: TimeInterval?

    public init() {}

    /// `now` is any monotonic clock in seconds (ProcessInfo.systemUptime in the app).
    public mutating func scrollChanged(isScrolling: Bool, now: TimeInterval) {
        if scrolling && !isScrolling { stoppedAt = now }
        scrolling = isScrolling
    }

    public func acceptsTap(now: TimeInterval) -> Bool {
        if scrolling { return false }
        guard let stoppedAt else { return true }
        return now - stoppedAt >= Self.quietAfterScroll
    }
}
