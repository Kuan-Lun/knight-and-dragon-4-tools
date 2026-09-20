import Testing
@testable import MirrorProbeRuntime

@Suite("Immediate re-post after a cursor-disturbed click")
struct AutomationClickRepostPolicyTests {
    @Test("Only a disturbed cursor on an unchanged page re-posts, at most twice")
    func repostConditions() {
        #expect(AutomationClickRepostPolicy.shouldRepost(cursorDisturbed: true, frameUnchanged: true, repostsSoFar: 0))
        #expect(AutomationClickRepostPolicy.shouldRepost(cursorDisturbed: true, frameUnchanged: true, repostsSoFar: 1))
        #expect(!AutomationClickRepostPolicy.shouldRepost(cursorDisturbed: true, frameUnchanged: true, repostsSoFar: 2))
        // A changed page means the tap (or something else) took effect: never double-tap.
        #expect(!AutomationClickRepostPolicy.shouldRepost(cursorDisturbed: true, frameUnchanged: false, repostsSoFar: 0))
        // An undisturbed cursor with an unchanged page is a slow game, not a lost tap.
        #expect(!AutomationClickRepostPolicy.shouldRepost(cursorDisturbed: false, frameUnchanged: true, repostsSoFar: 0))
        #expect(!AutomationClickRepostPolicy.shouldRepost(cursorDisturbed: false, frameUnchanged: false, repostsSoFar: 0))
        #expect(!AutomationClickRepostPolicy.shouldRepost(cursorDisturbed: true, frameUnchanged: true, repostsSoFar: -1))
    }
}
