// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NotchNotes",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "NotchNotes", targets: ["NotchNotes"]),
        .executable(name: "NotchNotesSleepHelper", targets: ["NotchNotesSleepHelper"])
    ],
    dependencies: [
        .package(path: "Vendor/swift-markdown-engine")
    ],
    targets: [
        .executableTarget(
            name: "NotchNotes",
            dependencies: [
                "SleepGuardCore",
                .product(name: "MarkdownEngine", package: "swift-markdown-engine")
            ],
            path: "Sources/NotchNotes"
        ),
        .target(name: "SleepGuardCore"),
        .executableTarget(name: "NotchNotesSleepHelper", dependencies: ["SleepGuardCore"]),
        .testTarget(name: "SleepGuardCoreTests", dependencies: ["SleepGuardCore", "NotchNotesSleepHelper"]),
        .testTarget(
            name: "NotchNotesTests",
            dependencies: ["NotchNotes"],
            path: "Tests/NotchNotesTests"
        )
    ]
)
