import CoreGraphics
import Foundation
import MirrorProbeCore
import Vision

extension MirrorProbeRuntime {
    static func analyzeFileCommand(_ arguments: [String]) throws {
        try validateOptions(
            arguments,
            valueOptions: ["--input", "--report", "--profile"]
        )
        try validateAnalysisProfile(arguments)
        guard let inputPath = option("--input", in: arguments) else {
            throw ProbeError.invalidArguments("analyze-file requires --input IMAGE.png")
        }

        let inputURL = inputFileURL(for: inputPath)
        let reportURL = try option("--report", in: arguments).map { try outputURL(for: $0) }
        try requireDistinct(inputURL, reportURL, labels: "--input and --report")

        let loadedPNG = try loadPNG(at: inputURL)
        let report = try analyze(
            image: loadedPNG.image,
            pngSHA256: loadedPNG.sha256,
            command: "analyze-file",
            source: AnalysisSourceReport(
                kind: "file",
                path: inputURL.path,
                window: nil,
                capturedImagePath: nil
            )
        )
        try printJSON(report)
        if let reportURL {
            try writeJSON(report, to: reportURL)
        }
    }

    static func analyzeCommand(_ arguments: [String]) async throws {
        try validateOptions(
            arguments,
            valueOptions: ["--window-id", "--output", "--report", "--profile"]
        )
        try validateAnalysisProfile(arguments)
        try ensureScreenCapturePermission()

        let requestedID = try optionalWindowID(arguments)
        let captureURL = try outputURL(
            for: option("--output", in: arguments) ?? "captures/analysis.png"
        )
        let reportURL = try outputURL(
            for: option("--report", in: arguments) ?? "captures/analysis-report.json"
        )
        try requireDistinct(captureURL, reportURL, labels: "--output and --report")

        let window = try await selectMirrorWindow(requestedID: requestedID)
        let image = try await capture(window: window)
        let pngSHA256 = try writePNG(image, to: captureURL)

        let report = try analyze(
            image: image,
            pngSHA256: pngSHA256,
            command: "analyze",
            source: AnalysisSourceReport(
                kind: "mirrorCapture",
                path: nil,
                window: windowReport(window),
                capturedImagePath: captureURL.path
            )
        )
        try printJSON(report)
        try writeJSON(report, to: reportURL)
    }

    static func analyze(
        image: CGImage,
        pngSHA256: String,
        command: String,
        source: AnalysisSourceReport
    ) throws -> AnalysisReport {
        // Recognition runs on the reference-proportioned canvas; the report keeps the captured
        // dimensions and describes where the content was found.
        let normalized = try normalizedMirrorFrame(from: image)
        let frameMetrics = try FrameAnalyzer.analyzeRGBA(
            normalized.rgba.bytes, width: normalized.rgba.width, height: normalized.rgba.height,
            bytesPerRow: normalized.rgba.bytesPerRow
        )
        let classification: GameStateClassification
        if frameMetrics.isBlank {
            classification = .init(state: .unknown, evidence: [], allowedActions: [])
        } else {
            classification = try recognizeGameState(in: normalized.image, rgba: normalized.rgba)
        }
        let detectedLayout = MirrorContentLayout.detect(
            normalized.rgba.bytes, width: normalized.rgba.width, height: normalized.rgba.height,
            bytesPerRow: normalized.rgba.bytesPerRow
        ) != nil
        let status: String
        if frameMetrics.isBlank {
            status = "rejected"
        } else if classification.state == .unknown {
            status = "unknown"
        } else {
            status = "classified"
        }

        return AnalysisReport(
            schemaVersion: analysisSchemaVersion,
            profile: analysisProfileName,
            recognitionMode: "visualRegions",
            command: command,
            status: status,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            source: source,
            image: AnalysisImageReport(
                width: image.width,
                height: image.height,
                orientation: "up",
                pngSHA256: pngSHA256
            ),
            contentLayout: ContentLayoutReport(normalized.layout, detected: detectedLayout),
            frameMetrics: frameMetrics,
            ocr: AnalysisOCRReport(
                engine: "none",
                requestRevision: 0,
                recognitionLevel: "notUsed",
                languages: [],
                usesLanguageCorrection: false,
                coordinateSpace: "normalizedTopLeft",
                observations: []
            ),
            classification: classification,
            safety: AnalysisSafetyReport(
                readOnly: true,
                inputEventsPosted: 0,
                actionAuthorization: "none"
            )
        )
    }

