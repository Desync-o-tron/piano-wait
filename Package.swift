// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PianoWait",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PianoWaitCore", targets: ["PianoWaitCore"]),
        .executable(name: "pianowait-samples", targets: ["pianowait-samples"]),
    ],
    targets: [
        .target(name: "PianoWaitCore"),
        .executableTarget(name: "pianowait-samples", dependencies: ["PianoWaitCore"]),
        .testTarget(name: "PianoWaitCoreTests", dependencies: ["PianoWaitCore"]),
    ]
)
