// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CodexHUD",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "CodexHUD", targets: ["CodexHUD"])
    ],
    targets: [
        .executableTarget(
            name: "CodexHUD",
            path: "Sources/CodexHUD",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "CodexHUDTests",
            dependencies: ["CodexHUD"],
            path: "Tests/CodexHUDTests"
        )
    ]
)
