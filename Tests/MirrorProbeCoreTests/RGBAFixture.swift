import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing

/// A test fixture PNG decoded to the packed RGBA layout the detectors read.
struct RGBAFixtureFrame {
    var bytes: [UInt8]
    let width: Int
    let height: Int
    var bytesPerRow: Int { width * 4 }
}

/// Loads a bundled PNG byte-for-byte, verifying its SHA-256 so a regression always runs on
/// the original capture, and renders it into premultiplied RGBA.
func loadRGBAFixture(_ name: String, sha256: String? = nil) throws -> RGBAFixtureFrame {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "png"))
    let data = try Data(contentsOf: url)
    if let sha256 {
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256)
    }
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    var frame = RGBAFixtureFrame(
        bytes: [UInt8](repeating: 0, count: image.width * image.height * 4),
        width: image.width, height: image.height
    )
    let width = frame.width, height = frame.height, bytesPerRow = frame.bytesPerRow
    let rendered = frame.bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    #expect(rendered)
    return frame
}
