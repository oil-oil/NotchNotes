// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NotchNotes",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "NotchNotes", targets: ["NotchNotes"])
    ],
    dependencies: [
        .package(path: "Vendor/swift-markdown-engine")
    ],
    targets: [
        .executableTarget(
            name: "NotchNotes",
            dependencies: [
                .product(name: "MarkdownEngine", package: "swift-markdown-engine")
            ],
            path: "Sources/NotchNotes"
        ),
        .testTarget(
            name: "NotchNotesTests",
            dependencies: ["NotchNotes"],
            path: "Tests/NotchNotesTests"
        )
    ]
)
