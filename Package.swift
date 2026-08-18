// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "keep-attention",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "keep-attention",
            path: "Sources/keep-attention",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "keep-attentionTests",
            dependencies: ["keep-attention"],
            path: "Tests/keep-attentionTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xfrontend", "-disable-cross-import-overlays",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ]),
                .linkedFramework("Testing"),
            ]
        ),
    ]
)
