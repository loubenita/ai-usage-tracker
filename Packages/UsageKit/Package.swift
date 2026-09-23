// swift-tools-version: 6.2
import PackageDescription

// Three layers, one target each. Dependencies point inwards only:
// Presentation -> Domain, Data -> Domain. Domain depends on nothing.
let package = Package(
    name: "UsageKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "UsageDomain", targets: ["UsageDomain"]),
        .library(name: "UsageData", targets: ["UsageData"]),
        .library(name: "UsagePresentation", targets: ["UsagePresentation"]),
    ],
    targets: [
        .target(name: "UsageDomain"),
        // SQLite ships with macOS; Cursor keeps its chats in SQLite databases.
        .target(name: "UsageData", dependencies: ["UsageDomain"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "UsagePresentation", dependencies: ["UsageDomain"]),
        .testTarget(name: "UsageDomainTests", dependencies: ["UsageDomain"]),
        .testTarget(
            name: "UsageDataTests",
            dependencies: ["UsageData", "UsageDomain"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "UsagePresentationTests",
            dependencies: ["UsagePresentation", "UsageData", "UsageDomain"]
        ),
    ]
)
