// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Glint",
    platforms: [.macOS("15.2")],
    targets: [
        .executableTarget(name: "Glint")
    ],
    swiftLanguageModes: [.v5]
)
