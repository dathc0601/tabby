# TabbyMac — notes for Claude Code

A native macOS clone of Tabby (the Electron app in the parent directory), written in Swift.
The Electron source in `../` is the reference for behaviour; this folder is the new app.
Read `README.md` and `docs/ARCHITECTURE.md` before larger changes.

## Status

- Phase 1 (local shell + SSH, tabs, splits, hotkeys, settings, recovery) is written, builds
  on macOS (Xcode 27) and Linux, and `swift test` passes on both.
- Phase 1b done (app icon, green CI on `.github/workflows/tabby-macos.yml`, macos-15 +
  Xcode 16.4, M0 of `docs/MANUAL-CHECKS.md` passed). Phase 1c done 2026-10-22: M1–M5 of
  that list passed by hand; every fix is in its Findings table. The "process completed"
  notification check stays open: macOS refused notification permission to every local build
  on the test Mac.
- Phase 2 (started 2026-10-22, spec `docs/superpowers/specs/2026-10-22-phase-2-design.md`):
  2a redesign is in code (tokens, tab bar, content tabs, settings, cards, chip, toasts,
  splits, docking); its on-screen checks are M6. 2b personal account + sync is in code
  (`TabbySyncProtocol`, `TabbyAccount`, `TabbyApp/Account`, `../tabby-sync-server`; see
  `docs/SYNC-PROTOCOL.md`); its on-screen checks are M7. The server runs at
  https://tabby-sync.dcstyle.info since 2026-10-22 (Docker + Postgres behind nginx and
  Cloudflare; see `../tabby-sync-server/README.md`). M6 and M7 were walked on 2026-10-23
  (fixes in the Findings table); open: three mouse drags in M6, M7's no-network case, and a
  short run against the live server (M7 used a local one).
- Tests never touch the real Keychain, server or `~/.ssh`: `TestApp.boot` sets
  `TABBYMAC_SYNC_URL=memory:`, `TABBYMAC_KEYCHAIN=memory`, `TABBYMAC_SYNC_HOME`. Keep it so;
  a sync reads every saved SSH password.
- Phase 3 (started 2026-10-23, spec `docs/superpowers/specs/2026-10-23-phase-3-ssh-backend-design.md`,
  branch `claude/phase-3-libssh`): the libssh backend (`TabbySSHLib`, `CLibSSH`) is the default
  for SSH tabs; `ssh.backend: openssh` keeps the old one. SFTP panel, transfers, Ports popover,
  keyboard-interactive panel, shared connections, jump hosts, proxies, agent/X11 forwarding,
  Test connection. Needs `brew install libssh` to build. Its on-screen checks are M8, walked
  on 2026-10-23 against Docker test servers (fixes in the Findings table); open: X11 with
  XQuartz, dropping files from Finder, Show in Finder, and M4 again on `ssh.backend: openssh`.
- Phase 4 (started 2026-10-23, spec `docs/superpowers/specs/2026-10-23-phase-4-serial-telnet-design.md`,
  branch `claude/phase-4-serial-telnet`): serial (`TabbySerial`) and telnet (`TabbyTelnet`)
  sessions, Tabby's stream processing (`StreamProcessor`, `ProcessedSession`), login scripts
  for every type. Milestone 4.5 applied the owner's Claude Design canvas "Tabby
  Connections" (C1–C10: chip and pane labels, baud-rate popover, serial selectors, editor
  pages, quick-connect rows, terminal messages, alerts). On-screen checks are M9 and M9b,
  walked on 2026-10-23 against a fake device and a Docker busybox telnetd (fixes in the
  Findings table); open: saving the editor pages and the Settings items on screen, and real
  USB-serial / telnet hardware.
- Serial tests use pty pairs (`Tests/Support/PTYPair.swift`); never open a real `/dev/cu.*`
  in tests or walks, only list it. `scripts/fake-serial-device.py` is the walk's device.
- SSH integration tests start their own unprivileged sshd (`TestSSHD`); wrap runs that might
  hang with a deadline (macOS has no `timeout`), and never call `Process.waitUntilExit()` from
  an async test (it needs a run loop).
- Phase 5 (started 2026-10-24, spec `docs/superpowers/specs/2026-10-24-phase-5-design.md`,
  branch `claude/phase-5-more-of-tabby`): localization (`L()` over Tabby's catalogs in
  `Sources/TabbyCore/Resources/locale`, plus `tabbymac/vi-VN.po`), per-tab notify items and
  `Notifier`, the bell, `TabbyCLIKit` + the `tabby` helper + `CLIRouter` for links and the
  command line. On-screen checks are M10.
