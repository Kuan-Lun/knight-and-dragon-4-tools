import Foundation

public struct BattleHitPoints: Codable, Equatable, Sendable {
    public let current: Int
    public let maximum: Int

    public init?(current: Int, maximum: Int) {
        guard current >= 0, maximum > 0, current <= maximum else { return nil }
        self.current = current
        self.maximum = maximum
    }

    /// Parses a complete OCR HP token such as `0/9046`, `7128/14K`, or `423789/701K`.
    /// Missing digits and trailing OCR noise are rejected instead of guessed.
    public static func parse(_ text: String) -> BattleHitPoints? {
        let token = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        let pattern = #"^([0-9]+)/(?:([0-9]+(?:\.[0-9]+)?)([KkMm]?))$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: token,
                range: NSRange(token.startIndex..., in: token)
              ),
              match.range == NSRange(token.startIndex..., in: token),
              let currentRange = Range(match.range(at: 1), in: token),
              let maximumRange = Range(match.range(at: 2), in: token),
              let current = Int(token[currentRange]),
              let maximumBase = Double(token[maximumRange])
        else {
            return nil
        }

        let suffix: String
        if let suffixRange = Range(match.range(at: 3), in: token) {
            suffix = String(token[suffixRange]).uppercased()
        } else {
            suffix = ""
        }
        let multiplier: Double
        switch suffix {
        case "": multiplier = 1
        case "K": multiplier = 1_000
        case "M": multiplier = 1_000_000
        default: return nil
        }

        let scaledMaximum = maximumBase * multiplier
        guard scaledMaximum.isFinite,
              scaledMaximum.rounded() == scaledMaximum,
              scaledMaximum <= Double(Int.max)
        else {
            return nil
        }
        return BattleHitPoints(current: current, maximum: Int(scaledMaximum))
    }
}

public struct BattleStallBackgroundEvidence: Codable, Equatable, Sendable {
    public let lootCandidates: Int
    public let trustedLootAnchors: Int
    public let pauseCandidates: Int
    public let trustedPauseAnchors: Int
    public let retreatCandidates: Int
    public let trustedRetreatAnchors: Int
    public let automaticCandidates: Int
    public let trustedAutomaticAnchors: Int

    public init(
        lootCandidates: Int,
        trustedLootAnchors: Int,
        pauseCandidates: Int,
        trustedPauseAnchors: Int,
        retreatCandidates: Int,
        trustedRetreatAnchors: Int,
        automaticCandidates: Int,
        trustedAutomaticAnchors: Int
    ) {
        self.lootCandidates = lootCandidates
        self.trustedLootAnchors = trustedLootAnchors
        self.pauseCandidates = pauseCandidates
        self.trustedPauseAnchors = trustedPauseAnchors
        self.retreatCandidates = retreatCandidates
        self.trustedRetreatAnchors = trustedRetreatAnchors
        self.automaticCandidates = automaticCandidates
        self.trustedAutomaticAnchors = trustedAutomaticAnchors
    }

    public var isStrict: Bool {
        lootCandidates == 1
            && trustedLootAnchors == 1
            && pauseCandidates == 1
            && trustedPauseAnchors == 1
            && retreatCandidates == 1
            && trustedRetreatAnchors == 1
            && automaticCandidates == 1
            && trustedAutomaticAnchors == 1
    }
}

public struct BattleStallFrameEvidence: Codable, Equatable, Sendable {
    public let background: BattleStallBackgroundEvidence
    public let enemyHP: BattleHitPoints?
    /// Fixed order: top-left, top-middle, top-right, bottom-left, bottom-middle, bottom-right.
    /// An empty array means extraction did not find exactly one valid reading in every slot.
    public let partyHP: [BattleHitPoints]
    public let combatLogSignature: String

    public init(
        background: BattleStallBackgroundEvidence,
        enemyHP: BattleHitPoints?,
        partyHP: [BattleHitPoints],
        combatLogSignature: String
    ) {
        self.background = background
        self.enemyHP = enemyHP
        self.partyHP = partyHP
        self.combatLogSignature = combatLogSignature
    }

    public var zeroPartyMembers: Int {
        partyHP.filter { $0.current == 0 }.count
    }

