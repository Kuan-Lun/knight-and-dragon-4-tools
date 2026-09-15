import Foundation

public struct NormalizedRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var center: NormalizedPoint {
        NormalizedPoint(x: x + width / 2, y: y + height / 2)
    }

    public var isValid: Bool {
        x.isFinite
            && y.isFinite
            && width.isFinite
            && height.isFinite
            && x >= 0
            && y >= 0
            && width > 0
            && height > 0
            && x + width <= 1
            && y + height <= 1
    }
}

public struct NormalizedPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}
