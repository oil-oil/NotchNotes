// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NotchNotes",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "NotchNotes", targets: ["NotchNotes"]),
        .executable(name: "NotchNotesSleepHelper", targets: ["NotchNotesSleepHelper"]),
        .executable(name: "notch-notes", targets: ["NotchNotesCLI"])
    ],
    dependencies: [
        .package(path: "Vendor/swift-markdown-engine")
    ],
    targets: [
        .target(
            name: "NotchNotesCore",
            path: "Sources/NotchNotesCore"
        ),
        .executableTarget(
            name: "NotchNotes",
            dependencies: [
                "NotchNotesCore",
                "SleepGuardCore",
                .product(name: "MarkdownEngine", package: "swift-markdown-engine")
            ],
            path: "Sources/NotchNotes"
        ),
        .executableTarget(
            name: "NotchNotesCLI",
            dependencies: ["NotchNotesCore"],
            path: "Sources/NotchNotesCLI"
        ),
        .target(name: "SleepGuardCore"),
        .executableTarget(name: "NotchNotesSleepHelper", dependencies: ["SleepGuardCore"]),
        .testTarget(name: "SleepGuardCoreTests", dependencies: ["SleepGuardCore", "NotchNotesSleepHelper"]),
        .testTarget(
            name: "NotchNotesTests",
            dependencies: ["NotchNotes", "NotchNotesCore"],
            path: "Tests/NotchNotesTests"
        )
    ]
)
