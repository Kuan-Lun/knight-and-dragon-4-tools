import Foundation

public struct BattleActivityProgressConfiguration: Codable, Equatable, Sendable {
    public var minimumCorroboratingROIDifference: Double
    public var maximumSampleGap: TimeInterval
    public var maximumHPPositionDeltaX: Double
    public var maximumHPPositionDeltaY: Double

    public init(
        minimumCorroboratingROIDifference: Double = 0.002,
        maximumSampleGap: TimeInterval = 10,
        maximumHPPositionDeltaX: Double = 0.04,
        maximumHPPositionDeltaY: Double = 0.025
    ) {
        self.minimumCorroboratingROIDifference = minimumCorroboratingROIDifference
        self.maximumSampleGap = maximumSampleGap
        self.maximumHPPositionDeltaX = maximumHPPositionDeltaX
        self.maximumHPPositionDeltaY = maximumHPPositionDeltaY
    }

    public var isValid: Bool {
        minimumCorroboratingROIDifference.isFinite
            && minimumCorroboratingROIDifference >= 0
            && maximumSampleGap.isFinite
            && maximumSampleGap > 0
            && maximumHPPositionDeltaX.isFinite
            && maximumHPPositionDeltaX >= 0
            && maximumHPPositionDeltaY.isFinite
            && maximumHPPositionDeltaY >= 0
    }
}

public struct BattleActivityHPReading: Equatable, Sendable {
    public let hitPoints: BattleHitPoints
    public let rect: NormalizedRect

    public init(hitPoints: BattleHitPoints, rect: NormalizedRect) {
        self.hitPoints = hitPoints
        self.rect = rect
    }
}

/// A less brittle ordinary-combat signature than `BattleStallFrameEvidence`. It still requires
/// the strict battle background, but it can use any complete, stable-position HP reading or the
/// bounded combat-log region; it never supplies terminal-defeat evidence.
public struct BattleActivityFrameEvidence: Equatable, Sendable {
    public let hasStrictBattleBackground: Bool
    public let hpReadings: [BattleActivityHPReading]
    public let combatLogSignature: String

    public init(
        hasStrictBattleBackground: Bool,
        hpReadings: [BattleActivityHPReading],
        combatLogSignature: String
    ) {
        self.hasStrictBattleBackground = hasStrictBattleBackground
        self.hpReadings = hpReadings
        self.combatLogSignature = combatLogSignature
    }

    public static func extract(
        from observations: [OCRTextObservation]
    ) -> BattleActivityFrameEvidence {
        let stallEvidence = BattleStallFrameEvidence.extract(from: observations)
        let hpReadings = observations.compactMap { observation -> BattleActivityHPReading? in
            guard observation.rect.isValid,
                  observation.confidence.isFinite,
                  observation.confidence >= 0.60,
                  let hitPoints = BattleHitPoints.parse(observation.text)
            else {
                return nil
            }
            let center = observation.rect.center
            guard (0.02...0.98).contains(center.x),
                  (0.25...0.86).contains(center.y)
            else {
                return nil
            }
            return BattleActivityHPReading(hitPoints: hitPoints, rect: observation.rect)
        }
        return BattleActivityFrameEvidence(
            hasStrictBattleBackground: stallEvidence.background.isStrict,
            hpReadings: hpReadings,
            combatLogSignature: stallEvidence.combatLogSignature
        )
    }

    fileprivate var hasUsableSignature: Bool {
        hasStrictBattleBackground
            && (!hpReadings.isEmpty || !combatLogSignature.isEmpty)
    }
}

public struct BattleActivityProgressSample: Equatable, Sendable {
    public let monotonicTime: TimeInterval
    public let battleSessionID: String
    public let context: BattleWindowContext
    public let inputGeneration: UInt64
    public let evidence: BattleActivityFrameEvidence
    public let battleROIDifferenceFromPrevious: Double?

    public init(
        monotonicTime: TimeInterval,
        battleSessionID: String,
        context: BattleWindowContext,
        inputGeneration: UInt64,
        evidence: BattleActivityFrameEvidence,
        battleROIDifferenceFromPrevious: Double?
    ) {
        self.monotonicTime = monotonicTime
        self.battleSessionID = battleSessionID
        self.context = context
        self.inputGeneration = inputGeneration
        self.evidence = evidence
        self.battleROIDifferenceFromPrevious = battleROIDifferenceFromPrevious
    }
}

public enum BattleActivityProgressAssessment: Equatable, Sendable {
    case inactive
    case awaitingEvidence
    case progressObserved

    public var didObserveProgress: Bool { self == .progressObserved }
}

