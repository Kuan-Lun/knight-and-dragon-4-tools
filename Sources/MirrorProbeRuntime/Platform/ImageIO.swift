import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import MirrorProbeCore

extension MirrorProbeRuntime {
    static func rgbaFrame(from image: CGImage) throws -> RGBAFrame {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var bytes = Array(repeating: UInt8(0), count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue

        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  )
            else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard rendered else {
            throw ProbeError.frameConversionFailed
        }
        return RGBAFrame(bytes: bytes, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    static func metrics(for image: CGImage) throws -> FrameMetrics {
        let frame = try rgbaFrame(from: image)
        return try FrameAnalyzer.analyzeRGBA(
            frame.bytes,
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow
        )
    }

    @discardableResult
    static func writePNG(_ image: CGImage, to outputURL: URL) throws -> String {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw ProbeError.pngEncodingFailed
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: .atomic)
        return sha256Hex(of: data)
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func outputURL(for path: String, isDirectory: Bool = false) throws -> URL {
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path, isDirectory: isDirectory)
        } else {
            url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(path, isDirectory: isDirectory)
        }
        if isDirectory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url.standardizedFileURL
    }
}
