import Foundation

/// The complete auto-level recognition path. Every executable state comes from measured
/// pixels; no text-recognition fallback may fill in an absent or obscured visual anchor.
public enum AutoLevelVisualClassifier {
    public static func classifyRGBA(
        _ bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int
    ) throws -> GameStateClassification {
        guard width > 1, height > 1, width <= 10_000, height <= 10_000,
              width * height <= 25_000_000,
              bytesPerRow >= width * 4, bytesPerRow <= Int.max / height
        else { throw VisualResultDetectorError.invalidDimensions }
        guard bytes.count >= bytesPerRow * height else {
            throw VisualResultDetectorError.insufficientBytes
        }
        guard width >= 200, height >= 400,
              abs(Double(width) / Double(height) - 406.0 / 890.0) <= 0.01
        else {
            return .init(state: .unknown, evidence: [
                .init(kind: .lowConfidenceMarker, observation: nil,
                      detail: "autoLevelVisualRejected: unsupportedImageGeometry"),
            ], allowedActions: [])
        }
        let modal = try WideModalButtonDetector.detectRGBA(
            bytes, width: width, height: height, bytesPerRow: bytesPerRow
        )
        if modal.layout != .none {
            return WideModalActionResolver.resolve(
                classification: .init(state: .unknown, evidence: [], allowedActions: []),
                detection: modal
            )
        }
        let result = try VisualResultDetector.detectRGBA(
            bytes, width: width, height: height, bytesPerRow: bytesPerRow,
            modalDetection: modal
        )
        if result.isResultCandidate { return result.classification }

        let battle = try VisualBattleDetector.classifyRGBA(
            bytes, width: width, height: height, bytesPerRow: bytesPerRow,
            modalDetection: modal
        )
        if battle.state == .battle {
            // The footer identifies the battle page. Require a measured retreat control
            // before temporal monitoring; combat effects over pause do not invalidate it.
            guard VisualBattleEvidence.hasRunningBattleEvidence(in: battle) else {
                return .init(state: .unknown, evidence: battle.evidence + [
                    .init(kind: .lowConfidenceMarker, observation: nil,
                          detail: "battleFooterMatchedButRetreatUnconfirmed"),
                ], allowedActions: [])
            }
            return battle
        }
        return .init(
            state: .unknown,
            evidence: result.classification.evidence + battle.evidence,
            allowedActions: []
        )
    }
}
