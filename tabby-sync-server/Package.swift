// swift-tools-version:6.0
//
// tabby-sync-server: the account & sync service for TabbyMac (see README.md).
//
// Targets:
//   SyncServer          Library: configuration, Fluent models and migrations, the /v1 routes.
//   tabby-sync-server   Executable: reads the environment and runs the application.
//   SyncServerTests     In-process tests (HummingbirdTesting, SQLite in memory).
//
// The wire format (DTOs, VaultCrypto) comes from the TabbySyncProtocol product of the app's
// package in ../tabby-macos, so the Docker build context must be the repository root.

import PackageDescription

let package = Package(
    name: "tabby-sync-server",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "tabby-sync-server", targets: ["tabby-sync-server"]),
        .library(name: "SyncServer", targets: ["SyncServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.5.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-fluent.git", from: "2.0.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.8.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.10.0"),
        .package(url: "https://github.com/vapor/fluent-kit.git", from: "1.48.0"),
        .package(url: "https://github.com/vapor/sql-kit.git", from: "3.28.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        // Same range as ../tabby-macos (4.x needs swift-tools 6.2 there).
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"),
        .package(path: "../tabby-macos"),
    ],
    targets: [
        .target(
            name: "SyncServer",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdFluent", package: "hummingbird-fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "FluentKit", package: "fluent-kit"),
                .product(name: "SQLKit", package: "sql-kit"),
                .product(name: "TabbySyncProtocol", package: "tabby-macos"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "tabby-sync-server",
            dependencies: ["SyncServer", .product(name: "Logging", package: "swift-log")]
        ),
        .testTarget(
            name: "SyncServerTests",
            dependencies: [
                "SyncServer",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                // The app's own client and sync engine, for the client ↔ server end-to-end test.
                .product(name: "TabbyAccount", package: "tabby-macos"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
    ]
)
