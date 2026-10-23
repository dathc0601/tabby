# TabbyMac

A native macOS clone of [Tabby](../README.md), written in Swift with AppKit, SwiftUI and
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm). It reads Tabby's `config.yaml`
format, so profiles, hotkeys and colour schemes carry over.

"TabbyMac" and the bundle id `com.example.tabbymac` are placeholders; see
[Renaming](#renaming).

## Requirements

- macOS 14 Sonoma or later
- Xcode 16 or later (SwiftTerm 1.20 uses swift-tools 6.0)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) for the app bundle (`brew install xcodegen`)
- libssh for the SSH client (`brew install libssh`); the app bundle carries its own copy.
  Homebrew builds it for the Mac it runs on, so the bundled app needs that macOS too (the
  build raises `LSMinimumSystemVersion` and warns; e.g. 27.0 when built on macOS 27)

## Build and run

```sh
cd tabby-macos
./scripts/bootstrap-mac.sh        # generates Xcode/TabbyMac.xcodeproj and opens it
```

In Xcode choose the **TabbyMac** scheme and **My Mac**, then press ⌘R. On the first build
Xcode asks you to trust SwiftTerm's build plugin (`SwiftTermBuildInfoPlugin`); choose
**Trust & Enable**. From the command line, pass `-skipPackagePluginValidation` to
`xcodebuild`.

Without the Xcode project, for quick iteration:

```sh
swift run TabbyMacDev             # runs the app from .build/, no .app bundle
swift test                        # unit tests (also run on Linux)
```

`swift run` works for everything except notifications, which need a bundle.

The global show/hide hotkey defaults to Ctrl-Space, as in Tabby. macOS also uses Ctrl-Space
to switch input sources, and while TabbyMac runs the key doesn't reach the terminal. Rebind
"Show/hide window (global)" in **Settings → Hotkeys** if that gets in your way.

The first launch starts with defaults. To bring over your Electron Tabby setup, open
**Settings → Application → Import Tabby's config.yaml**. Your Electron Tabby files are only
read, never written.

## What works (phases 1 to 4)

| Area | Status |
|---|---|
| Local shells | Login shell, one built-in profile per `/etc/shells` entry, custom local profiles, cwd inheritance for new tabs and splits |
| Terminal | SwiftTerm VT engine, 191 bundled colour schemes, font, cursor, scrollback, bell, search (⌘F), zoom, copy on select, right-click modes, middle-click paste, multi-line paste warning, bracketed paste, progress in tab, OSC title and OSC 7 cwd |
| Tabs | New, close, reopen, rename, duplicate, pin, colour, reorder by drag, tabs on any side, MRU and index switching |
| Split panes | Split in four directions, drag dividers, keyboard navigation, maximize, resize, broadcast input, explode and combine tabs |
| Hotkeys | All Tabby hotkey ids with macOS defaults, multi-key chords, editor with capture, menu shortcuts follow the config |
| Profiles | Selector (⌘E) with recents, groups, built-ins, quick connect; editor for local, SSH, serial and telnet profiles; save layout as profile |
| SSH | Built-in client (libssh): password, key, agent and keyboard-interactive auth (2FA panel in the pane); host keys in known_hosts with a changed-key warning; passwords in the login keychain; jump-host chains; SOCKS/HTTP proxies and proxy commands; agent and X11 forwarding; shared connections; `~/.ssh/config` import; Test connection. `ssh.backend: openssh` uses the system OpenSSH client instead |
| SFTP and forwards | SFTP panel in the pane (browse, filter, upload by drop, download, folder download, Edit locally, delete); transfers popover; live local, remote and dynamic (SOCKS) port forwards from the connection chip |
| Serial | Ports listed through IOKit and kept current; a profile per port, ⌥K selector, quick connect `/dev/cu.x@9600`; asks for the port and baud rate when a profile has none; data/stop bits, parity, RTS/CTS and XON/XOFF, slow feed; change the rate while connected from the chip's popover |
| Telnet | Telnet with Tabby's option negotiation (echo, window size, terminal type) and raw TCP sockets; quick connect `host:port` |
| Stream processing | For serial and telnet: local echo, line-by-line and hex input, hexdump output, newline translation; login scripts on every profile type |
| Window | Integrated title bar, vibrancy, opacity, docked "Quake" mode with a global hotkey (Ctrl-Space) |
| Persistence | `config.yaml` (diff-only, like Tabby), tab and split recovery with buffer snapshots |
| Design | Phase 2 redesign: colour-scheme-derived tokens, tab bar with overflow menu and drag slot, Settings and a first-run Welcome page as tabs, card-style prompts, SSH status chip, toasts, split drop zones |
| Account & sync | Personal account (email + password, recovery key) at `https://tabby-sync.dcstyle.info`; profiles, groups, settings, saved passwords and passphrases, approved private keys and known hosts sync end-to-end encrypted between Macs ([docs/SYNC-PROTOCOL.md](docs/SYNC-PROTOCOL.md)); Settings › Vault lists the saved passwords |

Not yet: plugins, localization,
ligatures (SwiftTerm limitation). See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#roadmap).

## Files

| Path | Contents |
|---|---|
| `~/Library/Application Support/TabbyMac/config.yaml` | Settings, profiles, hotkeys (Tabby format) |
| `~/Library/Application Support/TabbyMac/recovery.json` | Open tabs, restored on launch |
| `~/Library/Application Support/TabbyMac/known_hosts` | SSH host keys accepted in the app |
| `~/Library/Application Support/TabbyMac/config.yaml.backup` | Copy of the last saved `config.yaml` |
| `~/Library/Application Support/TabbyMac/config.yaml.before-sign-in` | This Mac's settings as they were before the last sign-in replaced them with the account's |
| `~/Library/Application Support/TabbyMac/sync-state.json` | Sync bookkeeping (per-item hashes and times, the vault revision) |
| `~/Library/Application Support/TabbyMac/keys/` | Private keys that arrived from the account (owner-only), used when the original file is missing on this Mac |
| `/tmp/tabbymac-<uid>/` | Askpass socket, per-session ssh_config, ControlMaster sockets |

Set `TABBYMAC_CONFIG_DIRECTORY` to use another config directory.

## Tests

`swift test` runs on macOS and Linux. The SSH end-to-end tests need a reachable sshd:

```sh
swift build --product tabby-askpass
TABBYMAC_SSH_TEST_PORT=22 TABBYMAC_SSH_TEST_USER=$USER TABBYMAC_SSH_TEST_PASSWORD=... \
TABBYMAC_ASKPASS=$PWD/.build/debug/tabby-askpass swift test --filter SSHSessionTests
```

CI is in `.github/workflows/tabby-macos.yml`. It runs the core tests on Linux and builds the
package, the tests and the Xcode app on a macOS runner.

Behaviour that unit tests can't cover is checked by hand against
[docs/MANUAL-CHECKS.md](docs/MANUAL-CHECKS.md).

## Renaming

Change `ConfigPaths.appDirectoryName` (TabbyCore), `PRODUCT_NAME` and
`PRODUCT_BUNDLE_IDENTIFIER` in `Xcode/project.yml`, and the display strings in `App/Info.plist`.

## Redesign

The UI layer is SwiftUI views over observable models, so a redesign replaces files in
`Sources/TabbyApp/Views` and `Sources/TabbyApp/Settings` without touching the terminal or
SSH code. The brief for Claude Design is in
[docs/claude-design-prompt.md](docs/claude-design-prompt.md).
