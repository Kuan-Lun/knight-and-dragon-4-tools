import Testing
@testable import MirrorProbeCore

@Suite("Foreground activation retry")
struct AutoLevelForegroundActivationRetryTests {
    @Test("Focus contention gets exactly three total attempts")
    func exhaustsAfterThreeAttempts() {
        var state = AutoLevelForegroundActivationRetryState()

        #expect(state.currentAttempt == 1)
        #expect(state.settleDelayMilliseconds == 350)
        #expect(
            state.recordUnpostedFocusFailure()
                == .retry(nextAttempt: 2, delayMilliseconds: 1_000)
        )
        #expect(state.currentAttempt == 2)
        #expect(state.settleDelayMilliseconds == 600)
        #expect(
            state.recordUnpostedFocusFailure()
                == .retry(nextAttempt: 3, delayMilliseconds: 1_000)
        )
        #expect(state.currentAttempt == 3)
        #expect(state.settleDelayMilliseconds == 900)
        #expect(
            state.recordUnpostedFocusFailure()
                == .exhausted(attempts: 3)
        )
        #expect(
            state.recordUnpostedFocusFailure()
                == .exhausted(attempts: 3)
        )
        #expect(state.currentAttempt == 3)
    }

    @Test("Every action starts with a fresh retry budget")
    func freshActionsHaveIndependentBudgets() {
        var first = AutoLevelForegroundActivationRetryState()
        _ = first.recordUnpostedFocusFailure()

        let second = AutoLevelForegroundActivationRetryState()
        #expect(first.currentAttempt == 2)
        #expect(second.currentAttempt == 1)
        #expect(second.settleDelayMilliseconds == 350)
    }

    @Test("Live AX focus wins over advisory activation and stale AppKit active flags", arguments: [
        (false, true, true, true),
        (true, true, true, true),
        (true, false, true, true),
        (false, false, true, true),
        (true, true, false, false),
        (false, true, false, false),
        (false, false, false, false),
    ])
    func observedFocusIsAuthoritative(
        activateReturned: Bool,
        targetApplicationIsActive: Bool,
        frontmostProcessMatches: Bool,
        expected: Bool
    ) {
        #expect(
            AutoLevelForegroundActivationRetryState.activationIsReady(
                activateReturned: activateReturned,
                targetApplicationIsActive: targetApplicationIsActive,
                frontmostProcessMatches: frontmostProcessMatches
            ) == expected
        )
    }

    @Test("Without obstruction observations only an unposted foreground focus failure retries")
    func retryableInputBoundaryRejectionsStayNarrow() {
        #expect(
            AutoLevelForegroundActivationRetryState.permitsRetry(
                after: .applicationNotFrontmost,
                inputWasPosted: false
            )
        )
        #expect(
            !AutoLevelForegroundActivationRetryState.permitsRetry(
                after: .applicationNotFrontmost,
                inputWasPosted: true
            )
        )
        #expect(
            !AutoLevelForegroundActivationRetryState.permitsRetry(
                after: .applicationNotFrontmost,
                inputWasPosted: false,
                inputMode: .process
            )
        )

        let terminalRejections: [AutoLevelInputRejection] = [
            .stopRequested,
            .invalidTiming,
            .actionAuthorizationExpired,
            .sessionRuntimeExpired,
            .windowUnavailable,
            .windowIdentityChanged,
            .windowGeometryChanged,
            .clickPointObscured,
        ]
        for rejection in terminalRejections {
            #expect(
                !AutoLevelForegroundActivationRetryState.permitsRetry(
                    after: rejection,
                    inputWasPosted: false
                )
            )
        }
    }

    @Test("A focused target covered by another process stays rejected but may retry")
    func externalObstructionAllowsOnlyANewAttempt() throws {
        let snapshot = obstructionSnapshot()
        let rejection = try #require(safetyRejection(snapshot: snapshot))

        #expect(rejection == .clickPointObscured)
        #expect(AutoLevelForegroundActivationRetryState.permitsRetry(
            after: rejection,
            inputWasPosted: false,
            expectedWindowIdentity: identity,
            snapshot: snapshot
        ))
        // The retry policy does not relax the safety check for the rejected snapshot.
        #expect(safetyRejection(snapshot: snapshot) == .clickPointObscured)
    }

    @Test("Persistent external obstruction exhausts the same three-attempt budget")
    func persistentExternalObstructionIsBounded() throws {
        var state = AutoLevelForegroundActivationRetryState()
        let snapshot = obstructionSnapshot()
        let decisions: [AutoLevelForegroundActivationRetryDecision] = [
            .retry(nextAttempt: 2, delayMilliseconds: 1_000),
            .retry(nextAttempt: 3, delayMilliseconds: 1_000),
            .exhausted(attempts: 3),
        ]

        for expectedDecision in decisions {
            let rejection = try #require(safetyRejection(snapshot: snapshot))
            #expect(rejection == .clickPointObscured)
            #expect(AutoLevelForegroundActivationRetryState.permitsRetry(
                after: rejection,
                inputWasPosted: false,
                expectedWindowIdentity: identity,
                snapshot: snapshot
            ))
            #expect(state.recordUnpostedFocusFailure() == expectedDecision)
        }
        #expect(state.currentAttempt == 3)
        #expect(state.recordUnpostedFocusFailure() == .exhausted(attempts: 3))
    }

    @Test("Focus contention and external obstruction consume one shared budget")
    func contentionReasonsShareBudget() throws {
        var state = AutoLevelForegroundActivationRetryState()
        #expect(AutoLevelForegroundActivationRetryState.permitsRetry(
            after: .applicationNotFrontmost,
            inputWasPosted: false
        ))
        #expect(state.recordUnpostedFocusFailure() == .retry(nextAttempt: 2, delayMilliseconds: 1_000))

        let snapshot = obstructionSnapshot()
        let rejection = try #require(safetyRejection(snapshot: snapshot))
        #expect(AutoLevelForegroundActivationRetryState.permitsRetry(
            after: rejection,
            inputWasPosted: false,
            expectedWindowIdentity: identity,
            snapshot: snapshot
        ))
        #expect(state.recordUnpostedFocusFailure() == .retry(nextAttempt: 3, delayMilliseconds: 1_000))
        #expect(state.recordUnpostedFocusFailure() == .exhausted(attempts: 3))
    }

    @Test("Only a fresh unobscured snapshot can authorize input after recovery")
    func clearedObstructionNeedsFreshAuthorization() throws {
        let obscured = obstructionSnapshot()
        let rejection = try #require(safetyRejection(snapshot: obscured))
        #expect(AutoLevelForegroundActivationRetryState.permitsRetry(
            after: rejection,
            inputWasPosted: false,
            expectedWindowIdentity: identity,
            snapshot: obscured
        ))

        let freshSnapshot = obstructionSnapshot(topmostWindowIdentity: identity)
        #expect(safetyRejection(snapshot: obscured) == .clickPointObscured)
        #expect(safetyRejection(snapshot: freshSnapshot) == nil)
    }

    @Test("Obstruction retries require every identity and ordering observation")
    func obstructionVetoMatrix() {
        let competingTargetWindow = AutoLevelWindowIdentity(
            processID: identity.processID, windowID: identity.windowID + 1
        )
        let ineligibleSnapshots: [AutoLevelInputSnapshot?] = [
            nil,
            obstructionSnapshot(windowIdentity: nil),
            obstructionSnapshot(windowIdentity: otherWindow),
            obstructionSnapshot(windowIdentity: competingTargetWindow),
            obstructionSnapshot(frontmostProcessID: nil),
            obstructionSnapshot(frontmostProcessID: otherWindow.processID),
            obstructionSnapshot(targetProcessTopmostWindowIdentity: nil),
            obstructionSnapshot(targetProcessTopmostWindowIdentity: competingTargetWindow),
            obstructionSnapshot(targetProcessTopmostWindowIdentity: otherWindow),
            obstructionSnapshot(topmostWindowIdentity: nil),
            obstructionSnapshot(topmostWindowIdentity: competingTargetWindow),
            obstructionSnapshot(topmostWindowIdentity: identity),
        ]
        for snapshot in ineligibleSnapshots {
            #expect(!AutoLevelForegroundActivationRetryState.permitsRetry(
                after: .clickPointObscured,
                inputWasPosted: false,
                expectedWindowIdentity: identity,
                snapshot: snapshot
            ))
        }

        let eligibleSnapshot = obstructionSnapshot()
        #expect(!AutoLevelForegroundActivationRetryState.permitsRetry(
            after: .clickPointObscured,
            inputWasPosted: false,
            expectedWindowIdentity: nil,
            snapshot: eligibleSnapshot
        ))
        #expect(!AutoLevelForegroundActivationRetryState.permitsRetry(
            after: .clickPointObscured,
            inputWasPosted: false,
            inputMode: .process,
            expectedWindowIdentity: identity,
            snapshot: eligibleSnapshot
        ))
        #expect(!AutoLevelForegroundActivationRetryState.permitsRetry(
            after: .clickPointObscured,
            inputWasPosted: true,
            expectedWindowIdentity: identity,
            snapshot: eligibleSnapshot
        ))
    }

    @Test("A covering external window never makes other safety failures retryable")
    func otherRejectionsRemainTerminal() {
        let terminalRejections: [AutoLevelInputRejection] = [
            .stopRequested,
            .invalidTiming,
            .actionAuthorizationExpired,
            .sessionRuntimeExpired,
            .windowUnavailable,
            .windowIdentityChanged,
            .windowGeometryChanged,
        ]
        for rejection in terminalRejections {
            #expect(!AutoLevelForegroundActivationRetryState.permitsRetry(
                after: rejection,
                inputWasPosted: false,
                expectedWindowIdentity: identity,
                snapshot: obstructionSnapshot()
            ))
        }
    }

    private let identity = AutoLevelWindowIdentity(processID: 99, windowID: 7)
    private let otherWindow = AutoLevelWindowIdentity(processID: 98, windowID: 8)
    private let geometry = AutoLevelWindowGeometry(x: 40, y: 80, width: 300, height: 650)

    private func obstructionSnapshot(
        windowIdentity: AutoLevelWindowIdentity? = AutoLevelWindowIdentity(processID: 99, windowID: 7),
        frontmostProcessID: Int32? = 99,
        topmostWindowIdentity: AutoLevelWindowIdentity? = AutoLevelWindowIdentity(processID: 98, windowID: 8),
        targetProcessTopmostWindowIdentity: AutoLevelWindowIdentity? = AutoLevelWindowIdentity(processID: 99, windowID: 7)
    ) -> AutoLevelInputSnapshot {
        AutoLevelInputSnapshot(
            windowIdentity: windowIdentity,
            windowGeometry: geometry,
            frontmostProcessID: frontmostProcessID,
            topmostWindowIdentity: topmostWindowIdentity,
            targetProcessTopmostWindowIdentity: targetProcessTopmostWindowIdentity
        )
    }

    private func safetyRejection(snapshot: AutoLevelInputSnapshot) -> AutoLevelInputRejection? {
        AutoLevelInputSafety.rejection(
            expectedWindowIdentity: identity,
            expectedWindowGeometry: geometry,
            snapshot: snapshot,
            now: 100,
            actionDeadline: 112,
            sessionDeadline: 200,
            stopRequested: false
        )
    }
}
