import Testing
@testable import MirrorProbeCore

@Suite("Auto-level capture retention")
struct AutoLevelCaptureRetentionTests {
    @Test("An empty recent-capture buffer has no elements")
    func emptyBuffer() {
        let buffer = RecentCaptureBuffer<Int>()

        #expect(buffer.capacity == 8)
        #expect(buffer.count == 0)
        #expect(buffer.isEmpty)
        #expect(buffer.elementsOldestFirst.isEmpty)
    }

    @Test("Fewer than eight captures preserve insertion order")
    func partiallyFilledBuffer() {
        var buffer = RecentCaptureBuffer<Int>()
        for value in 1...5 {
            #expect(buffer.append(value) == nil)
        }

        #expect(buffer.count == 5)
        #expect(buffer.elementsOldestFirst == [1, 2, 3, 4, 5])
    }

    @Test("Exactly eight captures fill the buffer without eviction")
    func exactlyFullBuffer() {
        var buffer = RecentCaptureBuffer<Int>()
        for value in 1...8 {
            #expect(buffer.append(value) == nil)
        }

        #expect(buffer.count == 8)
        #expect(buffer.elementsOldestFirst == Array(1...8))
    }

    @Test("The ninth capture evicts only the oldest capture")
    func overflowingBuffer() {
        var buffer = RecentCaptureBuffer<Int>()
        for value in 1...8 {
            buffer.append(value)
        }

        #expect(buffer.append(9) == 1)
        #expect(buffer.count == 8)
        #expect(buffer.elementsOldestFirst == Array(2...9))
    }

    @Test("Sixteen captures leave captures nine through sixteen in chronological order")
    func repeatedWraparound() {
        var buffer = RecentCaptureBuffer<Int>()
        for value in 1...16 {
            buffer.append(value)
        }

        #expect(buffer.count == 8)
        #expect(buffer.elementsOldestFirst == Array(9...16))
    }

    @Test("Captures with the same fingerprint remain distinct temporal samples")
    func duplicateFingerprintsAreNotDeduplicated() {
        struct Token: Equatable {
            let sequence: Int
            let fingerprint: String
        }

        var buffer = RecentCaptureBuffer<Token>()
        buffer.append(Token(sequence: 1, fingerprint: "same"))
        buffer.append(Token(sequence: 2, fingerprint: "same"))

        #expect(buffer.elementsOldestFirst.map(\.sequence) == [1, 2])
        #expect(buffer.elementsOldestFirst.map(\.fingerprint) == ["same", "same"])
    }

    @Test("Copies have independent value semantics after mutation")
    func copySemantics() {
        var original = RecentCaptureBuffer<Int>()
        for value in 1...8 {
            original.append(value)
        }
        var copy = original

        #expect(copy.append(9) == 1)

        #expect(original.elementsOldestFirst == Array(1...8))
        #expect(copy.elementsOldestFirst == Array(2...9))
    }

    @Test("Equality compares chronological content rather than circular storage layout")
    func logicalEquality() {
        var wrapped = RecentCaptureBuffer<Int>()
        for value in 1...9 {
            wrapped.append(value)
        }
        var freshlyFilled = RecentCaptureBuffer<Int>()
        for value in 2...9 {
            freshlyFilled.append(value)
        }

        #expect(wrapped == freshlyFilled)
    }

    @Test("Error-level expected limits and user stops retain no screenshots")
    func errorRoutineTerminationsRetainNothing() {
        let policy = AutoLevelCaptureRetentionPolicy(level: .error)

        for termination in [
            AutoLevelCaptureTerminationKind.expectedLimit,
            .userStop,
        ] {
            let plan = policy.plan(for: termination)
            #expect(plan == AutoLevelCaptureRetentionPlan(
                retainsInitial: false,
                retainsActionPairs: false,
                retainsRecent: false,
                retainsFinal: false
            ))
            #expect(!plan.retainsAnyScreenshot)
        }
    }

    @Test("Error-level safety stops and runtime errors retain recent and final evidence")
    func errorDiagnosticTerminationsRetainEvidence() {
        let policy = AutoLevelCaptureRetentionPolicy(level: .error)

        for termination in [
            AutoLevelCaptureTerminationKind.safetyStop,
            .runtimeError,
        ] {
            #expect(policy.plan(for: termination) == AutoLevelCaptureRetentionPlan(
                retainsInitial: false,
                retainsActionPairs: false,
                retainsRecent: true,
                retainsFinal: true
            ))
        }
    }

    @Test("Info-level expected limits and user stops retain the audit trail and final frame")
    func infoRoutineTerminationsRetainAuditTrail() {
        let policy = AutoLevelCaptureRetentionPolicy(level: .info)

        for termination in [
            AutoLevelCaptureTerminationKind.expectedLimit,
            .userStop,
        ] {
            #expect(policy.plan(for: termination) == AutoLevelCaptureRetentionPlan(
                retainsInitial: true,
                retainsActionPairs: true,
                retainsRecent: false,
                retainsFinal: true
            ))
        }
    }

    @Test("Info-level diagnostic terminations retain audit, recent, and final frames")
    func infoDiagnosticTerminationsRetainEverything() {
        let policy = AutoLevelCaptureRetentionPolicy(level: .info)

        for termination in [
            AutoLevelCaptureTerminationKind.safetyStop,
            .runtimeError,
        ] {
            #expect(policy.plan(for: termination) == AutoLevelCaptureRetentionPlan(
                retainsInitial: true,
                retainsActionPairs: true,
                retainsRecent: true,
                retainsFinal: true
            ))
        }
    }
}
