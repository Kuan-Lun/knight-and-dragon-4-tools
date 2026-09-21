import Foundation

public enum AutoLevelForegroundDeferralReason: String, Equatable, Sendable {
    /// The focused application could not be read, so no focus borrow was attempted.
    case focusUnavailable
    /// iPhone Mirroring was activated, yet another process owned focus at the preflight.
    case focusContended
}

public struct AutoLevelForegroundDeferralRecovery: Equatable, Sendable {
    public let deferredActions: Int
    public let unavailableSeconds: TimeInterval

    public init(deferredActions: Int, unavailableSeconds: TimeInterval) {
        self.deferredActions = deferredActions
        self.unavailableSeconds = unavailableSeconds
    }
}

public enum AutoLevelForegroundDeferralDecision: Equatable, Sendable {
    case deferred(deferredActions: Int, unavailableSeconds: TimeInterval, backoffSeconds: TimeInterval)
    case exhausted(deferredActions: Int, unavailableSeconds: TimeInterval)
    case invalidClock
}

/// Bounded patience for foreground focus that is unavailable or contended before any input.
///
/// An unposted action that spent its activation attempts is discarded instead of the run. The
/// caller resumes observations, and a later request is minted from a newer frame and validated
/// from scratch. An episode starts at the first deferral and ends when a preflight confirms that
/// the target owns focus again, or when deferrals stop for longer than `episodeGapSeconds`
/// because no click was needed. Patience is measured within one episode, so quiet stretches
/// without any click never count as unavailability.
public struct AutoLevelForegroundDeferralState: Equatable, Sendable {
    public static let maximumUnavailableSeconds: TimeInterval = 120
    public static let backoffSeconds: [TimeInterval] = [5, 10, 20, 30]
    public static let episodeGapSeconds: TimeInterval = 300

    public private(set) var unavailableSince: TimeInterval?
    public private(set) var lastDeferralAt: TimeInterval?
    public private(set) var deferredActions = 0

    public init() {}

    public var isDeferring: Bool { unavailableSince != nil }

    /// Records one discarded action. An invalid or backwards clock fails closed.
    public mutating func recordDeferral(
        at now: TimeInterval
    ) -> AutoLevelForegroundDeferralDecision {
        guard now.isFinite, now >= 0, lastDeferralAt.map({ now >= $0 }) ?? true else {
            return .invalidClock
        }
        if let lastDeferralAt, now - lastDeferralAt > Self.episodeGapSeconds {
            unavailableSince = nil
            deferredActions = 0
        }
        let since = unavailableSince ?? now
        unavailableSince = since
        lastDeferralAt = now
        deferredActions += 1
        let unavailableSeconds = now - since
        guard unavailableSeconds < Self.maximumUnavailableSeconds else {
            return .exhausted(deferredActions: deferredActions, unavailableSeconds: unavailableSeconds)
        }
        let backoff = Self.backoffSeconds[min(deferredActions, Self.backoffSeconds.count) - 1]
        return .deferred(
            deferredActions: deferredActions,
            unavailableSeconds: unavailableSeconds,
            backoffSeconds: backoff
        )
    }

    /// Ends the episode once a preflight observed the target owning focus. Returns the episode
    /// summary for the caller's report, or nil when nothing was deferred.
    public mutating func recordForegroundAvailable(
        at now: TimeInterval
    ) -> AutoLevelForegroundDeferralRecovery? {
        guard let unavailableSince else { return nil }
        let recovery = AutoLevelForegroundDeferralRecovery(
            deferredActions: deferredActions,
            unavailableSeconds: now.isFinite && now >= unavailableSince ? now - unavailableSince : 0
        )
        self.unavailableSince = nil
        lastDeferralAt = nil
        deferredActions = 0
        return recovery
    }
}
