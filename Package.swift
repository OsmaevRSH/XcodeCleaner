// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XcodeCleaner",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "XcodeCleanerCore"),
        .executableTarget(
            name: "XcodeCleaner",
            dependencies: ["XcodeCleanerCore"]
        ),
        .testTarget(
            name: "XcodeCleanerCoreTests",
            dependencies: ["XcodeCleanerCore"]
        ),
    ]
)
