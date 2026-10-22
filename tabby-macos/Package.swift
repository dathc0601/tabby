// swift-tools-version:5.9
//
// TabbyMac: a native macOS clone of Tabby (https://github.com/Eugeny/tabby).
//
// Targets:
//   TabbyCore      Platform-independent model: config, profiles, hotkeys, split tree,
//                  recovery tokens, colour schemes, ssh_config parsing. Builds and is
//                  unit-tested on Linux as well as macOS.
//   TabbyTerminal  macOS: PTY, sessions, SwiftTerm-backed terminal engine, terminal tabs.
//   TabbySSH       macOS: SSH sessions over the system OpenSSH client with native prompts.
//   TabbyApp       macOS: AppKit window, tab bar, split panes, SwiftUI settings and modals.
//   TabbyIPC       Unix-socket messages shared by the app and the askpass helper.
//   tabby-askpass  Tiny helper that OpenSSH runs as SSH_ASKPASS; forwards prompts to the app.
//   TabbySyncProtocol  Account & sync wire format shared with ../tabby-sync-server: DTOs,
//                  SyncSnapshot, SyncMerger, VaultCrypto. Foundation + swift-crypto only (no
//                  TabbyCore) so the server can use it; builds and is tested on Linux too.
//
// The .app bundle itself is produced by the Xcode project generated from Xcode/project.yml.

import PackageDescription

let package = Package(
    name: "TabbyMac",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TabbyCore", targets: ["TabbyCore"]),
        .library(name: "TabbyApp", targets: ["TabbyApp"]),
        .library(name: "TabbySyncProtocol", targets: ["TabbySyncProtocol"]),
        .executable(name: "tabby-askpass", targets: ["TabbyAskpass"]),
        .executable(name: "TabbyMacDev", targets: ["TabbyMacDev"]),
    ],
    dependencies: [
        // Pinned to the last 1.x release that builds with Xcode 16 (swift-tools 6.0).
        // 1.99+/2.0 requires swift-tools 6.2 (Xcode 26); see docs/ARCHITECTURE.md.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        // 3.x only: swift-crypto 4/5 need swift-tools 6.2, the macOS CI uses Xcode 16.4.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"),
    ],
    targets: [
        .target(
            name: "TabbyCore",
            dependencies: [.product(name: "Yams", package: "Yams")],
            resources: [
                .copy("Resources/defaults.yaml"),
                .copy("Resources/schemes"),
            ]
        ),
        .target(
            name: "TabbyTerminal",
            dependencies: [
                "TabbyCore",
                .product(name: "SwiftTerm", package: "SwiftTerm", condition: .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "TabbyIPC",
            dependencies: []
        ),
        .target(
            name: "TabbySSH",
            dependencies: ["TabbyCore", "TabbyTerminal", "TabbyIPC"]
        ),
        .target(
            name: "TabbyApp",
            dependencies: ["TabbyCore", "TabbyTerminal", "TabbySSH"]
        ),
        // `swift run TabbyMacDev` starts the app without an .app bundle (handy for development).
        .executableTarget(
            name: "TabbyMacDev",
            dependencies: ["TabbyApp", "TabbyAskpass"]
        ),
        .executableTarget(
            name: "TabbyAskpass",
            dependencies: ["TabbyIPC"]
        ),
        .target(
            name: "TabbySyncProtocol",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "TabbySyncProtocolTests",
            dependencies: ["TabbySyncProtocol", .product(name: "Crypto", package: "swift-crypto")],
            // swift-crypto's BoringSSL is C++, so the Linux test bundle links libstdc++, and
            // gold then checks the undefined symbols of the shared libraries it loads. Swift
            // 6.1's libswiftObservation.so (TabbyTerminal imports Observation) references
            // swift::threading::fatal, which no 6.1 runtime library exports; fixed in 6.2.
            linkerSettings: [.unsafeFlags(["-Xlinker", "--allow-shlib-undefined"], .when(platforms: [.linux]))]
        ),
        .testTarget(
            name: "TabbyTerminalTests",
            dependencies: ["TabbyCore", "TabbyTerminal", "TabbySSH", "TabbyIPC"]
        ),
        .testTarget(
            name: "TabbyAppTests",
            dependencies: ["TabbyApp"]
        ),
        .testTarget(
            name: "TabbyCoreTests",
            dependencies: ["TabbyCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
