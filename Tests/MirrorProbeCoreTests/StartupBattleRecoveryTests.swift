import Testing
@testable import MirrorProbeCore

@Suite("Recovery of a battle frozen before startup")
struct StartupBattleRecoveryTests {
    @Test("Thirty seconds without progress permits one fresh dense confirmation")
    func frozenStartupRequiresFullIndependentConfirmation() throws {
        var recovery = try makeRecovery()
        #expect(begin(&recovery, from: sample(at: 0, difference: nil), battleSessionID: battleID) == nil)
        for time in 1...29 {
            let current = sample(at: Double(time))
            #expect(update(&recovery, current, battleSessionID: battleID, genuineProgressObserved: false))
            #expect(begin(&recovery, from: current, battleSessionID: battleID) == nil)
        }
        let baseline = sample(at: 30)
        #expect(update(&recovery, baseline, battleSessionID: battleID, genuineProgressObserved: false))
        var confirmation = try #require(begin(&recovery, from: baseline, battleSessionID: battleID))
        #expect(!recovery.isEligible)
        #expect(begin(&recovery, from: baseline, battleSessionID: battleID) == nil)
        #expect(confirmation.stableDuration == 0)
        #expect(confirmation.stableSampleCount == 1)
        #expect(!confirmation.isComplete)
        for time in 31...34 {
            #expect(observe(&confirmation, at: Double(time)))
            #expect(!confirmation.isComplete)
        }
        #expect(observe(&confirmation, at: 35))
        #expect(confirmation.isComplete)
        let assessment = confirmation.validate(sample(at: 35.5), differenceFromAnchor: 0)
        #expect(assessment?.isConfirmedEvidence == true)
        #expect(assessment?.stableDuration == 5.5)
        #expect(assessment?.enemyHP == nil)
        #expect(assessment?.zeroPartyMembers == 0)
        // Issuing startup evidence never arms the normal progress-dependent detector.
        var normal = BattleStallDetector(configuration: configuration)
        _ = normal.automaticBattleEnabled(at: 0, context: context, inputGeneration: 7)
        #expect(normal.beginVisualConfirmation(from: baseline) == nil)
    }

