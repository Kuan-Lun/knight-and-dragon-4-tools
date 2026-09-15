import Foundation
import MirrorProbeCore
import ScreenCaptureKit

extension MirrorProbeRuntime {
    static func emitCharacterRerollReport(
        status: String,
        reason: String,
        startedDate: Date,
        window: SCWindow,
        limits: CharacterRerollLimitsReport,
        initialTotal: Int?,
        finalTotal: Int?,
        rerollsPosted: Int,
        reportURL: URL?,
        candidateObservation: CharacterRerollObservation? = nil,
        candidateRole: CharacterRerollCandidateRole? = nil,
        keeperOrConflictWasObserved: Bool = false,
        printToStandardOutput: Bool = true
    ) throws {
        let terminalBoundaryWasObserved = keeperOrConflictWasObserved
            || candidateObservation?.boundaryEvidence == .thresholdReached
            || candidateObservation?.boundaryEvidence == .boundaryConflict
        let candidateImage: CharacterRerollCandidateImageReport?
        if status != "running",
           let reportURL,
           let candidateObservation
        {
            let imageURL = reportURL.deletingLastPathComponent()
                .appendingPathComponent("final-candidate.png")
            if let pngSHA256 = try? writePNG(candidateObservation.image, to: imageURL) {
                candidateImage = CharacterRerollCandidateImageReport(
                    role: (
                        candidateRole
                            ?? (status == "completed" ? .finalStable : .lastVerifiedStable)
                    ).rawValue,
                    path: imageURL.path,
                    pngSHA256: pngSHA256,
                    observedTotal: characterRerollUnambiguousTotal(candidateObservation),
                    observedTotalSource: characterRerollObservedTotalSource(
                        candidateObservation
                    ),
                    credibleFullFrameTotals: candidateObservation.credibleFullFrameTotals,
                    credibleFocusedTotals: candidateObservation.credibleFocusedTotals,
                    fullFrameWasContaminated: candidateObservation.fullFrameWasContaminated,
                    focusedWasContaminated: candidateObservation.focusedWasContaminated,
                    focusedTotal: candidateObservation.focusedTotal,
                    renderedDigitCount: candidateObservation.renderedDigitCount,
                    boundaryEvidence: characterRerollBoundaryEvidenceName(
                        candidateObservation.boundaryEvidence
                    ),
                    thresholdReached: candidateObservation.boundaryEvidence == .thresholdReached
                )
            } else {
                candidateImage = nil
            }
        } else {
            candidateImage = nil
        }
        let report = CharacterRerollReport(
            schemaVersion: characterRerollSchemaVersion,
            status: status,
            startedAt: ISO8601DateFormatter().string(from: startedDate),
            endedAt: status == "running"
                ? nil
                : ISO8601DateFormatter().string(from: Date()),
            window: windowReport(window),
            limits: limits,
            initialTotal: initialTotal,
            finalTotal: finalTotal,
            rerollsPosted: rerollsPosted,
            finalReason: reason,
            keeperOrConflictWasObserved: terminalBoundaryWasObserved,
            candidateImage: candidateImage
        )
        if let reportURL {
            try writeJSON(report, to: reportURL)
        }
        if printToStandardOutput {
            try printJSON(report)
        }
    }
}