    public var hasCompleteDefeatCandidateEvidence: Bool {
        background.isStrict
            && enemyHP.map { $0.current > 0 } == true
            && partyHP.count == 6
            && zeroPartyMembers >= 5
            && !combatLogSignature.isEmpty
    }

    /// Extracts only complete, layout-constrained readings. Ambiguous, missing, truncated,
    /// misplaced, or duplicated HP observations deliberately produce incomplete evidence.
    public static func extract(
        from observations: [OCRTextObservation]
    ) -> BattleStallFrameEvidence {
        let valid = observations.filter {
            $0.rect.isValid
                && $0.confidence.isFinite
                && (0...1).contains($0.confidence)
                && !canonicalBattleText($0.text).isEmpty
        }

        let loot = valid.filter {
            let text = canonicalBattleText($0.text)
            return text.hasPrefix("戰利品") || text.hasPrefix("利品")
        }
        let pause = valid.filter { canonicalBattleText($0.text) == "暫停" }
        let retreat = valid.filter { canonicalBattleText($0.text) == "撤退" }
        let automatic = valid.filter { canonicalBattleText($0.text) == "全部自動" }
        let background = BattleStallBackgroundEvidence(
            lootCandidates: loot.count,
            trustedLootAnchors: loot.filter {
                // Vision can lose the leading 戰 beside the talisman header. The measured
                // 利品 reading needs a higher confidence floor and the same unique location;
                // all three independent battle controls remain mandatory.
                let minimumConfidence = canonicalBattleText($0.text).hasPrefix("戰利品") ? 0.30 : 0.50
                return $0.confidence >= minimumConfidence
                    && rectCenter($0.rect, isInside: (0.75...0.98, 0.08...0.15))
            }.count,
            pauseCandidates: pause.count,
            trustedPauseAnchors: pause.filter {
                // Active animations repeatedly give this fixed label exactly 0.50. It remains
                // only one member of the strict loot/pause/retreat/all-auto fingerprint.
                $0.confidence >= 0.50 && rectCenter($0.rect, isInside: (0.75...0.98, 0.59...0.67))
            }.count,
            retreatCandidates: retreat.count,
            trustedRetreatAnchors: retreat.filter {
                $0.confidence >= 0.50 && rectCenter($0.rect, isInside: (0.75...0.98, 0.63...0.72))
            }.count,
            automaticCandidates: automatic.count,
            trustedAutomaticAnchors: automatic.filter {
                $0.confidence >= 0.60 && rectCenter($0.rect, isInside: (0.15...0.45, 0.84...0.91))
            }.count
        )

        let hpObservations = valid.compactMap { observation -> ParsedHPObservation? in
            guard observation.confidence >= 0.30,
                  let hp = BattleHitPoints.parse(observation.text)
            else { return nil }
            return ParsedHPObservation(observation: observation, hp: hp)
        }

        let enemyCandidates = hpObservations.filter {
            rectCenter($0.observation.rect, isInside: (0.35...0.78, 0.53...0.62))
        }
        let enemyHP = enemyCandidates.count == 1 ? enemyCandidates[0].hp : nil

        let columnRanges: [ClosedRange<Double>] = [0.05...0.38, 0.38...0.70, 0.70...0.99]
        let rowRanges: [ClosedRange<Double>] = [0.70...0.785, 0.785...0.86]
        var partyHP: [BattleHitPoints] = []
        for row in rowRanges {
            for column in columnRanges {
                let matches = hpObservations.filter {
                    rectCenter($0.observation.rect, isInside: (column, row))
                }
                guard matches.count == 1 else {
                    partyHP.removeAll()
                    break
                }
                partyHP.append(matches[0].hp)
            }
            if partyHP.isEmpty { break }
        }

        let logLines = valid.filter {
            let center = $0.rect.center
            return center.x < 0.78 && (0.625...0.705).contains(center.y)
        }.sorted {
            let left = $0.rect.center
            let right = $1.rect.center
            let leftRow = Int(floor(left.y * 500))
            let rightRow = Int(floor(right.y * 500))
            if leftRow != rightRow { return leftRow < rightRow }
            if left.x != right.x { return left.x < right.x }
            return canonicalBattleText($0.text) < canonicalBattleText($1.text)
        }.map { canonicalBattleText($0.text) }

        return BattleStallFrameEvidence(
            background: background,
            enemyHP: enemyHP,
            partyHP: partyHP,
            combatLogSignature: logLines.joined(separator: "|")
        )
    }
}

