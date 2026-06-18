// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ProxySwitcher",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ProxySwitcher",
            path: "Sources/ProxySwitcher"
        )
    ]
)
