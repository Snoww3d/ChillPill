// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ChillPill",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "CChillPillIOKit",
            path: "Sources/CChillPillIOKit",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .target(
            name: "ChillPillShared",
            path: "Sources/ChillPillShared"
        ),
        .executableTarget(
            name: "ChillPillHelper",
            dependencies: ["CChillPillIOKit", "ChillPillShared"],
            path: "Sources/ChillPillHelper"
        ),
        .executableTarget(
            name: "ChillPill",
            dependencies: ["ChillPillShared"],
            path: "Sources/ChillPill"
        ),
        .testTarget(
            name: "ChillPillSharedTests",
            dependencies: ["ChillPillShared"],
            path: "Tests/ChillPillSharedTests"
        )
    ]
)