public struct BattleWindowContext: Codable, Equatable, Sendable {
    public let processID: Int32
    public let windowID: UInt32
    public let originX: Double
    public let originY: Double
    public let width: Int
    public let height: Int
    public let scaleFactor: Double

    public init(
        processID: Int32,
        windowID: UInt32,
        originX: Double,
        originY: Double,
        width: Int,
        height: Int,
        scaleFactor: Double = 1
    ) {
        self.processID = processID
        self.windowID = windowID
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
        self.scaleFactor = scaleFactor
    }

    public var isValid: Bool {
        processID > 0
            && windowID > 0
            && originX.isFinite
            && originY.isFinite
            && width > 0
            && height > 0
            && scaleFactor.isFinite
            && scaleFactor > 0
    }
}

public struct BattleStallSample: Codable, Equatable, Sendable {
    public let monotonicTime: Double
    public let context: BattleWindowContext
    /// True only when the current frame was classified as the complete battle screen.
    /// Unknown and modal frames must never contribute time to a visual-stability candidate.
    public let battleScreenConfirmed: Bool
    public let modalPresent: Bool
    public let paused: Bool
    public let inputGeneration: UInt64
    public let frameEvidence: BattleStallFrameEvidence
    /// Difference against the immediately preceding captured frame, measured only in
    /// `BattleStallDetector.battleROI`. It is nil for the first frame in a sequence.
    public let battleROIDifferenceFromPrevious: Double?

    public init(
        monotonicTime: Double,
        context: BattleWindowContext,
        battleScreenConfirmed: Bool = true,
        modalPresent: Bool,
        paused: Bool,
        inputGeneration: UInt64,
        frameEvidence: BattleStallFrameEvidence,
        battleROIDifferenceFromPrevious: Double?
    ) {
        self.monotonicTime = monotonicTime
        self.context = context
        self.battleScreenConfirmed = battleScreenConfirmed
        self.modalPresent = modalPresent
        self.paused = paused
        self.inputGeneration = inputGeneration
        self.frameEvidence = frameEvidence
        self.battleROIDifferenceFromPrevious = battleROIDifferenceFromPrevious
    }
}

public enum BattleStallPhase: String, Codable, Equatable, Sendable {
    case inactive
    case awaitingProgress
    case monitoring
    case suspected
    case confirmed
}

public enum BattleStallResetReason: String, Codable, Equatable, Sendable {
    case explicitlyReset
    case invalidSample
    case outOfOrderTime
    case sampleGap
    case windowOrGeometryChanged
    case inputGenerationChanged
    case modalObserved
    case paused
    case incompleteBattleEvidence
    case battleProgress
}

public struct BattleStallAssessment: Codable, Equatable, Sendable {
    public let phase: BattleStallPhase
    public let isArmed: Bool
    public let stableDuration: Double
    public let stableSampleCount: Int
    public let zeroPartyMembers: Int
    public let enemyHP: BattleHitPoints?
    public let strictBattleBackground: Bool
    public let resetReason: BattleStallResetReason?

    /// This remains evidence only. A runtime must apply a separate policy and authorization
    /// before performing any input; the detector contains no target or click API.
    public var isConfirmedEvidence: Bool { phase == .confirmed }
}

/// Opaque evidence that this detector observed genuine battle progress after automatic battle
/// was enabled. A runtime may retain it across a failed OCR sample, but must additionally bind it
/// to its own battle-session identity before asking the detector to resume.
public struct BattleStallProgressResumeState: Equatable, Sendable {
    public let context: BattleWindowContext
    public let inputGeneration: UInt64
    public let progressObservedAt: Double

    fileprivate init(
        context: BattleWindowContext,
        inputGeneration: UInt64,
        progressObservedAt: Double
    ) {
        self.context = context
        self.inputGeneration = inputGeneration
        self.progressObservedAt = progressObservedAt
    }
}

public struct BattleStallConfiguration: Codable, Equatable, Sendable {
    public var suspectedAfter: Double
    public var confirmedAfter: Double
    public var maximumSampleGap: Double
    public var maximumStableROIDifference: Double
    public var minimumStableSampleCount: Int

