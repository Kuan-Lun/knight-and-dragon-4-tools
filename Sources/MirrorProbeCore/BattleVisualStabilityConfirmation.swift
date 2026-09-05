/// A bounded sequence of pixel comparisons issued only after normal battle activity was verified.
/// Pixel samples do not claim to contain fresh OCR evidence. A caller must validate a newer,
/// fully classified battle frame before using the result as recovery evidence.
public struct BattleVisualStabilityConfirmation: Sendable {
    private let configuration: BattleStallConfiguration
    private let context: BattleWindowContext
    private let inputGeneration: UInt64
    private let startedAt: Double
    private var lastTime: Double
    private var sampleCount = 1
    private var invalidated = false

    init(configuration: BattleStallConfiguration, baseline: BattleStallSample) {
        self.configuration = configuration
        context = baseline.context
        inputGeneration = baseline.inputGeneration
        startedAt = baseline.monotonicTime
        lastTime = baseline.monotonicTime
    }

    public var stableDuration: Double {
        invalidated ? 0 : lastTime - startedAt
    }

    public var stableSampleCount: Int {
        invalidated ? 0 : sampleCount
    }

    public var isComplete: Bool {
        !invalidated
            && stableDuration >= max(5, configuration.confirmedAfter)
            && sampleCount >= max(5, configuration.minimumStableSampleCount)
    }

    /// Returns whether this pixel sample was accepted, independently of `isComplete`.
    /// Every rejection permanently invalidates this confirmation, including after completion.
    /// Times must describe actual captures, not the completion of later OCR or processing work.
    @discardableResult
    public mutating func observe(
        monotonicTime: Double,
        context: BattleWindowContext,
        inputGeneration: UInt64,
        differenceFromPrevious: Double?,
        differenceFromAnchor: Double?
    ) -> Bool {
        guard !invalidated else { return false }
        guard monotonicTime.isFinite,
              monotonicTime >= 0,
              monotonicTime > lastTime,
              monotonicTime - lastTime <= configuration.maximumSampleGap,
              context.isValid,
              context == self.context,
              inputGeneration == self.inputGeneration,
              let differenceFromPrevious,
              differenceFromPrevious.isFinite,
              differenceFromPrevious >= 0,
              differenceFromPrevious <= configuration.maximumStableROIDifference,
              let differenceFromAnchor,
              differenceFromAnchor.isFinite,
              differenceFromAnchor >= 0,
              differenceFromAnchor <= configuration.maximumStableROIDifference
        else {
            invalidated = true
            return false
        }

        lastTime = monotonicTime
        sampleCount += 1
        return true
    }

    /// Revalidates fresh OCR and pixels, including during the final retreat preflight.
    /// This must be a new capture after the latest accepted pixel sample. A changed or unknown
    /// battle state revokes the confirmation; it cannot be reused if the battle later returns.
    public mutating func validate(
        _ sample: BattleStallSample,
        differenceFromAnchor: Double?
    ) -> BattleStallAssessment? {
        guard !invalidated else { return nil }
        guard sample.battleScreenConfirmed,
              !sample.modalPresent,
              !sample.paused,
              sample.frameEvidence.background.isStrict
        else {
            invalidated = true
            return nil
        }
        guard observe(
            monotonicTime: sample.monotonicTime,
            context: sample.context,
            inputGeneration: sample.inputGeneration,
            differenceFromPrevious: sample.battleROIDifferenceFromPrevious,
            differenceFromAnchor: differenceFromAnchor
        ), isComplete else {
            return nil
        }

        return BattleStallAssessment(
            phase: .confirmed,
            isArmed: true,
            stableDuration: stableDuration,
            stableSampleCount: stableSampleCount,
            zeroPartyMembers: sample.frameEvidence.zeroPartyMembers,
            enemyHP: sample.frameEvidence.enemyHP,
            strictBattleBackground: true,
            resetReason: nil
        )
    }
}
