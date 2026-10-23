// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Gajos",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Gajos", path: "Sources/Gajos")
    ]
)
