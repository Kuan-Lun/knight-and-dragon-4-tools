import Foundation

/// One fresh visual observation used by the narrowly scoped obscured-footer recovery policy.
public struct BattleRecognitionRecoverySample: Sendable {
    public let classification: GameStateClassification
    public let runtime: AutoLevelRuntimeMetadata
    public let context: BattleWindowContext
    public let inputGeneration: UInt64

    public init(
        classification: GameStateClassification,
        runtime: AutoLevelRuntimeMetadata,
        context: BattleWindowContext,
        inputGeneration: UInt64
    ) {
        self.classification = classification
        self.runtime = runtime
        self.context = context
        self.inputGeneration = inputGeneration
    }

    fileprivate var isValid: Bool {
        runtime.observedAt.isFinite
            && runtime.observedAt >= 0
            && !runtime.frameFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && runtime.battleSessionID.map {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } == true
            && context.isValid
            && context.processID == runtime.windowIdentity.processID
            && context.windowID == runtime.windowIdentity.windowID
    }

    fileprivate func hasSameContinuity(as other: Self) -> Bool {
        context == other.context
            && inputGeneration == other.inputGeneration
            && runtime.windowIdentity == other.runtime.windowIdentity
            && runtime.battleSessionID == other.runtime.battleSessionID
    }
}

/// Temporal authorization bound to the exact observation which completed the waiting period.
/// Pixel motion is allowed: this policy recovers failed recognition, not a frozen battle.
public struct BattleRecognitionRecoveryAssessment: Sendable {
    public let elapsedSeconds: TimeInterval
    private let sample: BattleRecognitionRecoverySample

    public var isReady: Bool { elapsedSeconds >= BattleRecognitionRecovery.minimumDuration }

    fileprivate init(sample: BattleRecognitionRecoverySample, elapsedSeconds: TimeInterval) {
        self.sample = sample
        self.elapsedSeconds = elapsedSeconds
    }

    /// An assessment must not authorize a different page, capture, battle or window.
    public func matches(_ snapshot: AutoLevelSnapshot) -> Bool {
        snapshot.classification == sample.classification
            && VisualBattleEvidence.hasRecoverableFooterOcclusion(in: snapshot.classification)
            && snapshot.runtime.observedAt == sample.runtime.observedAt
            && snapshot.runtime.frameFingerprint == sample.runtime.frameFingerprint
            && snapshot.runtime.battleSessionID == sample.runtime.battleSessionID
            && snapshot.runtime.windowIdentity == sample.runtime.windowIdentity
    }

    /// Final input authorization always requires a newer capture which still measures retreat.
    /// An unchanged fingerprint is valid when fresh captures contain identical pixels.
    public func canPreflight(_ fresh: BattleRecognitionRecoverySample) -> Bool {
        isReady
            && fresh.isValid
            && fresh.hasSameContinuity(as: sample)
            && fresh.runtime.observedAt > sample.runtime.observedAt
            && fresh.runtime.observedAt - sample.runtime.observedAt < 12
            && VisualBattleEvidence.hasRecoverableFooterOcclusion(in: fresh.classification)
    }
}

/// Allows retreat only after a measured battle is followed by 30 seconds of consecutive,
/// otherwise unrecognized frames whose footer is obscured but whose retreat button is measured.
/// A lost button, modal, result, capture gap, or input/window boundary revokes the entire chain.
public struct BattleRecognitionRecovery: Sendable {
    public static let minimumDuration: TimeInterval = 30
    public static let maximumSampleGap: TimeInterval = 5

    private var latestSample: BattleRecognitionRecoverySample?
    private var firstOccludedAt: TimeInterval?

    public init() {}

    public mutating func observe(
        _ sample: BattleRecognitionRecoverySample
    ) -> BattleRecognitionRecoveryAssessment? {
        guard sample.isValid else {
            reset()
            return nil
        }
        if let previous = latestSample {
            guard sample.runtime.observedAt > previous.runtime.observedAt else {
                reset()
                return nil
            }
            if !sample.hasSameContinuity(as: previous)
                || sample.runtime.observedAt - previous.runtime.observedAt > Self.maximumSampleGap
            {
                reset()
            }
        }

        if VisualBattleEvidence.hasRunningBattleEvidence(in: sample.classification) {
            latestSample = sample
            firstOccludedAt = nil
            return nil
        }
        guard latestSample != nil,
              VisualBattleEvidence.hasRecoverableFooterOcclusion(in: sample.classification)
        else {
            reset()
            return nil
        }

        let startedAt = firstOccludedAt ?? sample.runtime.observedAt
        firstOccludedAt = startedAt
        latestSample = sample
        return BattleRecognitionRecoveryAssessment(
            sample: sample,
            elapsedSeconds: sample.runtime.observedAt - startedAt
        )
    }

    public mutating func reset() {
        latestSample = nil
        firstOccludedAt = nil
    }
}
