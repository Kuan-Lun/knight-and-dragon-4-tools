// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "KnightDragonMirrorProbe",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "mirror-probe", targets: ["MirrorProbe"]),
    ],
    targets: [
        .target(name: "MirrorProbeCore"),
        .executableTarget(
            name: "MirrorProbe",
            dependencies: ["MirrorProbeCore"]
        ),
        .testTarget(
            name: "MirrorProbeCoreTests",
            dependencies: ["MirrorProbeCore"],
            resources: [
                .process("Fixtures"),
            ]
        ),
    ]
)
