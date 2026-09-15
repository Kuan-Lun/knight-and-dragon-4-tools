import CoreGraphics
import Foundation
import MirrorProbeCore
import ScreenCaptureKit

struct CharacterRerollLimitsReport: Codable {
    let minimumTotal: Int
    let maximumRerolls: Int
    let maximumMinutes: Double
}

struct CharacterRerollReport: Codable {
    let schemaVersion: Int
    let status: String
    let startedAt: String
    let endedAt: String?
    let window: WindowReport
    let limits: CharacterRerollLimitsReport
    let initialTotal: Int?
    let finalTotal: Int?
    let rerollsPosted: Int
    let finalReason: String
    let keeperOrConflictWasObserved: Bool
    let candidateImage: CharacterRerollCandidateImageReport?
}

struct CharacterRerollCandidateImageReport: Codable {
    let role: String
    let path: String
    let pngSHA256: String
    let observedTotal: Int?
    let observedTotalSource: String?
    let credibleFullFrameTotals: [Int]
    let credibleFocusedTotals: [Int]
    let fullFrameWasContaminated: Bool
    let focusedWasContaminated: Bool
    let focusedTotal: Int?
    let renderedDigitCount: Int?
    let boundaryEvidence: String
    let thresholdReached: Bool
}

struct CharacterRerollPixelGuardDiagnostic: Codable {
    let schemaVersion: Int
    let timestamp: String
    let rerollsPosted: Int
    let inputSurfaceDifference: Double
    let resultDifference: Double
    let maximumQuiescentDifference: Double
    let inputSurfaceRegion: MirrorProbeCore.NormalizedRect
    let resultRegion: MirrorProbeCore.NormalizedRect
    let beforeImagePath: String
    let beforeImageSHA256: String
    let rejectedImagePath: String
    let rejectedImageSHA256: String
}

struct CharacterRerollObservation {
    let capturedAt: TimeInterval
    let window: SCWindow
    let decision: CharacterRerollDecision
    let boundaryEvidence: CharacterTotalBoundaryEvidence
    let credibleFullFrameTotals: [Int]
    let credibleFocusedTotals: [Int]
    let fullFrameWasContaminated: Bool
    let focusedWasContaminated: Bool
    let fullFrameTotal: Int?
    let focusedTotal: Int?
    let renderedDigitCount: Int?
    let image: CGImage
    let rgba: RGBAFrame
}

enum CharacterRerollCandidateRole: String {
    case finalStable
    case lastVerifiedStable
    case preClickFallback
    case latestPreClickUnverified
    case latestPostClickUnverified
}

struct CharacterRerollTerminalError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

enum CharacterRerollObservationEnd {
    case stopRequested
    case maximumRuntimeReached
    case failed(String)
}

enum CharacterRerollAcknowledgementOutcome {
    case acknowledged(CharacterRerollObservation)
    case ended(
        latestPostClick: CharacterRerollObservation?,
        keeperOrConflictWasObserved: Bool,
        reason: CharacterRerollObservationEnd
    )
}

enum CharacterRerollStabilityOutcome {
    case stable(CharacterRerollObservation)
    case ended(
        latest: CharacterRerollObservation?,
        keeperOrConflictWasObserved: Bool,
        reason: CharacterRerollObservationEnd
    )
}

enum CharacterRerollClickResult {
    case posted
    case focusContended
    case stopRequested
    case maximumRuntimeReached
}

enum CharacterRerollInterruption: Error {
    case stopRequested
    case maximumRuntimeReached
}
