import Foundation

public enum VisualBattleDetectorError: Error, Equatable, Sendable {
    case invalidDimensions
    case insufficientBytes
}

public enum VisualBattleDetector {
    public static func classifyRGBA(
        _ bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int,
        modalDetection: WideModalButtonDetection? = nil
    ) throws -> GameStateClassification {
        guard width > 1, height > 1, width <= 10_000, height <= 10_000,
              width * height <= 25_000_000,
              bytesPerRow >= width * 4, bytesPerRow <= Int.max / height
        else { throw VisualBattleDetectorError.invalidDimensions }
        guard bytes.count >= bytesPerRow * height else {
            throw VisualBattleDetectorError.insufficientBytes
        }
        let modal = try modalDetection ?? WideModalButtonDetector.detectRGBA(
            bytes, width: width, height: height, bytesPerRow: bytesPerRow
        )
        guard modal.layout == .none else { return rejected("modalPresent") }
        guard MirrorContentLayout.hasReferenceProportions(width: width, height: height)
        else { return rejected("unsupportedImageGeometry") }

        let matches = VisualBattleMarker.allCases.compactMap { marker -> VisualBattleMatch? in
            let samples = VisualBattleTemplates.samples[marker] ?? []
            return VisualBattleMatch.regions(for: marker).map { region in
                VisualBattleMatch(
                    marker: marker, region: region,
                    similarity: VisualRegionMatcher.bestSimilarity(
                        region: region,
                        templates: samples.filter { $0.region == region }.map(\.pixels),
                        sampleWidth: VisualBattleTemplates.sampleWidth,
                        sampleHeight: VisualBattleTemplates.sampleHeight,
                        bytes: bytes, width: width, height: height, bytesPerRow: bytesPerRow
                    )
                )
            }.max { $0.similarity < $1.similarity }
        }
        let detail = matches.map { "\($0.marker.rawValue)=\(String(format: "%.5f", $0.similarity))" }
            .joined(separator: ", ")
        let trusted = matches.filter { $0.similarity >= VisualBattleMatch.minimumSimilarity }
        let evidence = trusted.map { match in
            GameStateEvidence(
                kind: .battleMarker, observation: nil,
                detail: "source=battleVisualV1, marker=\(match.marker.rawValue), "
                    + "similarity=\(match.similarity), minimumSimilarity=\(VisualBattleMatch.minimumSimilarity)",
                battleVisualMatch: match
            )
        }
        guard VisualBattleEvidence.identityMarkers.allSatisfy({ marker in
            trusted.contains { $0.marker == marker }
        }) else {
            guard trusted.contains(where: { $0.marker == .retreatControl }) else {
                return rejected("incompleteFooterMarkers, \(detail)")
            }
            // Keep measured controls so temporal recovery can revalidate a visible retreat
            // target without treating an incomplete footer as a recognized battle.
            return .init(state: .unknown, evidence: evidence + [
                .init(kind: .battleFooterOcclusion, observation: nil,
                      detail: "battleVisualRejected: incompleteFooterMarkers, \(detail)"),
            ], allowedActions: [])
        }
        let canLocateRetreat = trusted.contains { $0.marker == .retreatControl }

        let retreat = VisualBattleEvidence.measuredRetreatRect
        return GameStateClassification(
            state: .battle,
            evidence: evidence,
            allowedActions: [],
            policyGatedActions: canLocateRetreat ? [.init(
                name: .openBattleRetreatConfirmation,
                target: .init(name: .battleRetreat,
                              sourceText: VisualBattleEvidence.measuredRetreatSentinel,
                              rect: retreat, point: retreat.center),
                requirement: .temporalDefeatRecovery
            )] : []
        )
    }

    private static func rejected(_ detail: String) -> GameStateClassification {
        .init(state: .unknown,
              evidence: [.init(kind: .lowConfidenceMarker, observation: nil,
                               detail: "battleVisualRejected: \(detail)")],
              allowedActions: [])
    }
}
