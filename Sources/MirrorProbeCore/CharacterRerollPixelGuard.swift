public struct CharacterRerollPixelGuardDifferences: Equatable, Sendable {
    public let inputSurface: Double
    public let result: Double

    public init(inputSurface: Double, result: Double) {
        self.inputSurface = inputSurface
        self.result = result
    }

    public var inputSurfaceIsQuiescent: Bool {
        Self.isQuiescent(inputSurface)
    }

    public var resultIsQuiescent: Bool {
        Self.isQuiescent(result)
    }

    private static func isQuiescent(_ difference: Double) -> Bool {
        difference.isFinite
            && difference >= 0
            && difference <= CharacterRerollPixelGuard.maximumQuiescentDifference
    }
}

public enum CharacterRerollPixelGuard {
    /// All generated fields, with the phone status bar and tappable controls omitted.
    public static let resultRegion = NormalizedRect(
        x: 0.01, y: 0.13, width: 0.98, height: 0.50
    )
    /// Starts below the full phone status bar while retaining the page title, Random button,
    /// generated fields, and lower action controls. Coordinates scale with the captured window.
    public static let inputSurfaceRegion = NormalizedRect(
        x: 0.01, y: 0.095, width: 0.98, height: 0.635
    )
    public static let maximumQuiescentDifference = 0.000_1

    public static func differences(
        _ lhs: [UInt8],
        _ rhs: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) throws -> CharacterRerollPixelGuardDifferences {
        let inputSurface = try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
            lhs, rhs,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            region: inputSurfaceRegion
        )
        let result = try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
            lhs, rhs,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            region: resultRegion
        )
        return CharacterRerollPixelGuardDifferences(inputSurface: inputSurface, result: result)
    }
}

public enum CharacterRerollPixelGuardRecoveryDecision: Equatable, Sendable {
    case retry(attempt: Int)
    case exhausted
    case unsafe
}

/// A rejected surface comparison never authorizes input. Recovery only permits another complete
/// observation and authorization pass after the rejected pixels independently prove the same low
/// character. The caller retains the session deadline and resets this budget only after posting.
public struct CharacterRerollPixelGuardRecovery: Sendable {
    public static let maximumRetries = 3
    private var retries = 0
    private var terminalDecision: CharacterRerollPixelGuardRecoveryDecision?

    public init() {}

    public mutating func evaluate(
        authorized: CharacterRerollDecision,
        observed: CharacterRerollDecision,
        boundaryEvidence: CharacterTotalBoundaryEvidence,
        differences: CharacterRerollPixelGuardDifferences
    ) -> CharacterRerollPixelGuardRecoveryDecision {
        if let terminalDecision { return terminalDecision }

        guard boundaryEvidence == .belowThreshold,
              case let .rerollRequired(authorizedRoll, authorizedTarget) = authorized,
              case let .rerollRequired(observedRoll, observedTarget) = observed,
              authorizedRoll == observedRoll,
              Self.targetsMatch(authorizedTarget, observedTarget),
              differences.inputSurface.isFinite,
              (0...1).contains(differences.inputSurface),
              differences.resultIsQuiescent
        else {
            terminalDecision = .unsafe
            return .unsafe
        }

        guard retries < Self.maximumRetries else {
            terminalDecision = .exhausted
            return .exhausted
        }
        retries += 1
        return .retry(attempt: retries)
    }

    private static func targetsMatch(
        _ lhs: CharacterRerollTarget,
        _ rhs: CharacterRerollTarget
    ) -> Bool {
        lhs.sourceText == rhs.sourceText
            && lhs.rect.isValid && rhs.rect.isValid
            && lhs.point.x.isFinite && lhs.point.y.isFinite
            && rhs.point.x.isFinite && rhs.point.y.isFinite
            && (0...1).contains(lhs.point.x) && (0...1).contains(lhs.point.y)
            && (0...1).contains(rhs.point.x) && (0...1).contains(rhs.point.y)
            && abs(lhs.point.x - rhs.point.x) <= 0.01
            && abs(lhs.point.y - rhs.point.y) <= 0.01
            && abs(lhs.rect.width - rhs.rect.width) <= 0.02
            && abs(lhs.rect.height - rhs.rect.height) <= 0.02
    }
}
