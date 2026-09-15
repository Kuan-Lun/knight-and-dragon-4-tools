import Foundation

/// A one-shot recovery candidate for a battle that was already frozen when the runner started.
/// The caller may construct this only from the session's first observation. It cannot establish
/// normal combat progress or arm the regular stall detector: recovery still needs a separate
/// dense visual confirmation and a fresh classified retreat preflight.
public struct StartupBattleRecovery: Sendable {
    private let configuration: BattleStallConfiguration
    private let minimumObservationDuration: Double
    private let battleSessionID: String
    private let initialSample: BattleStallSample
    private var latestSample: BattleStallSample
    public private(set) var isEligible = true

    public init?(
        sample: BattleStallSample,
        battleSessionID: String,
        configuration: BattleStallConfiguration,
        minimumObservationDuration: Double = 30
    ) {
        let normalizedID = battleSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard configuration.isValid,
              minimumObservationDuration.isFinite,
              minimumObservationDuration >= 30,
              !normalizedID.isEmpty,
              Self.isTrustedBattleSample(sample),
              sample.battleROIDifferenceFromPrevious.map({ $0.isFinite && $0 >= 0 }) != false
        else { return nil }

        self.configuration = configuration
        self.minimumObservationDuration = minimumObservationDuration
        self.battleSessionID = normalizedID
        initialSample = sample
        latestSample = sample
    }

    /// Every observation must be supplied, including state changes. A boundary violation or
    /// verified activity permanently removes startup eligibility even if the old frame returns.
    /// Scene motion alone is not treated as verified combat activity; the later confirmation
    /// independently requires five seconds of consecutive and fixed-anchor pixel stability.
    @discardableResult
    public mutating func observe(
        _ sample: BattleStallSample,
        battleSessionID: String?,
        genuineProgressObserved: Bool
    ) -> Bool {
        guard isEligible else { return false }
        guard !genuineProgressObserved,
              battleSessionID?.trimmingCharacters(in: .whitespacesAndNewlines) == self.battleSessionID,
              Self.isTrustedBattleSample(sample),
              sample.context == initialSample.context,
              sample.inputGeneration == initialSample.inputGeneration,
              sample.monotonicTime > latestSample.monotonicTime,
              sample.monotonicTime - latestSample.monotonicTime <= configuration.maximumSampleGap,
              let difference = sample.battleROIDifferenceFromPrevious,
              difference.isFinite,
              difference >= 0
        else {
            isEligible = false
            return false
        }

        latestSample = sample
        return true
    }

    /// Consumes the sole startup attempt. The initial observation period never contributes to
    /// the dense confirmation's stable duration, and the unverified startup candidate itself
    /// never supplies a confirmed stall assessment.
    public mutating func beginVisualConfirmation(
        from sample: BattleStallSample,
        battleSessionID: String
    ) -> BattleVisualStabilityConfirmation? {
        guard isEligible else { return nil }
        guard battleSessionID.trimmingCharacters(in: .whitespacesAndNewlines) == self.battleSessionID,
              sample == latestSample
        else {
            isEligible = false
            return nil
        }
        guard sample.monotonicTime - initialSample.monotonicTime >= minimumObservationDuration,
              let difference = sample.battleROIDifferenceFromPrevious,
              difference <= configuration.maximumStableROIDifference
        else { return nil }

        isEligible = false
        return BattleVisualStabilityConfirmation(configuration: configuration, baseline: sample)
    }

    private static func isTrustedBattleSample(_ sample: BattleStallSample) -> Bool {
        sample.monotonicTime.isFinite
            && sample.monotonicTime >= 0
            && sample.context.isValid
            && sample.battleScreenConfirmed
            && !sample.modalPresent
            && !sample.paused
            && sample.frameEvidence.background.isStrict
    }
}
