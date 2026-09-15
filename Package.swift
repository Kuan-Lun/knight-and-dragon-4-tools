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
        .target(
            name: "MirrorProbeRuntime",
            dependencies: ["MirrorProbeCore"]
        ),
        .executableTarget(
            name: "MirrorProbe",
            dependencies: ["MirrorProbeRuntime"]
        ),
        .testTarget(
            name: "MirrorProbeRuntimeTests",
            dependencies: ["MirrorProbeRuntime", "MirrorProbeCore"],
            resources: [
                .process("Fixtures"),
            ]
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
