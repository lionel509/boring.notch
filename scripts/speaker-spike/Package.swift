// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "speaker-spike",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.0")
    ],
    targets: [
        .executableTarget(
            name: "speaker-spike",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        )
    ]
)