    /// Auto-level recognition uses only captured image regions, including battle activity.
    /// Vision text recognition is reserved for the separate character-reroll workflow below.
    static func recognizeGameState(
        in image: CGImage,
        rgba suppliedRGBA: RGBAFrame? = nil
    ) throws -> GameStateClassification {
        let rgba = try suppliedRGBA ?? rgbaFrame(from: image)
        return try AutoLevelVisualClassifier.classifyRGBA(
            rgba.bytes, width: rgba.width, height: rgba.height, bytesPerRow: rgba.bytesPerRow
        )
    }

    static func recognizeText(
        in image: CGImage,
        regionOfInterest: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        minimumTextHeight: Float = 0.01,
        languages: [String] = ["zh-Hant", "en-US"]
    ) throws -> [OCRTextObservation] {
        let revision = VNRecognizeTextRequestRevision3
        do {
            let request = VNRecognizeTextRequest()
            request.revision = revision
            request.recognitionLevel = .accurate
            request.recognitionLanguages = languages
            request.usesLanguageCorrection = false
            request.minimumTextHeight = minimumTextHeight
            request.regionOfInterest = regionOfInterest
            let supported: [String]
            do {
                supported = try request.supportedRecognitionLanguages()
            } catch {
                throw ProbeError.textRecognitionFailed(
                    "supported-language query failed: \(diagnosticDescription(error))"
                )
            }
            guard languages.allSatisfy(supported.contains) else {
                throw ProbeError.textRecognitionFailed(
                    "the \(analysisProfileName) languages are not supported by this Vision revision"
                )
            }

            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            do {
                try handler.perform([request])
            } catch {
                throw ProbeError.textRecognitionFailed(
                    "request execution failed: \(diagnosticDescription(error))"
                )
            }

            var observations = (request.results ?? []).compactMap { result -> OCRTextObservation? in
                guard let candidate = result.topCandidates(1).first else {
                    return nil
                }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    return nil
                }
                // Vision reports OCR boxes relative to `regionOfInterest`, not the source image.
                // Convert them back to the full-frame normalized coordinate space used by the
                // classifier and click safety checks.
                let regionBox = result.boundingBox
                let box = CGRect(
                    x: regionOfInterest.minX + regionBox.minX * regionOfInterest.width,
                    y: regionOfInterest.minY + regionBox.minY * regionOfInterest.height,
                    width: regionBox.width * regionOfInterest.width,
                    height: regionBox.height * regionOfInterest.height
                )
                return OCRTextObservation(
                    text: text,
                    rect: NormalizedRect(
                        x: normalizedVisionValue(box.minX),
                        y: normalizedVisionValue(1 - box.maxY),
                        width: normalizedVisionValue(box.width),
                        height: normalizedVisionValue(box.height)
                    ),
                    confidence: Double(candidate.confidence)
                )
            }
            observations.sort { lhs, rhs in
                if lhs.rect.y != rhs.rect.y {
                    return lhs.rect.y < rhs.rect.y
                }
                if lhs.rect.x != rhs.rect.x {
                    return lhs.rect.x < rhs.rect.x
                }
                return lhs.text < rhs.text
            }
            return observations
        } catch let error as ProbeError {
            throw error
        } catch {
            throw ProbeError.textRecognitionFailed(error.localizedDescription)
        }
    }

    static func normalizedVisionValue(_ value: CGFloat) -> Double {
        let converted = Double(value)
        if converted < 0, converted >= -0.000_001 {
            return 0
        }
        if converted > 1, converted <= 1.000_001 {
            return 1
        }
        return converted
    }

    static func diagnosticDescription(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) code \(nsError.code): \(nsError.localizedDescription)"
    }
}
