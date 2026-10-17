// swift-tools-version: 6.2
// AbapitApp: the screen models (orgs, devices, the inspector), outside AbapitKit as the app is. They were moved into
// AbapitKit to be testable (Phase 1b review M6), and there the compiler let them see every `package` declaration (a
// secret's bytes, the Vault's reads and signatures, the read builders); a source scan held the line and missed a read
// through implicit `self`. In their own package they see AbapitKit's public API only, as the app does, and the
// compiler holds the boundary (plan §3.2, L9).
//
// One dependency, AbapitKit by path, products only: `scripts/check_graph.py` holds this manifest to that, and refuses
// `unsafeFlags` (a `-package-name abapitkit` would reopen the boundary).

import PackageDescription

let settings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let kit = "AbapitKit"

let package = Package(
    name: "AbapitApp",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "AppModels", targets: ["AppModels"]),
    ],
    dependencies: [
        .package(path: "../AbapitKit"),
    ],
    targets: [
        // Never HTTPCore, Wire or ChangeCore: no read is built and no write is reachable from a screen model.
        .target(name: "AppModels", dependencies: [
            .product(name: "AppleBusiness", package: kit), .product(name: "AppleModels", package: kit),
            .product(name: "Orgs", package: kit), .product(name: "Vault", package: kit), .product(name: "Reports", package: kit),
        ], swiftSettings: settings),
        .testTarget(name: "AppModelsTests", dependencies: [
            "AppModels",
            .product(name: "AppleBusiness", package: kit), .product(name: "AppleModels", package: kit),
            .product(name: "Orgs", package: kit), .product(name: "Vault", package: kit), .product(name: "Reports", package: kit),
            .product(name: "JSONAPI", package: kit), .product(name: "HTTPCore", package: kit), .product(name: "TestSupport", package: kit),
        ], swiftSettings: settings),
    ]
)
