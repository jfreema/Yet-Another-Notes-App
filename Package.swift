// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "YANA",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "YANA", path: "Sources/YANA"),
        .testTarget(name: "YANATests", dependencies: ["YANA"], path: "Tests/YANATests"),
    ],
    swiftLanguageModes: [.v5]
)
