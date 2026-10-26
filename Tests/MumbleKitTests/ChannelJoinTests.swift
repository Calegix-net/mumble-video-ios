import Foundation
@testable import MumbleKit
import Testing

struct ChannelJoinPolicyTests {
    let lobby = ChannelID(1)
    let games = ChannelID(2)

    @Test func tapSelectsAndNeverJoins() {
        #expect(ChannelJoinPolicy.resolve(.tap, on: games, selfChannel: lobby, tapAccepted: true) == .select)
        #expect(ChannelJoinPolicy.resolve(.tap, on: lobby, selfChannel: lobby, tapAccepted: true) == .select)
        #expect(ChannelJoinPolicy.resolve(.tap, on: games, selfChannel: lobby, tapAccepted: false) == .ignore)
    }

    @Test func joinButtonSwipeAndLongPressJoin() {
        #expect(ChannelJoinPolicy.resolve(.joinButton, on: games, selfChannel: lobby, tapAccepted: true) == .join)
        #expect(ChannelJoinPolicy.resolve(.swipe, on: games, selfChannel: lobby, tapAccepted: false) == .join)
        #expect(ChannelJoinPolicy.resolve(.longPress, on: games, selfChannel: lobby, tapAccepted: false) == .join)
        #expect(ChannelJoinPolicy.resolve(.longPress, on: games, selfChannel: nil, tapAccepted: true) == .join)
    }

    @Test func joinButtonTapDuringScrollIsIgnored() {
        #expect(ChannelJoinPolicy.resolve(.joinButton, on: games, selfChannel: lobby, tapAccepted: false) == .ignore)
    }

    @Test func ownChannelIsNeverJoined() {
        for gesture in [ChannelGesture.joinButton, .swipe, .longPress] {
            #expect(ChannelJoinPolicy.resolve(gesture, on: lobby, selfChannel: lobby, tapAccepted: true) == .ignore)
        }
    }
}

struct ScrollTapGuardTests {
    @Test func acceptsTapsOnAListThatNeverMoved() {
        #expect(ScrollTapGuard().acceptsTap(now: 0))
    }

    @Test func ignoresTapsWhileScrollingAndJustAfter() {
        var g = ScrollTapGuard()
        g.scrollChanged(isScrolling: true, now: 10)
        #expect(!g.acceptsTap(now: 10.2))
        g.scrollChanged(isScrolling: false, now: 11) // deceleration ended, or a touch stopped it
        #expect(!g.acceptsTap(now: 11))
        #expect(!g.acceptsTap(now: 11 + ScrollTapGuard.quietAfterScroll - 0.01))
        #expect(g.acceptsTap(now: 11 + ScrollTapGuard.quietAfterScroll + 0.01))
    }

    @Test func repeatedIdleReportsDoNotRestartTheQuietPeriod() {
        var g = ScrollTapGuard()
        g.scrollChanged(isScrolling: true, now: 0)
        g.scrollChanged(isScrolling: false, now: 1)
        g.scrollChanged(isScrolling: false, now: 1.3)
        #expect(g.acceptsTap(now: 1.5)) // 0.2 s after the second report, 0.5 s after the stop
    }
}
