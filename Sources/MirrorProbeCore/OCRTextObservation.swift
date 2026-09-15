import Foundation

/// OCR observations use a top-left origin and normalized coordinates in the closed range 0...1.
public struct OCRTextObservation: Codable, Equatable, Sendable {
    public let text: String
    public let rect: NormalizedRect
    public let confidence: Double

    public init(text: String, rect: NormalizedRect, confidence: Double) {
        self.text = text
        self.rect = rect
        self.confidence = confidence
    }
}
