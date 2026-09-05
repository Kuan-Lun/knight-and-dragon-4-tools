import Testing
@testable import MirrorProbeCore

@Suite("All-auto progress validation")
struct AllAutoProgressValidatorTests {
    @Test("A default-on battle uses the same bounded progress requirement without a click")
    func defaultAutomaticBattleRequiresProgress() {
        var validator = AllAutoProgressValidator()
        #expect(validator.automaticBattleExpected(
            at: 10,
            battleSessionID: "battle-default"
        ) == .awaitingProgress(elapsed: 0, remaining: 30))

        #expect(validator.observe(
            at: 39,
            battleSessionID: "battle-default",
            state: .battle,
            genuineProgressObserved: false
        ) == .awaitingProgress(elapsed: 29, remaining: 1))
        #expect(validator.observe(
            at: 40,
            battleSessionID: "battle-default",
            state: .battle,
            genuineProgressObserved: false
        ) == .timedOut(battleSessionID: "battle-default"))
    }

    @Test("A posted all-auto click times out after 30 seconds of an unchanged battle")
    func unchangedBattleTimesOut() {
        var validator = AllAutoProgressValidator()
        #expect(validator.automaticBattlePosted(
            at: 10,
            battleSessionID: "battle-1"
        ) == .awaitingProgress(elapsed: 0, remaining: 30))

        #expect(validator.observe(
            at: 39,
            battleSessionID: "battle-1",
            state: .battle,
            genuineProgressObserved: false
        ) == .awaitingProgress(elapsed: 29, remaining: 1))
        #expect(validator.observe(
            at: 40,
            battleSessionID: "battle-1",
            state: .battle,
            genuineProgressObserved: false
        ) == .timedOut(battleSessionID: "battle-1"))
        #expect(!validator.isAwaitingProgress)
    }

    @Test("Only genuine progress from the clicked battle validates all-auto")
    func genuineProgressMustMatchBattle() {
        var validator = AllAutoProgressValidator()
        _ = validator.automaticBattlePosted(at: 10, battleSessionID: "battle-1")

        #expect(validator.observe(
            at: 20,
            battleSessionID: "battle-2",
            state: .battle,
            genuineProgressObserved: true
        ) == .awaitingProgress(elapsed: 10, remaining: 20))
        #expect(validator.observe(
            at: 21,
            battleSessionID: "battle-1",
            state: .battle,
            genuineProgressObserved: true
        ) == .validated(.genuineBattleProgress))
        #expect(validator.observe(
            at: 50,
            battleSessionID: "battle-1",
            state: .battle,
            genuineProgressObserved: false
        ) == .inactive)
    }

    @Test(
        "A battle modal never counts as automatic-combat progress",
        arguments: [
            GameState.battleEncounterPrompt,
            .battleEventPrompt,
            .defeatPrompt,
        ]
    )
    func battleModalDoesNotValidate(state: GameState) {
        var validator = AllAutoProgressValidator()
        _ = validator.automaticBattleExpected(at: 10, battleSessionID: "battle-1")

        #expect(validator.observe(
            at: 11,
            battleSessionID: "battle-1",
            state: state,
            genuineProgressObserved: false
        ) == .awaitingProgress(elapsed: 1, remaining: 29))
        #expect(validator.isAwaitingProgress)
    }

    @Test(
        "A completed mission validates an automatic battle without an HP sample",
        arguments: [
            GameState.missionComplete,
            .missionCompleteRepeatSelected,
            .missionFailed,
            .missionFailedRepeatSelected,
        ]
    )
    func missionResultValidates(state: GameState) {
        var validator = AllAutoProgressValidator()
        _ = validator.automaticBattleExpected(at: 10, battleSessionID: "battle-1")

        #expect(validator.observe(
            at: 11,
            battleSessionID: nil,
            state: state,
            genuineProgressObserved: false
        ) == .validated(.normalTransition(state)))
    }

    @Test("Rearming after a closed modal starts a fresh 30-second deadline")
    func closedModalRestartsDeadline() {
        var validator = AllAutoProgressValidator()
        _ = validator.automaticBattleExpected(at: 10, battleSessionID: "battle-1")
        #expect(validator.observe(
            at: 35,
            battleSessionID: "battle-1",
            state: .battleEventPrompt,
            genuineProgressObserved: false
        ) == .awaitingProgress(elapsed: 25, remaining: 5))

        #expect(validator.automaticBattleExpected(
            at: 35,
            battleSessionID: "battle-1"
        ) == .awaitingProgress(elapsed: 0, remaining: 30))
        #expect(validator.observe(
            at: 64,
            battleSessionID: "battle-1",
            state: .battle,
            genuineProgressObserved: false
        ) == .awaitingProgress(elapsed: 29, remaining: 1))
        #expect(validator.observe(
            at: 65,
            battleSessionID: "battle-1",
            state: .battle,
            genuineProgressObserved: false
        ) == .timedOut(battleSessionID: "battle-1"))
    }

    @Test("Invalid activation cannot leave a validation pending")
    func invalidActivationFailsClosed() {
        var validator = AllAutoProgressValidator()
        #expect(validator.automaticBattlePosted(
            at: 10,
            battleSessionID: "   "
        ) == .invalidSample)
        #expect(!validator.isAwaitingProgress)
    }
}