/// Detects acknowledgement-quality activity after a battle is expected to be in `全部自動`
/// mode, without weakening the much stricter stalled-defeat detector. Pixel movement alone is
/// insufficient: it must corroborate a changed combat-log signature or an HP value at the same
/// screen position and maximum HP.
public struct BattleActivityProgressDetector: Sendable {
    public let configuration: BattleActivityProgressConfiguration

    private var activation: Activation?
    private var previousSample: BattleActivityProgressSample?
    private var progressObserved = false

    public init(
        configuration: BattleActivityProgressConfiguration = .init()
    ) {
        self.configuration = configuration
    }

    @discardableResult
    public mutating func automaticBattleExpected(
        at monotonicTime: TimeInterval,
        battleSessionID: String,
        context: BattleWindowContext,
        inputGeneration: UInt64
    ) -> BattleActivityProgressAssessment {
        clearState()
        let normalizedID = battleSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard configuration.isValid,
              monotonicTime.isFinite,
              monotonicTime >= 0,
              !normalizedID.isEmpty,
              context.isValid
        else {
            return .inactive
        }
        activation = Activation(
            monotonicTime: monotonicTime,
            battleSessionID: normalizedID,
            context: context,
            inputGeneration: inputGeneration
        )
        return .awaitingEvidence
    }

    /// Compatibility entry point for the supervised/clicked-auto pathway.
    @discardableResult
    public mutating func automaticBattlePosted(
        at monotonicTime: TimeInterval,
        battleSessionID: String,
        context: BattleWindowContext,
        inputGeneration: UInt64
    ) -> BattleActivityProgressAssessment {
        automaticBattleExpected(
            at: monotonicTime,
            battleSessionID: battleSessionID,
            context: context,
            inputGeneration: inputGeneration
        )
    }

    public mutating func observe(
        _ sample: BattleActivityProgressSample
    ) -> BattleActivityProgressAssessment {
        guard let activation else { return .inactive }
        let normalizedID = sample.battleSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sample.monotonicTime.isFinite,
              sample.monotonicTime > activation.monotonicTime,
              previousSample.map({ sample.monotonicTime > $0.monotonicTime }) != false,
              sample.context.isValid,
              sample.battleROIDifferenceFromPrevious.map({ $0.isFinite && $0 >= 0 }) != false,
              normalizedID == activation.battleSessionID,
              sample.context == activation.context,
              sample.inputGeneration == activation.inputGeneration
        else {
            clearState()
            return .inactive
        }
        if progressObserved { return .progressObserved }

        guard sample.evidence.hasUsableSignature else {
            previousSample = nil
            return .awaitingEvidence
        }
        guard let previous = previousSample else {
            previousSample = sample
            return .awaitingEvidence
        }
        guard sample.monotonicTime - previous.monotonicTime <= configuration.maximumSampleGap else {
            previousSample = sample
            return .awaitingEvidence
        }

        let pixelsCorroborateChange = sample.battleROIDifferenceFromPrevious.map {
            $0 > configuration.minimumCorroboratingROIDifference
        } == true
        let logChanged = !previous.evidence.combatLogSignature.isEmpty
            && !sample.evidence.combatLogSignature.isEmpty
            && previous.evidence.combatLogSignature != sample.evidence.combatLogSignature
        let hpChanged = hasStablePositionHPChange(
            from: previous.evidence.hpReadings,
            to: sample.evidence.hpReadings
        )
        previousSample = sample
        if pixelsCorroborateChange && (logChanged || hpChanged) {
            progressObserved = true
            return .progressObserved
        }
        return .awaitingEvidence
    }

    public mutating func reset() {
        clearState()
    }

    private func hasStablePositionHPChange(
        from previous: [BattleActivityHPReading],
        to current: [BattleActivityHPReading]
    ) -> Bool {
        previous.contains { oldReading in
            let oldCenter = oldReading.rect.center
            let matches = current.filter { newReading in
                let newCenter = newReading.rect.center
                return abs(oldCenter.x - newCenter.x) <= configuration.maximumHPPositionDeltaX
                    && abs(oldCenter.y - newCenter.y) <= configuration.maximumHPPositionDeltaY
                    && oldReading.hitPoints.maximum == newReading.hitPoints.maximum
            }
            guard matches.count == 1, let newReading = matches.first else { return false }
            return oldReading.hitPoints.current != newReading.hitPoints.current
        }
    }

    private mutating func clearState() {
        activation = nil
        previousSample = nil
        progressObserved = false
    }

    private struct Activation: Sendable {
        let monotonicTime: TimeInterval
        let battleSessionID: String
        let context: BattleWindowContext
        let inputGeneration: UInt64
    }
}
