import Testing
@testable import MirrorProbeCore
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

    @Test("A byte-identical capture is unchanged for every intent")
    func byteIdentityAlwaysCounts() {
        for intent in [AutoLevelActionIntent.selectMissionRepeat, .requestRetreat, .confirmRetreatWithoutTalisman,
                       .advanceMissionSuccess, .pressWideModalTopButton] {
            #expect(AutomationClickRepostPolicy.frameUnchanged(
                intent: intent, fingerprintsEqual: true, sameState: false, samePage: false,
                sameTarget: false, meanAbsoluteDifference: 0.5
            ))
        }
    }

    @Test("A settling result page or dialog counts as unchanged only with the same state, page and target",
          arguments: [AutoLevelActionIntent.advanceMissionSuccess, .advanceMissionFailure,
                      .pressWideModalTopButton, .closeBattlePrompt])
    func settlingPageCountsForAdvancingIntents(intent: AutoLevelActionIntent) {
        // logs/auto-level-20260920-200804: the lost tap left a difference of 0.00008.
        #expect(AutomationClickRepostPolicy.frameUnchanged(
            intent: intent, fingerprintsEqual: false, sameState: true, samePage: true,
            sameTarget: true, meanAbsoluteDifference: 0.00008
        ))
        #expect(AutomationClickRepostPolicy.frameUnchanged(
            intent: intent, fingerprintsEqual: false, sameState: true, samePage: true,
            sameTarget: true, meanAbsoluteDifference: AutomationClickRepostPolicy.unchangedPageMaximumMeanAbsoluteDifference
        ))
        // The smallest received tap in that run moved the page by 0.07.
        #expect(!AutomationClickRepostPolicy.frameUnchanged(
            intent: intent, fingerprintsEqual: false, sameState: true, samePage: true,
            sameTarget: true, meanAbsoluteDifference: 0.07
        ))
        #expect(!AutomationClickRepostPolicy.frameUnchanged(
            intent: intent, fingerprintsEqual: false, sameState: false, samePage: true,
            sameTarget: true, meanAbsoluteDifference: 0
        ))
        // EXP -> loot shares the state and the arrow: a changed page identity is a received tap.
        #expect(!AutomationClickRepostPolicy.frameUnchanged(
            intent: intent, fingerprintsEqual: false, sameState: true, samePage: false,
            sameTarget: true, meanAbsoluteDifference: 0
        ))
        #expect(!AutomationClickRepostPolicy.frameUnchanged(
            intent: intent, fingerprintsEqual: false, sameState: true, samePage: true,
            sameTarget: false, meanAbsoluteDifference: 0
        ))
        // No comparable frame after a window change: never re-post.
        #expect(!AutomationClickRepostPolicy.frameUnchanged(
            intent: intent, fingerprintsEqual: false, sameState: true, samePage: true,
            sameTarget: true, meanAbsoluteDifference: nil
        ))
        #expect(!AutomationClickRepostPolicy.frameUnchanged(
            intent: intent, fingerprintsEqual: false, sameState: true, samePage: true,
            sameTarget: true, meanAbsoluteDifference: .nan
        ))
    }

    @Test("Toggles, one-shot confirmations and the stalled-battle retreat keep byte identity",
          arguments: [AutoLevelActionIntent.selectMissionRepeat, .confirmRetreatWithoutTalisman,
                      .requestRetreat, .enableAllAuto, .confirmLootCollection, .recruitAdventurer,
                      .leaveAdventurer])
    func settlingPageNeverCountsForOtherIntents(intent: AutoLevelActionIntent) {
        #expect(!AutomationClickRepostPolicy.toleratesSettlingPage(intent))
        #expect(!AutomationClickRepostPolicy.frameUnchanged(
            intent: intent, fingerprintsEqual: false, sameState: true, samePage: true,
            sameTarget: true, meanAbsoluteDifference: 0
        ))
    }
}
