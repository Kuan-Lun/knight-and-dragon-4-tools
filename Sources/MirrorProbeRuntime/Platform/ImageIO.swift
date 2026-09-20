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

    /// Frame prepared for recognition: the captured pixels placed on the reference-proportioned
    /// canvas (see MirrorContentLayout). A reference-size capture is passed through unchanged.
    struct NormalizedMirrorFrame {
        let image: CGImage
        let rgba: RGBAFrame
        let layout: MirrorContentLayout
        let sourceWidth: Int
        let sourceHeight: Int
    }

    static func normalizedMirrorFrame(from image: CGImage) throws -> NormalizedMirrorFrame {
        let source = try rgbaFrame(from: image)
        return try normalizedMirrorFrame(from: source, image: image)
    }

    static func normalizedMirrorFrame(
        from source: RGBAFrame, image: CGImage? = nil
    ) throws -> NormalizedMirrorFrame {
        let detected = MirrorContentLayout.detect(
            source.bytes, width: source.width, height: source.height, bytesPerRow: source.bytesPerRow
        )
        let layout = detected ?? .identity(width: source.width, height: source.height)
        if layout.isIdentity, source.bytesPerRow == source.width * 4 {
            return NormalizedMirrorFrame(
                image: try image ?? cgImage(from: source), rgba: source, layout: layout,
                sourceWidth: source.width, sourceHeight: source.height
            )
        }
        guard let canvasBytes = layout.canvasRGBA(
            source.bytes, width: source.width, height: source.height, bytesPerRow: source.bytesPerRow
        ) else {
            throw ProbeError.frameConversionFailed
        }
        let canvas = RGBAFrame(
            bytes: canvasBytes, width: layout.canvasWidth, height: layout.canvasHeight,
            bytesPerRow: layout.canvasWidth * 4
        )
        return NormalizedMirrorFrame(
            image: try cgImage(from: canvas), rgba: canvas, layout: layout,
            sourceWidth: source.width, sourceHeight: source.height
        )
    }

    static func cgImage(from frame: RGBAFrame) throws -> CGImage {
        var bytes = frame.bytes
        let image = bytes.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress, width: frame.width, height: frame.height,
                    bitsPerComponent: 8, bytesPerRow: frame.bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return nil }
            return context.makeImage()
        }
        guard let image else { throw ProbeError.frameConversionFailed }
        return image
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
