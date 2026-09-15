import CoreGraphics
import MirrorProbeCore

struct RGBAFrame {
    let bytes: [UInt8]
    let width: Int
    let height: Int
    let bytesPerRow: Int
}

struct WindowServerWindow {
    let identity: AutoLevelWindowIdentity
    let frame: CGRect
    let alpha: Double
    let layer: Int
    let name: String?
    let ownerBundleIdentifier: String?
}

struct LoadedPNG {
    let image: CGImage
    let sha256: String
}
