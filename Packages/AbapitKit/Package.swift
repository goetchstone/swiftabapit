// swift-tools-version: 6.2
// AbapitKit: everything below the SwiftUI layer. The app target sits outside this package, so a
// `package`-access symbol (the `WriteTicket`, `HTTPCore.send(_:ticket:)`, `Secret.bytes`, the read
// builders) is invisible to views and App Intents by construction (plan §3.2, L9).
//
// The screen models live in Packages/AbapitApp, outside this package as the app is (Phase 1b review).
//
// The dependency edges below are the whole graph: `PackageGraphTests` parses this file and fails on any
// edge not in its list. The pure modules (JSONAPI, AppleModels, MosyleModels, Wire, Planners, Reports,
// ProfileSchema) import only Foundation, so they build on Linux for the fuzz job. Zero third-party
// dependencies (L5): there is no `dependencies:` list, and a test holds that.

import PackageDescription

let settings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "AbapitKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "JSONAPI", targets: ["JSONAPI"]),
        .library(name: "AppleModels", targets: ["AppleModels"]),
        .library(name: "MosyleModels", targets: ["MosyleModels"]),
        .library(name: "Wire", targets: ["Wire"]),
        .library(name: "Planners", targets: ["Planners"]),
        .library(name: "Reports", targets: ["Reports"]),
        .library(name: "ProfileSchema", targets: ["ProfileSchema"]),
        .library(name: "Orgs", targets: ["Orgs"]),
        .library(name: "Vault", targets: ["Vault"]),
        .library(name: "HTTPCore", targets: ["HTTPCore"]),
        .library(name: "AppleBusiness", targets: ["AppleBusiness"]),
        .library(name: "Mosyle", targets: ["Mosyle"]),
        .library(name: "History", targets: ["History"]),
        .library(name: "ChangeCore", targets: ["ChangeCore"]),
        .library(name: "Assist", targets: ["Assist"]),
        // The strict stubs and the demo fleet: the app links it for its DEBUG demo org only (dead-stripped from
        // Release, which never references it; scripts/check_app.sh refuses the demo switch in a Release binary).
        .library(name: "TestSupport", targets: ["TestSupport"]),
    ],
    targets: [
        // Pure (Foundation only).
        .target(name: "JSONAPI", swiftSettings: settings),
        .target(name: "AppleModels", dependencies: ["JSONAPI"], swiftSettings: settings),
        .target(name: "MosyleModels", dependencies: ["JSONAPI"], swiftSettings: settings),
        .target(name: "Wire", swiftSettings: settings),
        .target(name: "Planners", dependencies: ["AppleModels", "MosyleModels", "JSONAPI", "Wire"], swiftSettings: settings),
        .target(name: "Reports", dependencies: ["AppleModels", "MosyleModels", "JSONAPI"], swiftSettings: settings),
        .target(name: "ProfileSchema", swiftSettings: settings),
        // Platform.
        .target(name: "Orgs", dependencies: ["JSONAPI"], swiftSettings: settings),
        .target(name: "Vault", swiftSettings: settings),
        .target(name: "HTTPCore", dependencies: ["Wire"], swiftSettings: settings),
        .target(name: "AppleBusiness", dependencies: ["HTTPCore", "Wire", "Vault", "Orgs", "AppleModels", "JSONAPI"], swiftSettings: settings),
        .target(name: "Mosyle", dependencies: ["HTTPCore", "Wire", "Vault", "Orgs", "MosyleModels", "JSONAPI"], swiftSettings: settings),
        .target(name: "History", dependencies: ["Orgs", "AppleModels", "MosyleModels", "Reports"], swiftSettings: settings),
        .target(name: "ChangeCore", dependencies: ["HTTPCore", "Wire", "Planners", "Vault", "Orgs"], swiftSettings: settings),
        .target(name: "Assist", dependencies: ["Planners", "Reports"], swiftSettings: settings),
        .target(name: "TestSupport", dependencies: ["HTTPCore", "Wire", "Vault", "Orgs", "AppleModels", "MosyleModels", "JSONAPI"],
                swiftSettings: settings),
        // Tests: one target per module, plus the source scans.
        .testTarget(name: "JSONAPITests", dependencies: ["JSONAPI", "TestSupport"], swiftSettings: settings),
        .testTarget(name: "AppleModelsTests", dependencies: ["AppleModels", "JSONAPI", "TestSupport"], swiftSettings: settings),
        .testTarget(name: "MosyleModelsTests", dependencies: ["MosyleModels", "JSONAPI", "TestSupport"], swiftSettings: settings),
        .testTarget(name: "WireTests", dependencies: ["Wire", "TestSupport"], swiftSettings: settings),
        .testTarget(name: "PlannersTests", dependencies: ["Planners", "AppleModels", "MosyleModels", "JSONAPI", "Wire", "TestSupport"],
                    swiftSettings: settings),
        .testTarget(name: "ReportsTests", dependencies: ["Reports", "AppleModels", "MosyleModels", "JSONAPI", "TestSupport"], swiftSettings: settings),
        .testTarget(name: "ProfileSchemaTests", dependencies: ["ProfileSchema", "TestSupport"], swiftSettings: settings),
        .testTarget(name: "OrgsTests", dependencies: ["Orgs", "JSONAPI", "TestSupport"], swiftSettings: settings),
        .testTarget(name: "VaultTests", dependencies: ["Vault", "TestSupport"], swiftSettings: settings),
        .testTarget(name: "HTTPCoreTests", dependencies: ["HTTPCore", "Wire", "TestSupport"], swiftSettings: settings),
        .testTarget(name: "AppleBusinessTests", dependencies: ["AppleBusiness", "HTTPCore", "Wire", "Vault", "Orgs", "AppleModels", "JSONAPI", "TestSupport"],
                    swiftSettings: settings),
        .testTarget(name: "MosyleTests", dependencies: ["Mosyle", "HTTPCore", "Wire", "Vault", "MosyleModels", "JSONAPI", "TestSupport"],
                    swiftSettings: settings),
        .testTarget(name: "HistoryTests", dependencies: ["History", "AppleModels", "MosyleModels", "Reports", "TestSupport"],
                    swiftSettings: settings),
        .testTarget(name: "ChangeCoreTests", dependencies: ["ChangeCore", "HTTPCore", "Wire", "Planners", "Vault", "TestSupport"],
                    swiftSettings: settings),
        .testTarget(name: "AssistTests", dependencies: ["Assist", "Planners", "Reports", "TestSupport"], swiftSettings: settings),
        .testTarget(name: "SourceScanTests", dependencies: ["TestSupport"], swiftSettings: settings),
    ]
)