    @Test("Observed combat activity permanently ends startup recovery eligibility")
    func genuineProgressSuppressesStartupRecovery() throws {
        for progressTime in [1.0, 30.0] {
            var recovery = try makeRecovery()
            for time in 1..<Int(progressTime) {
                #expect(update(&recovery, sample(at: Double(time)), battleSessionID: battleID,
                                         genuineProgressObserved: false))
            }
            #expect(!update(&recovery, sample(at: progressTime), battleSessionID: battleID,
                                      genuineProgressObserved: true))
            #expect(!update(&recovery, sample(at: progressTime + 1), battleSessionID: battleID,
                                      genuineProgressObserved: false))
            #expect(begin(&recovery, from: sample(at: 30), battleSessionID: battleID) == nil)
        }
    }

    @Test("Battle, modal, pause, anchor, identity and input changes cannot return to startup")
    func continuityFailuresArePermanent() throws {
        let changedContext = BattleWindowContext(
            processID: 123, windowID: 17, originX: 1, originY: 30, width: 406, height: 890
        )
        let invalidSamples: [(BattleStallSample, String?)] = [
            (sample(at: 1, battle: false), battleID),
            (sample(at: 1, modal: true), battleID),
            (sample(at: 1, paused: true), battleID),
            (sample(at: 1, strict: false), battleID),
            (sample(at: 1, context: changedContext), battleID),
            (sample(at: 1, generation: 8), battleID),
            (sample(at: 1), "another-battle"),
            (sample(at: 1), nil),
            (sample(at: 1), "  "),
        ]
        for (invalid, identity) in invalidSamples {
            var recovery = try makeRecovery()
            #expect(!update(&recovery, invalid, battleSessionID: identity, genuineProgressObserved: false))
            #expect(!recovery.isEligible)
            #expect(!update(&recovery, sample(at: 2), battleSessionID: battleID, genuineProgressObserved: false))
            #expect(begin(&recovery, from: sample(at: 30), battleSessionID: battleID) == nil)
        }
    }

    @Test("Missing pixels, invalid times and capture gaps cannot count toward startup waiting")
    func invalidSamplesFailClosed() throws {
        var invalid = [0.0, -1, 3.001, Double.nan, .infinity, -.infinity].map { sample(at: $0) }
        invalid += [nil, -0.001, Double.nan, .infinity, -.infinity].map { sample(at: 1, difference: $0) }
        for candidate in invalid {
            var recovery = try makeRecovery()
            #expect(!update(&recovery, candidate, battleSessionID: battleID, genuineProgressObserved: false))
            #expect(!update(&recovery, sample(at: 2), battleSessionID: battleID, genuineProgressObserved: false))
        }
        var exactBoundary = try makeRecovery()
        #expect(update(&exactBoundary, sample(at: 3), battleSessionID: battleID, genuineProgressObserved: false))
    }

    @Test("Only the latest stable frame can issue a confirmation, and motion resets the dense proof")
    func requiresCurrentStableBaseline() throws {
        var recovery = try readyRecovery(until: 29)
        let moving = sample(at: 30, difference: 0.02)
        #expect(update(&recovery, moving, battleSessionID: battleID, genuineProgressObserved: false))
        #expect(begin(&recovery, from: moving, battleSessionID: battleID) == nil)
        #expect(recovery.isEligible)
        let stable = sample(at: 31, difference: configuration.maximumStableROIDifference)
        #expect(update(&recovery, stable, battleSessionID: battleID, genuineProgressObserved: false))
        var confirmation = try #require(begin(&recovery, from: stable, battleSessionID: battleID))
        #expect(!observe(&confirmation, at: 32, anchor: 0.003))
        #expect(!observe(&confirmation, at: 33))
        #expect(!update(&recovery, sample(at: 34), battleSessionID: battleID, genuineProgressObserved: false))
        #expect(begin(&recovery, from: sample(at: 34), battleSessionID: battleID) == nil)

        for (candidate, identity) in [(sample(at: 29), battleID), (sample(at: 31), battleID),
                                      (sample(at: 30), "another-battle")] {
            var stale = try readyRecovery()
            #expect(begin(&stale, from: candidate, battleSessionID: identity) == nil)
            #expect(!stale.isEligible)
        }
    }

    @Test("Startup evidence still requires fresh strict classification at final retreat preflight")
    func freshPreflightRemainsMandatory() throws {
        for invalid in [sample(at: 36, battle: false), sample(at: 36, strict: false),
                        sample(at: 36, modal: true), sample(at: 36, generation: 8),
                        sample(at: 36, difference: 0.01)] {
            var recovery = try readyRecovery()
            var confirmation = try #require(begin(&recovery, from: sample(at: 30), battleSessionID: battleID))
            for time in 31...35 { #expect(observe(&confirmation, at: Double(time))) }
            #expect(confirmation.validate(invalid, differenceFromAnchor: 0) == nil)
            #expect(confirmation.validate(sample(at: 37), differenceFromAnchor: 0) == nil)
        }
    }

    @Test("A cancelled startup confirmation retains the original all-auto timeout")
    func cancelledConfirmationCannotExtendProgressDeadline() throws {
        var recovery = try readyRecovery()
        var validator = AllAutoProgressValidator()
        _ = validator.automaticBattleExpected(at: 0, battleSessionID: battleID)
        #expect(validator.observe(at: 30, battleSessionID: battleID, state: .battle,
                                  genuineProgressObserved: false) == .timedOut(battleSessionID: battleID))
        var confirmation = try #require(begin(&recovery, from: sample(at: 30), battleSessionID: battleID))
        // The runtime restores the original expectation while attempting bounded recovery.
        _ = validator.automaticBattleExpected(at: 0, battleSessionID: battleID)
        #expect(!observe(&confirmation, at: 31, anchor: 0.01))
        #expect(begin(&recovery, from: sample(at: 31), battleSessionID: battleID) == nil)
        #expect(validator.observe(at: 31, battleSessionID: battleID, state: .battle,
                                  genuineProgressObserved: false) == .timedOut(battleSessionID: battleID))

        // Actual progress or a result during the cancellation still resolves that expectation.
        _ = validator.automaticBattleExpected(at: 0, battleSessionID: battleID)
        #expect(validator.observe(at: 31, battleSessionID: battleID, state: .battle,
                                  genuineProgressObserved: true) == .validated(.genuineBattleProgress))
        _ = validator.automaticBattleExpected(at: 0, battleSessionID: battleID)
        #expect(validator.observe(at: 31, battleSessionID: battleID, state: .missionFailed,
                                  genuineProgressObserved: false) == .validated(.normalTransition(.missionFailed)))
    }

    @Test("Invalid startup observations and weaker time limits cannot enable recovery")
    func rejectsInvalidInitialization() {
        for initial in [sample(at: -1), sample(at: .nan), sample(at: 0, strict: false),
                        sample(at: 0, paused: true), sample(at: 0, modal: true),
                        sample(at: 0, battle: false), sample(at: 0, difference: -.infinity)] {
            #expect(StartupBattleRecovery(sample: initial, battleSessionID: battleID, configuration: configuration) == nil)
        }
        for duration in [29.9, 0, -1, Double.nan, .infinity] {
            #expect(StartupBattleRecovery(sample: sample(at: 0), battleSessionID: battleID,
                                          configuration: configuration, minimumObservationDuration: duration) == nil)
        }
        #expect(StartupBattleRecovery(sample: sample(at: 0), battleSessionID: "  ", configuration: configuration) == nil)
        var invalidConfiguration = configuration
        invalidConfiguration.maximumSampleGap = 0
        #expect(StartupBattleRecovery(sample: sample(at: 0), battleSessionID: battleID, configuration: invalidConfiguration) == nil)
    }

    private let battleID = "startup-battle"
    private let context = BattleWindowContext(
        processID: 123, windowID: 17, originX: 0, originY: 30, width: 406, height: 890
    )
    private var configuration: BattleStallConfiguration {
        .init(suspectedAfter: 3, confirmedAfter: 5, maximumSampleGap: 3,
              maximumStableROIDifference: 0.002, minimumStableSampleCount: 5)
    }
    private func makeRecovery() throws -> StartupBattleRecovery {
        try #require(StartupBattleRecovery(sample: sample(at: 0, difference: nil),
                                           battleSessionID: battleID, configuration: configuration))
    }
    private func readyRecovery(until end: Int = 30) throws -> StartupBattleRecovery {
        var recovery = try makeRecovery()
        for time in 1...end {
            #expect(update(&recovery, sample(at: Double(time)), battleSessionID: battleID,
                                     genuineProgressObserved: false))
        }
        return recovery
    }
    private func update(
        _ recovery: inout StartupBattleRecovery,
        _ sample: BattleStallSample,
        battleSessionID: String?,
        genuineProgressObserved: Bool
    ) -> Bool {
        recovery.observe(sample, battleSessionID: battleSessionID,
                         genuineProgressObserved: genuineProgressObserved)
    }
    private func begin(
        _ recovery: inout StartupBattleRecovery,
        from sample: BattleStallSample,
        battleSessionID: String
    ) -> BattleVisualStabilityConfirmation? {
        recovery.beginVisualConfirmation(from: sample, battleSessionID: battleSessionID)
    }
    private func observe(
        _ confirmation: inout BattleVisualStabilityConfirmation,
        at time: Double, anchor: Double = 0
    ) -> Bool {
        confirmation.observe(monotonicTime: time, context: context, inputGeneration: 7,
                             differenceFromPrevious: 0, differenceFromAnchor: anchor)
    }
    private func sample(
        at time: Double,
        difference: Double? = 0,
        context: BattleWindowContext? = nil,
        generation: UInt64 = 7,
        battle: Bool = true,
        modal: Bool = false,
        paused: Bool = false,
        strict: Bool = true
    ) -> BattleStallSample {
        let evidence = BattleStallFrameEvidence(
            background: .init(lootCandidates: 0, trustedLootAnchors: 0,
                              pauseCandidates: 1, trustedPauseAnchors: 1,
                              retreatCandidates: 1, trustedRetreatAnchors: 1,
                              automaticCandidates: 1, trustedAutomaticAnchors: 1,
                              visualControlsConfirmed: strict),
            enemyHP: nil, partyHP: [], combatLogSignature: ""
        )
        return .init(monotonicTime: time, context: context ?? self.context,
                     battleScreenConfirmed: battle, modalPresent: modal, paused: paused,
                     inputGeneration: generation, frameEvidence: evidence,
                     battleROIDifferenceFromPrevious: difference)
    }
}
