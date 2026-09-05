import Foundation

public struct AllAutoProgressValidationConfiguration: Codable, Equatable, Sendable {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 30) {
        self.timeout = timeout
    }

    public var isValid: Bool {
        timeout.isFinite && timeout > 0
    }
}

public enum AllAutoProgressValidationEvidence: Equatable, Sendable {
    /// A BattleStallDetector armed from a pixel-corroborated HP or combat-log transition.
    case genuineBattleProgress
    /// A mission result which proves that the expected automatic battle finished between polls.
    case normalTransition(GameState)
}

public enum AllAutoProgressValidationAssessment: Equatable, Sendable {
    case inactive
    case awaitingProgress(elapsed: TimeInterval, remaining: TimeInterval)
    case validated(AllAutoProgressValidationEvidence)
    case timedOut(battleSessionID: String)
    case invalidSample
}

/// Bounded validation for a battle which is expected to be running in `全部自動` mode. The
/// expectation may come from the game's configured default or from a successfully posted input.
/// This type never emits an action and therefore cannot toggle the control. The runtime supplies
/// genuine progress only after its temporal battle detector has independently armed.
public struct AllAutoProgressValidator: Sendable {
    public let configuration: AllAutoProgressValidationConfiguration

    private var pending: Pending?

    public init(
        configuration: AllAutoProgressValidationConfiguration = .init()
    ) {
        self.configuration = configuration
    }

    public var isAwaitingProgress: Bool { pending != nil }

    @discardableResult
    public mutating func automaticBattleExpected(
        at monotonicTime: TimeInterval,
        battleSessionID: String
    ) -> AllAutoProgressValidationAssessment {
        pending = nil
        let normalizedID = battleSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard configuration.isValid,
              monotonicTime.isFinite,
              monotonicTime >= 0,
              !normalizedID.isEmpty
        else {
            return .invalidSample
        }

        pending = Pending(
            startedAt: monotonicTime,
            battleSessionID: normalizedID
        )
        return .awaitingProgress(elapsed: 0, remaining: configuration.timeout)
    }

    /// Compatibility entry point for the supervised/clicked-auto pathway.
    @discardableResult
    public mutating func automaticBattlePosted(
        at monotonicTime: TimeInterval,
        battleSessionID: String
    ) -> AllAutoProgressValidationAssessment {
        automaticBattleExpected(
            at: monotonicTime,
            battleSessionID: battleSessionID
        )
    }

    public mutating func observe(
        at monotonicTime: TimeInterval,
        battleSessionID: String?,
        state: GameState,
        genuineProgressObserved: Bool
    ) -> AllAutoProgressValidationAssessment {
        guard let pending else { return .inactive }
        guard monotonicTime.isFinite,
              monotonicTime >= pending.startedAt
        else {
            self.pending = nil
            return .invalidSample
        }

        if Self.isNormalFastTransition(state) {
            self.pending = nil
            return .validated(.normalTransition(state))
        }

        let normalizedID = battleSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if genuineProgressObserved,
           normalizedID == pending.battleSessionID
        {
            self.pending = nil
            return .validated(.genuineBattleProgress)
        }

        let elapsed = monotonicTime - pending.startedAt
        if elapsed >= configuration.timeout,
           Self.isUnresolvedBattleFamily(state)
        {
            self.pending = nil
            return .timedOut(battleSessionID: pending.battleSessionID)
        }

        return .awaitingProgress(
            elapsed: elapsed,
            remaining: max(0, configuration.timeout - elapsed)
        )
    }

    public mutating func reset() {
        pending = nil
    }

    private static func isNormalFastTransition(_ state: GameState) -> Bool {
        switch state {
        case .missionComplete, .missionCompleteRepeatSelected,
             .missionFailed, .missionFailedRepeatSelected:
            return true
        default:
            return false
        }
    }

    private static func isUnresolvedBattleFamily(_ state: GameState) -> Bool {
        switch state {
        case .battle, .defeat, .retreatConfirmation:
            return true
        default:
            return false
        }
    }

    private struct Pending: Sendable {
        let startedAt: TimeInterval
        let battleSessionID: String
    }
}