    public init(
        suspectedAfter: Double = 30,
        confirmedAfter: Double = 60,
        maximumSampleGap: Double = 45,
        maximumStableROIDifference: Double = 0.002,
        minimumStableSampleCount: Int = 2
    ) {
        self.suspectedAfter = suspectedAfter
        self.confirmedAfter = confirmedAfter
        self.maximumSampleGap = maximumSampleGap
        self.maximumStableROIDifference = maximumStableROIDifference
        self.minimumStableSampleCount = minimumStableSampleCount
    }

    public var isValid: Bool {
        suspectedAfter.isFinite
            && suspectedAfter > 0
            && confirmedAfter.isFinite
            && confirmedAfter >= suspectedAfter
            && maximumSampleGap.isFinite
            && maximumSampleGap > 0
            && maximumStableROIDifference.isFinite
            && maximumStableROIDifference >= 0
            && minimumStableSampleCount >= 2
    }
}

/// A deterministic state machine. It owns no clock and emits no input; callers supply a
/// monotonic timestamp and the generation of their own input stream with every observation.
public struct BattleStallDetector: Sendable {
    /// Excludes the changing iPhone status bar/clock and the bottom skill tray.
    public static let battleROI = NormalizedRect(x: 0.02, y: 0.09, width: 0.96, height: 0.79)

    public let configuration: BattleStallConfiguration

    private var activation: Activation?
    private var lastSample: BattleStallSample?
    private var genuineProgressObserved = false
    private var candidateStartedAt: Double?
    private var stableSampleCount = 0

    public init(configuration: BattleStallConfiguration = BattleStallConfiguration()) {
        self.configuration = configuration
    }

    /// Available only after normal combat progress was independently verified. The state carries
    /// no stall candidate or elapsed stable time, so resuming from it cannot turn an observation
    /// gap into evidence that the terminal frame was stable during that gap.
    public var progressResumeState: BattleStallProgressResumeState? {
        guard genuineProgressObserved,
              let activation,
              let lastSample
        else {
            return nil
        }
        return BattleStallProgressResumeState(
            context: activation.context,
            inputGeneration: activation.inputGeneration,
            progressObservedAt: lastSample.monotonicTime
        )
    }

    /// Starts a new pixel-only confirmation from a trusted battle frame. It carries no time
    /// from earlier observations and never grants progress verification to an unarmed detector.
    public func beginVisualConfirmation(
        from sample: BattleStallSample
    ) -> BattleVisualStabilityConfirmation? {
        guard genuineProgressObserved,
              let activation,
              configuration.isValid,
              activation.monotonicTime.isFinite,
              activation.monotonicTime >= 0,
              sample.monotonicTime.isFinite,
              sample.monotonicTime >= activation.monotonicTime,
              lastSample.map({ sample.monotonicTime >= $0.monotonicTime }) != false,
              sample.context.isValid,
              sample.context == activation.context,
              sample.inputGeneration == activation.inputGeneration,
              sample.battleScreenConfirmed,
              !sample.modalPresent,
              !sample.paused,
              sample.frameEvidence.background.isStrict,
              sample.battleROIDifferenceFromPrevious.map({ $0.isFinite && $0 >= 0 }) != false
        else {
            return nil
        }
        return BattleVisualStabilityConfirmation(configuration: configuration, baseline: sample)
    }

    /// Arms monitoring after the runtime establishes that this battle is expected to be in
    /// `全部自動` mode, either from the game's configured default or a posted input.
    public mutating func automaticBattleEnabled(
        at monotonicTime: Double,
        context: BattleWindowContext,
        inputGeneration: UInt64
    ) -> BattleStallAssessment {
        clearState()
        guard configuration.isValid, monotonicTime.isFinite, context.isValid else {
            return assessment(phase: .inactive, resetReason: .invalidSample)
        }
        activation = Activation(
            monotonicTime: monotonicTime,
            context: context,
            inputGeneration: inputGeneration
        )
        return assessment(phase: .awaitingProgress)
    }

