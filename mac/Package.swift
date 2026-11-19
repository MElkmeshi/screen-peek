// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScreenPeek",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ScreenPeek", path: "Sources/ScreenPeek")
    ]
)
