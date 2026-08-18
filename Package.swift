// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "keep-attention",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "keep-attention", targets: ["keep-attention"]),
        .executable(name: "keep-attention-hook", targets: ["keep-attention-hook"]),
    ],
    targets: [
        .target(
            name: "KeepAttentionCore",
            path: "Sources/KeepAttentionCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags(["-enable-testing"]),
            ]
        ),
        .executableTarget(
            name: "keep-attention",
            dependencies: ["KeepAttentionCore"],
            path: "Sources/keep-attention",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "keep-attention-hook",
            dependencies: ["KeepAttentionCore"],
            path: "Sources/keep-attention-hook",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "keep-attention-tests",
            dependencies: ["KeepAttentionCore"],
            path: "Tests/keep-attentionTestsRunner",
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
