@testable import MumbleKit
import Testing

struct KeepScreenAwakeTests {
    @Test func defaultsToWhileVideo() {
        #expect(KeepScreenAwake(stored: nil) == .whileVideo)
        #expect(KeepScreenAwake(stored: "sometimes") == .whileVideo)
        #expect(KeepScreenAwake(stored: "off") == .off)
        #expect(KeepScreenAwake(stored: "whileOpen") == .whileOpen)
    }

    @Test func eachChoiceKeepsTheScreenOnWhenItShould() {
        for sending in [false, true] {
            for watching in [false, true] {
                #expect(!KeepScreenAwake.off.keepsScreenOn(connected: true, sendingVideo: sending, watchingVideo: watching))
                #expect(KeepScreenAwake.whileVideo.keepsScreenOn(connected: true, sendingVideo: sending, watchingVideo: watching)
                    == (sending || watching))
                #expect(!KeepScreenAwake.whileVideo.keepsScreenOn(connected: false, sendingVideo: sending, watchingVideo: watching))
                #expect(KeepScreenAwake.whileOpen.keepsScreenOn(connected: false, sendingVideo: sending, watchingVideo: watching))
            }
        }
    }
}