    /// Arms visual-stability monitoring from the runtime's independently verified normal-battle
    /// activity. The verification is bound to the same window context and input generation; no
    /// HP value is needed after this point. Starting with an empty temporal baseline prevents the
    /// activity frame itself from contributing to a later frozen-screen duration.
    public mutating func markVerifiedNormalBattleProgress(
        at monotonicTime: Double,
        context: BattleWindowContext,
        inputGeneration: UInt64
    ) -> BattleStallAssessment {
        clearState()
        guard configuration.isValid, monotonicTime.isFinite, context.isValid else {
            return assessment(phase: .inactive, resetReason: .invalidSample)
        }
        activation = Activation(
            monotonicTime: monotonicTime,
            context: context,
            inputGeneration: inputGeneration
        )
        genuineProgressObserved = true
        return assessment(phase: .monitoring)
    }

    /// Resumes an independently established progress latch after an incomplete or late sample.
    /// The caller must bind `state` to the same battle-session ID outside this detector. Context
    /// and input generation are checked here, and the stable-frame candidate always starts empty.
    public mutating func resumeMonitoring(
        from state: BattleStallProgressResumeState,
        at monotonicTime: Double,
        context: BattleWindowContext,
        inputGeneration: UInt64
    ) -> BattleStallAssessment {
        clearState()
        guard configuration.isValid,
              monotonicTime.isFinite,
              context.isValid,
              monotonicTime > state.progressObservedAt
        else {
            return assessment(phase: .inactive, resetReason: .invalidSample)
        }
        guard context == state.context else {
            return assessment(phase: .inactive, resetReason: .windowOrGeometryChanged)
        }
        guard inputGeneration == state.inputGeneration else {
            return assessment(phase: .inactive, resetReason: .inputGenerationChanged)
        }

        activation = Activation(
            monotonicTime: monotonicTime,
            context: context,
            inputGeneration: inputGeneration
        )
        genuineProgressObserved = true
        return assessment(phase: .monitoring)
    }

    public mutating func reset(
        reason: BattleStallResetReason = .explicitlyReset
    ) -> BattleStallAssessment {
        clearState()
        return assessment(phase: .inactive, resetReason: reason)
    }

    public mutating func observe(_ sample: BattleStallSample) -> BattleStallAssessment {
        guard let activation else {
            return assessment(phase: .inactive)
        }
        guard sample.monotonicTime.isFinite,
              sample.context.isValid,
              sample.battleROIDifferenceFromPrevious.map({ $0.isFinite && $0 >= 0 }) != false
        else {
            return reset(reason: .invalidSample)
        }
        guard sample.monotonicTime > activation.monotonicTime,
              lastSample.map({ sample.monotonicTime > $0.monotonicTime }) != false
        else {
            return reset(reason: .outOfOrderTime)
        }
        guard sample.context == activation.context else {
            return reset(reason: .windowOrGeometryChanged)
        }
        guard sample.inputGeneration == activation.inputGeneration else {
            return reset(reason: .inputGenerationChanged)
        }
        if sample.modalPresent {
            return reset(reason: .modalObserved)
        }
        if sample.paused {
            return reset(reason: .paused)
        }
        guard sample.battleScreenConfirmed else {
            return reset(reason: .incompleteBattleEvidence)
        }
        if let previous = lastSample,
           sample.monotonicTime - previous.monotonicTime > configuration.maximumSampleGap {
            return reset(reason: .sampleGap)
        }
        guard sample.frameEvidence.background.isStrict else {
            return reset(reason: .incompleteBattleEvidence)
        }

        if genuineProgressObserved {
            return observeVerifiedVisualStability(sample)
        }

        guard sample.frameEvidence.enemyHP != nil,
              sample.frameEvidence.partyHP.count == 6,
              !sample.frameEvidence.combatLogSignature.isEmpty
        else {
            return reset(reason: .incompleteBattleEvidence)
        }

        guard let previous = lastSample else {
            lastSample = sample
            return assessment(
                phase: genuineProgressObserved ? .monitoring : .awaitingProgress,
                evidence: sample.frameEvidence
            )
        }

        let previousSignature = progressSignature(of: previous.frameEvidence)
        let currentSignature = progressSignature(of: sample.frameEvidence)
        let progressChanged = previousSignature != currentSignature
        if progressChanged {
            let pixelChangeCorroborated = sample.battleROIDifferenceFromPrevious.map {
                $0 > configuration.maximumStableROIDifference
            } == true
            let corroboratedHPChange = pixelChangeCorroborated
                && (previousSignature.enemyHP != currentSignature.enemyHP
                    || previousSignature.partyHP != currentSignature.partyHP)
            let corroboratedLogChange = pixelChangeCorroborated
                && previousSignature.combatLogSignature != currentSignature.combatLogSignature
            let genuineProgressChanged = corroboratedHPChange || corroboratedLogChange
            genuineProgressObserved = genuineProgressObserved || genuineProgressChanged
            candidateStartedAt = nil
            stableSampleCount = 0
            lastSample = sample
            return assessment(
                phase: genuineProgressObserved ? .monitoring : .awaitingProgress,
                evidence: sample.frameEvidence,
                resetReason: genuineProgressChanged ? .battleProgress : nil
            )
        }

        lastSample = sample
        return assessment(
            phase: .awaitingProgress,
            evidence: sample.frameEvidence
        )
    }