- Every user-visible string goes through `L("English", ["name": value])`; never a raw literal
  (CatalogTests fails). New keys: run `scripts/l10n-extract.sh` and add Vietnamese to
  `tabbymac/vi-VN.po`. Mark data that only looks like words with `// l10n-ignore: why`.
- Phase 6 (started 2026-10-24, spec `docs/superpowers/specs/2026-10-24-phase-6-design.md`,
  branch `claude/phase-6-terminal-parity`): terminal and tab parity (export, formatted copy,
  word separators, pane labels and rearranging, focus follows mouse, broadcast to every tab,
  OSC 1337, file drops, new terminal, save as profile, links, ZMODEM, sixel). On-screen checks
  are M11. The tab menu is an AppKit menu built when it opens (`TabMenu`), not SwiftUI's
  `.contextMenu`. ZMODEM interop tests need `scripts/lrzsz-image.sh` once (Docker).
- Phase 7 (started 2026-10-25, spec `docs/superpowers/specs/2026-10-25-phase-7-design.md`,
  plan `docs/superpowers/plans/2026-10-25-phase-7-settings-editors.md`, branch
  `claude/phase-7-settings-editors`): settings and profile editors (group tree and editor,
  type/group defaults, blacklist hiding, icon/colour pickers, environment editor, SSH
  connection modes, line padding, 256-colour palette, custom schemes, Display on, profile
  sidebar, dynamic hotkeys). On-screen checks are M12. `ProfileRegistry.tree` is the one
  group tree (Profiles page and sidebar); hiding writes `profileBlacklist`.
- Roadmap after phase 7: macOS integration, Tabby's vault, native
  plugin features, TabbyMac's strings in Tabby's other languages, SwiftTerm 2.0 when released.
- Screens can be checked without a display:
  `TABBYMAC_SNAPSHOT_DIR=/tmp/shots swift test --filter DesignSnapshotTests`.
- Linux: run `docker run --rm -v "$PWD/..":/src -w /src/tabby-macos swift:6.1-noble swift test
  --scratch-path /tmp/linux-build` before pushing test changes (Linux XCTest differs: test
  methods of a `@MainActor` XCTestCase must be `async`, and URLProtocol stubs cannot redirect).
- Tooling quirk: shells spawned by the Xcode coding assistant cannot allocate PTYs
  (`forkpty: Operation not permitted`), so PTY-backed tests fail there. Run them from
  Terminal, the Claude Code CLI, or Xcode's test runner.

## Commands

```sh
brew install libssh               # once: the SSH library backend links it
swift build                       # all targets
swift test                        # unit tests
swift run TabbyMacDev             # run the app without a bundle
./scripts/bootstrap-mac.sh        # xcodegen -> Xcode/TabbyMac.xcodeproj, then opens it
xcodebuild -project Xcode/TabbyMac.xcodeproj -scheme TabbyMac -configuration Debug \
  -skipPackagePluginValidation build
```

The `.xcodeproj` is generated from `Xcode/project.yml` and gitignored. Edit `project.yml`,
never the project file, and re-run xcodegen after adding files to `App/`.

## Constraints

- macOS 14+, Xcode 16+. Swift 5 language mode (`swift-tools-version 5.9`).
- SwiftTerm is pinned to exactly 1.20.0. 1.99+/2.x need Xcode 26; don't bump it unless asked.
  Check SwiftTerm API names against the 1.20.0 sources in `.build/checkouts/SwiftTerm`.
- `TabbyCore` must stay Foundation + Yams only so it builds and tests on Linux. Put AppKit
  code in `TabbyTerminal` (behind `#if canImport(AppKit)`), `TabbySSH` or `TabbyApp`.
- App sandbox is off (needed for PTYs and sockets); hardened runtime on; ad-hoc signing.
- Config lives in `~/Library/Application Support/TabbyMac/`. Never write to Electron Tabby's
  `~/Library/Application Support/tabby/`; it is only read for import.
- Config semantics follow Tabby's `ConfigProxy`: save only diffs from `defaults.yaml`,
  `__nonStructural` maps and arrays replace wholesale, unknown keys round-trip.
- Keychain names follow Tabby's keytar: service `ssh@host:port`, account = user.
- Models are `@Observable @MainActor`; AppKit views follow them with `ObservationLoop`.
- `runCommand(_:)` is deliberately not called `perform` (clashes with `NSObject.perform`).

## Working style

- Run `swift build` and `swift test` before committing.
- When porting a feature, find the Tabby implementation in `../tabby-*/src` first and keep the
  same config keys, hotkey ids and recovery token types so Tabby configs keep working.
