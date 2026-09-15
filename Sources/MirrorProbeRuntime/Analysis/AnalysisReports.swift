import Foundation
import MirrorProbeCore

struct AnalysisSourceReport: Codable {
    let kind: String
    let path: String?
    let window: WindowReport?
    let capturedImagePath: String?
}

struct AnalysisImageReport: Codable {
    let width: Int
    let height: Int
    let orientation: String
    let pngSHA256: String
}

struct AnalysisOCRReport: Codable {
    let engine: String
    let requestRevision: Int
    let recognitionLevel: String
    let languages: [String]
    let usesLanguageCorrection: Bool
    let coordinateSpace: String
    let observations: [OCRTextObservation]
}

struct AnalysisSafetyReport: Codable {
    let readOnly: Bool
    let inputEventsPosted: Int
    let actionAuthorization: String
}

struct AnalysisReport: Codable {
    let schemaVersion: Int
    let profile: String
    let recognitionMode: String?
    let command: String
    let status: String
    let timestamp: String
    let source: AnalysisSourceReport
    let image: AnalysisImageReport
    let frameMetrics: FrameMetrics
    let ocr: AnalysisOCRReport
    let classification: GameStateClassification
    let safety: AnalysisSafetyReport
}
