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
        .executableTarget(
            name: "ChillPill",
            dependencies: ["CChillPillIOKit"],
            path: "Sources/ChillPill"
        )
    ]
)
