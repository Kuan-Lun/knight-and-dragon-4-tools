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

/// Where the phone content sits in the captured frame and on the recognition canvas.
struct ContentLayoutReport: Codable {
    let detected: Bool
    let sourceWidth: Int
    let sourceHeight: Int
    let sourceContentX: Int
    let sourceContentY: Int
    let contentWidth: Int
    let contentHeight: Int
    let canvasWidth: Int
    let canvasHeight: Int
    let canvasContentX: Int
    let canvasContentY: Int
    let identity: Bool

    init(_ layout: MirrorContentLayout, detected: Bool) {
        self.detected = detected
        sourceWidth = layout.sourceWidth
        sourceHeight = layout.sourceHeight
        sourceContentX = layout.sourceContent.x
        sourceContentY = layout.sourceContent.y
        contentWidth = layout.sourceContent.width
        contentHeight = layout.sourceContent.height
        canvasWidth = layout.canvasWidth
        canvasHeight = layout.canvasHeight
        canvasContentX = layout.canvasContent.x
        canvasContentY = layout.canvasContent.y
        identity = layout.isIdentity
    }
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
    /// Absent only in reports written before schema 3.
    let contentLayout: ContentLayoutReport?
    let frameMetrics: FrameMetrics
    let ocr: AnalysisOCRReport
    let classification: GameStateClassification
    let safety: AnalysisSafetyReport
}
