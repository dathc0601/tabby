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

## What works (phases 1 and 2)

| Area | Status |
|---|---|
| Local shells | Login shell, one built-in profile per `/etc/shells` entry, custom local profiles, cwd inheritance for new tabs and splits |
| Terminal | SwiftTerm VT engine, 191 bundled colour schemes, font, cursor, scrollback, bell, search (⌘F), zoom, copy on select, right-click modes, middle-click paste, multi-line paste warning, bracketed paste, progress in tab, OSC title and OSC 7 cwd |
| Tabs | New, close, reopen, rename, duplicate, pin, colour, reorder by drag, tabs on any side, MRU and index switching |
| Split panes | Split in four directions, drag dividers, keyboard navigation, maximize, resize, broadcast input, explode and combine tabs |
| Hotkeys | All Tabby hotkey ids with macOS defaults, multi-key chords, editor with capture, menu shortcuts follow the config |
| Profiles | Selector (⌘E) with recents, groups, built-ins, quick connect `user@host:port`; editor for local and SSH profiles; save layout as profile |
| SSH | Password, key, agent and keyboard-interactive auth through the system OpenSSH client; native host-key and password prompts; passwords in the login keychain; jump-host chains; `~/.ssh/config` import; port forwards; connection reuse |
| Window | Integrated title bar, vibrancy, opacity, docked "Quake" mode with a global hotkey (Ctrl-Space) |
| Persistence | `config.yaml` (diff-only, like Tabby), tab and split recovery with buffer snapshots |
| Design | Phase 2 redesign: colour-scheme-derived tokens, tab bar with overflow menu and drag slot, Settings and a first-run Welcome page as tabs, card-style prompts, SSH status chip, toasts, split drop zones |
| Account & sync | Personal account (email + password, recovery key) at `https://tabby-sync.dcstyle.info`; profiles, groups, settings, saved passwords and passphrases, approved private keys and known hosts sync end-to-end encrypted between Macs ([docs/SYNC-PROTOCOL.md](docs/SYNC-PROTOCOL.md)); Settings › Vault lists the saved passwords |

Not yet: serial and telnet, SFTP panel, live port-forward editing, plugins, localization,
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
