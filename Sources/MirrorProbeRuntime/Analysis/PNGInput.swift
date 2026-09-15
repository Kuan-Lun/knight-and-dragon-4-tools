import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension MirrorProbeRuntime {
    static func loadPNG(at url: URL) throws -> LoadedPNG {
        do {
            let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else {
                    return -1
                }
                return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard descriptor >= 0 else {
                throw ProbeError.imageLoadFailed(
                    "could not open a readable regular PNG without following a symbolic link"
                )
            }
            defer { _ = Darwin.close(descriptor) }

            var fileStatus = stat()
            guard Darwin.fstat(descriptor, &fileStatus) == 0 else {
                throw ProbeError.imageLoadFailed("could not inspect the opened PNG")
            }
            guard fileStatus.st_mode & S_IFMT == S_IFREG else {
                throw ProbeError.imageLoadFailed("the opened input is not a regular file")
            }
            let encodedSize = fileStatus.st_size
            guard encodedSize > 0, encodedSize <= maximumPNGByteCount else {
                throw ProbeError.imageLoadFailed("PNG must be between 1 byte and 50 MiB")
            }

            let encodedData = try readBounded(
                descriptor: descriptor,
                maximumByteCount: maximumPNGByteCount
            )
            guard encodedData.count <= maximumPNGByteCount else {
                throw ProbeError.imageLoadFailed("PNG must not exceed 50 MiB")
            }
            guard Int64(encodedData.count) == encodedSize else {
                throw ProbeError.imageLoadFailed("the PNG changed while it was being read")
            }
            let encodedSHA256 = sha256Hex(of: encodedData)
            guard let source = CGImageSourceCreateWithData(encodedData as CFData, nil) else {
                throw ProbeError.imageLoadFailed("the file is not a supported image source")
            }
            guard CGImageSourceGetCount(source) == 1 else {
                throw ProbeError.imageLoadFailed("exactly one image is required")
            }
            guard (CGImageSourceGetType(source) as String?) == UTType.png.identifier else {
                throw ProbeError.imageLoadFailed("only PNG input is accepted")
            }

            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
                  let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber
            else {
                throw ProbeError.imageLoadFailed("PNG dimensions are missing")
            }
            let pixelWidth = widthNumber.int64Value
            let pixelHeight = heightNumber.int64Value
            guard pixelWidth > 0,
                  pixelHeight > 0,
                  pixelWidth <= 10_000,
                  pixelHeight <= 10_000,
                  pixelWidth * pixelHeight <= 25_000_000
            else {
                throw ProbeError.imageLoadFailed(
                    "PNG dimensions must be at most 10,000 pixels per side and 25 megapixels"
                )
            }
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            guard orientation == 1 else {
                throw ProbeError.imageLoadFailed("PNG orientation metadata must be up (1)")
            }
            guard let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            ) else {
                throw ProbeError.imageLoadFailed("PNG decoding failed")
            }
            guard Int64(image.width) == pixelWidth, Int64(image.height) == pixelHeight else {
                throw ProbeError.imageLoadFailed("decoded PNG dimensions do not match its properties")
            }
            return LoadedPNG(image: image, sha256: encodedSHA256)
        } catch let error as ProbeError {
            throw error
        } catch {
            throw ProbeError.imageLoadFailed(error.localizedDescription)
        }
    }

    static func readBounded(
        descriptor: Int32,
        maximumByteCount: Int
    ) throws -> Data {
        let bufferCapacity = 64 * 1_024
        var buffer = [UInt8](repeating: 0, count: bufferCapacity)
        var data = Data()
        data.reserveCapacity(min(maximumByteCount, bufferCapacity))

        while data.count <= maximumByteCount {
            let remainingCapacity = maximumByteCount + 1 - data.count
            let requestedCount = min(bufferCapacity, remainingCapacity)
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                Darwin.read(descriptor, bytes.baseAddress, requestedCount)
            }
            if count == 0 {
                return data
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw ProbeError.imageLoadFailed("could not read the opened PNG")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    static func inputFileURL(for path: String) -> URL {
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(path)
        }
        return url.standardizedFileURL
    }

    static func validateAnalysisProfile(_ arguments: [String]) throws {
        guard let profile = option("--profile", in: arguments) else {
            return
        }
        guard profile == analysisProfileName else {
            throw ProbeError.invalidArguments(
                "--profile must be \(analysisProfileName); confidence thresholds cannot be lowered"
            )
        }
    }

    static func requireDistinct(
        _ lhs: URL,
        _ rhs: URL?,
        labels: String
    ) throws {
        guard let rhs else {
            return
        }
        let lhsPath = lhs.standardizedFileURL.resolvingSymlinksInPath().path
        let rhsPath = rhs.standardizedFileURL.resolvingSymlinksInPath().path
        guard lhsPath != rhsPath else {
            throw ProbeError.invalidArguments("\(labels) must refer to different files")
        }
    }
}
