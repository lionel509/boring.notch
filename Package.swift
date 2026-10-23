// swift-tools-version: 5.9
import PackageDescription

// Test harness only: the app does not depend on this package.
let package = Package(
    name: "VoiceDictationLogic",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VoiceDictationLogic", targets: ["VoiceDictationLogic"]),
    ],
    targets: [
        .target(name: "VoiceDictationLogic", path: "boringNotch/Voice/Logic"),
        .testTarget(
            name: "VoiceDictationLogicTests",
            dependencies: ["VoiceDictationLogic"],
            path: "Tests/VoiceDictationLogicTests"
        ),
    ]
)
