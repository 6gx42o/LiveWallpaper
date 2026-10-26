// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LiveWallpaper",
    platforms: [.macOS(.v15)],
    targets: [.executableTarget(name: "LiveWallpaper")],
    swiftLanguageModes: [.v5]
)