    /// Once normal automatic combat was verified independently, a frozen battle is detected by
    /// dense, consecutive image comparisons. HP OCR remains diagnostic only: changing pixels
    /// reset the candidate, while missing or varying HP text cannot prevent recovery.
    private mutating func observeVerifiedVisualStability(
        _ sample: BattleStallSample
    ) -> BattleStallAssessment {
        guard let previous = lastSample else {
            lastSample = sample
            candidateStartedAt = nil
            stableSampleCount = 0
            return assessment(phase: .monitoring, evidence: sample.frameEvidence)
        }
        lastSample = sample

        guard let roiDifference = sample.battleROIDifferenceFromPrevious,
              roiDifference <= configuration.maximumStableROIDifference
        else {
            candidateStartedAt = nil
            stableSampleCount = 0
            return assessment(
                phase: .monitoring,
                evidence: sample.frameEvidence,
                resetReason: .battleProgress
            )
        }

        if candidateStartedAt == nil {
            candidateStartedAt = previous.monotonicTime
            stableSampleCount = 2
        } else {
            stableSampleCount += 1
        }
        let duration = max(0, sample.monotonicTime - (candidateStartedAt ?? sample.monotonicTime))
        let hasEnoughSamples = stableSampleCount >= configuration.minimumStableSampleCount
        let phase: BattleStallPhase
        if hasEnoughSamples, duration >= configuration.confirmedAfter {
            phase = .confirmed
        } else if hasEnoughSamples, duration >= configuration.suspectedAfter {
            phase = .suspected
        } else {
            phase = .monitoring
        }
        return assessment(
            phase: phase,
            evidence: sample.frameEvidence,
            stableDuration: duration
        )
    }

    private mutating func clearState() {
        activation = nil
        lastSample = nil
        genuineProgressObserved = false
        candidateStartedAt = nil
        stableSampleCount = 0
    }

    private func assessment(
        phase: BattleStallPhase,
        evidence: BattleStallFrameEvidence? = nil,
        stableDuration: Double = 0,
        resetReason: BattleStallResetReason? = nil
    ) -> BattleStallAssessment {
        BattleStallAssessment(
            phase: phase,
            isArmed: genuineProgressObserved && activation != nil,
            stableDuration: stableDuration,
            stableSampleCount: stableSampleCount,
            zeroPartyMembers: evidence?.zeroPartyMembers ?? 0,
            enemyHP: evidence?.enemyHP,
            strictBattleBackground: evidence?.background.isStrict ?? false,
            resetReason: resetReason
        )
    }

    private func progressSignature(
        of evidence: BattleStallFrameEvidence
    ) -> ProgressSignature {
        ProgressSignature(
            enemyHP: evidence.enemyHP,
            partyHP: evidence.partyHP,
            combatLogSignature: evidence.combatLogSignature
        )
    }

    private struct Activation: Sendable {
        let monotonicTime: Double
        let context: BattleWindowContext
        let inputGeneration: UInt64
    }

    private struct ProgressSignature: Equatable {
        let enemyHP: BattleHitPoints?
        let partyHP: [BattleHitPoints]
        let combatLogSignature: String
    }
}

private struct ParsedHPObservation {
    let observation: OCRTextObservation
    let hp: BattleHitPoints
}

private func canonicalBattleText(_ text: String) -> String {
    text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "\u{3000}", with: "")
}

private func rectCenter(
    _ rect: NormalizedRect,
    isInside ranges: (ClosedRange<Double>, ClosedRange<Double>)
) -> Bool {
    ranges.0.contains(rect.center.x) && ranges.1.contains(rect.center.y)
}
