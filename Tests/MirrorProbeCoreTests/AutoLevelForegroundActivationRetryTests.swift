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
                == .retry(nextAttempt: 2, delayMilliseconds: 250)
        )
        #expect(state.currentAttempt == 2)
        #expect(state.settleDelayMilliseconds == 600)
        #expect(
            state.recordUnpostedFocusFailure()
                == .retry(nextAttempt: 3, delayMilliseconds: 500)
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

    @Test("Only an unposted frontmost rejection may consume the retry budget")
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
}
