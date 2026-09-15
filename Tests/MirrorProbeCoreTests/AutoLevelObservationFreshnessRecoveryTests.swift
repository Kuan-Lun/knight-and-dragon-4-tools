import Foundation
import Testing
@testable import MirrorProbeCore

@Suite("Observation freshness recovery")
struct AutoLevelObservationFreshnessRecoveryTests {
    @Test("A roughly 55-second analysis delay discards the frame and a fresh capture resets recovery")
    func slowAnalysisThenFreshCapture() {
        var recovery = AutoLevelObservationFreshnessRecovery()
        let capturedAt = 1173.050503458362
        #expect(recovery.evaluate(capturedAt: capturedAt, now: capturedAt + 55) == .recapture(attempt: 1))
        #expect(recovery.evaluate(capturedAt: capturedAt + 56, now: capturedAt + 56.2) == .fresh)
        #expect(recovery.evaluate(capturedAt: 1300, now: 1355) == .recapture(attempt: 1))
    }

    @Test("Persistently slow fresh captures allow only two recaptures before exhaustion")
    func persistentStalenessIsBounded() {
        var recovery = AutoLevelObservationFreshnessRecovery()
        #expect(recovery.evaluate(capturedAt: 100, now: 155) == .recapture(attempt: 1))
        #expect(recovery.evaluate(capturedAt: 156, now: 211) == .recapture(attempt: 2))
        #expect(recovery.evaluate(capturedAt: 212, now: 267) == .exhausted)
        #expect(recovery.evaluate(capturedAt: 268, now: 323) == .exhausted)
    }

    @Test("An observation at the age limit is stale, while zero age and just under the limit are fresh")
    func exactAgeBoundary() {
        var recovery = AutoLevelObservationFreshnessRecovery()
        #expect(recovery.evaluate(capturedAt: 100, now: 100) == .fresh)
        #expect(recovery.evaluate(capturedAt: 100, now: 111.999) == .fresh)
        #expect(recovery.evaluate(capturedAt: 100, now: 112) == .recapture(attempt: 1))
    }

    @Test("Reevaluating the same old frame does not rewrite its capture time or restore freshness")
    func recaptureDecisionDoesNotRenewOldFrame() {
        var recovery = AutoLevelObservationFreshnessRecovery()
        let capturedAt = 100.0
        #expect(recovery.evaluate(capturedAt: capturedAt, now: 155) == .recapture(attempt: 1))
        #expect(recovery.evaluate(capturedAt: capturedAt, now: 156) == .recapture(attempt: 2))
        #expect(recovery.evaluate(capturedAt: capturedAt, now: 157) == .exhausted)
    }

    @Test("Fresh evidence resets even an exhausted consecutive streak")
    func freshResetsExhaustedStreak() {
        var recovery = AutoLevelObservationFreshnessRecovery(maximumRecaptures: 1)
        #expect(recovery.evaluate(capturedAt: 100, now: 113) == .recapture(attempt: 1))
        #expect(recovery.evaluate(capturedAt: 114, now: 127) == .exhausted)
        #expect(recovery.evaluate(capturedAt: 128, now: 129) == .fresh)
        #expect(recovery.evaluate(capturedAt: 130, now: 143) == .recapture(attempt: 1))
    }

    @Test("Custom positive timing and recapture bounds are honored")
    func customConfiguration() {
        var recovery = AutoLevelObservationFreshnessRecovery(maximumAgeSeconds: 2, maximumRecaptures: 1)
        #expect(recovery.evaluate(capturedAt: 100, now: 101) == .fresh)
        #expect(recovery.evaluate(capturedAt: 100, now: 102) == .recapture(attempt: 1))
        #expect(recovery.evaluate(capturedAt: 103, now: 105) == .exhausted)
    }

    @Test("Invalid configuration fails closed without issuing a recapture")
    func invalidConfiguration() {
        let invalidAges: [TimeInterval] = [0, -1, .nan, .infinity, -.infinity]
        for age in invalidAges {
            var recovery = AutoLevelObservationFreshnessRecovery(maximumAgeSeconds: age)
            #expect(recovery.evaluate(capturedAt: 100, now: 100) == .invalidTiming)
        }
        for limit in [0, -1] {
            var recovery = AutoLevelObservationFreshnessRecovery(maximumRecaptures: limit)
            #expect(recovery.evaluate(capturedAt: 100, now: 100) == .invalidTiming)
        }
    }

    @Test("Negative, future, NaN, and infinite timestamps fail closed and do not reset recovery")
    func invalidTimestamps() {
        let invalidTimes: [(TimeInterval, TimeInterval)] = [
            (-1, 100), (0, -1), (-2, -1), (101, 100),
            (.nan, 100), (100, .nan), (.infinity, 100), (100, .infinity),
            (-.infinity, 100), (100, -.infinity), (.infinity, .infinity),
        ]
        var recovery = AutoLevelObservationFreshnessRecovery()
        #expect(recovery.evaluate(capturedAt: 100, now: 155) == .recapture(attempt: 1))
        for (capturedAt, now) in invalidTimes {
            #expect(recovery.evaluate(capturedAt: capturedAt, now: now) == .invalidTiming)
        }
        #expect(recovery.evaluate(capturedAt: 200, now: 255) == .recapture(attempt: 2))
        #expect(recovery.evaluate(capturedAt: 300, now: 355) == .exhausted)
    }
}
