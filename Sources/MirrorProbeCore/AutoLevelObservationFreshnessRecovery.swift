import Foundation

public enum AutoLevelObservationFreshnessDecision: Equatable, Sendable {
    case fresh
    case recapture(attempt: Int)
    case exhausted
    case invalidTiming
}

/// Rejects observations that grew stale during capture analysis before requesting new input.
/// Recapture never refreshes the timestamp or authorizes an action from the rejected frame.
/// The caller must acquire and classify another frame while retaining session and action limits.
public struct AutoLevelObservationFreshnessRecovery: Sendable {
    public let maximumAgeSeconds: TimeInterval
    public let maximumRecaptures: Int
    private var consecutiveRecaptures = 0

    public init(maximumAgeSeconds: TimeInterval = 12, maximumRecaptures: Int = 2) {
        self.maximumAgeSeconds = maximumAgeSeconds
        self.maximumRecaptures = maximumRecaptures
    }

    public mutating func evaluate(
        capturedAt: TimeInterval,
        now: TimeInterval
    ) -> AutoLevelObservationFreshnessDecision {
        guard maximumAgeSeconds.isFinite, maximumAgeSeconds > 0,
              maximumRecaptures > 0,
              capturedAt.isFinite, capturedAt >= 0,
              now.isFinite, now >= capturedAt
        else {
            return .invalidTiming
        }

        let age = now - capturedAt
        guard age.isFinite else { return .invalidTiming }
        if age < maximumAgeSeconds {
            consecutiveRecaptures = 0
            return .fresh
        }

        guard consecutiveRecaptures < maximumRecaptures else { return .exhausted }
        consecutiveRecaptures += 1
        return .recapture(attempt: consecutiveRecaptures)
    }
}
