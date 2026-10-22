# TabbyMac architecture

TabbyMac ports Tabby's behaviour, not its code structure. Tabby is an Electron app built
from Angular plugins that register multi-providers; TabbyMac uses a handful of Swift
modules with plain protocols and registries instead.

## Modules

| Module | Platform | Role | Tabby counterpart |
|---|---|---|---|
| `TabbyCore` | macOS, Linux | Config store and migrations, profiles and groups, hotkeys and chord matching, split layout tree, recovery tokens, colour schemes and chrome palette, ssh_config import and generation | `tabby-core`, parts of `tabby-terminal`, `tabby-ssh`, `tabby-community-color-schemes` |
| `TabbyTerminal` | macOS, Linux (except `SwiftTermEngine`) | `PTYProcess`, `TerminalSession`, `LocalSession`, `TerminalPane` controller, output processing, `SwiftTermEngine` view | `tabby-terminal`, `tabby-local`, `app/lib/pty.ts` |
| `TabbySSH` | macOS, Linux | `SSHSession` over system OpenSSH, askpass server, password stores | `tabby-ssh` |
| `TabbyIPC` | macOS, Linux | Unix-socket messages between the app and `tabby-askpass` | none |
| `TabbyApp` | macOS | Window, tab bar, split views, hotkeys, menus, selector, settings, prompts | `tabby-core` components, `tabby-settings`, `tabby-electron` |
| `tabby-askpass` | macOS, Linux | `SSH_ASKPASS` helper | none |
| `TabbySyncProtocol` | macOS, Linux | Account and sync wire format: key derivation and vault encryption (`VaultCrypto`, swift-crypto), `SyncSnapshot`, `SyncMerger`, the HTTP API types | `tabby-settings` config sync, reworked |
| `TabbyAccount` | macOS, Linux | Sign-in flows, `SyncClient`, `ChangeTracker`, `LocalSyncData`, `SyncEngine`, session storage; see [SYNC-PROTOCOL.md](SYNC-PROTOCOL.md) | none |
| `../tabby-sync-server` | Linux (Docker), macOS | Hummingbird 2 + Fluent server for accounts, devices and the encrypted vault (its own package) | tabby-web's sync API, reworked |

Everything except the AppKit and SwiftUI views compiles and is tested on Linux.
`TabbyCore` stays Foundation + Yams; crypto lives in `TabbySyncProtocol` so the core does not
pick up swift-crypto.

## Key decisions

**Terminal engine.** SwiftTerm 1.20, pinned because 1.99 and later need Xcode 26.
`SwiftTermEngine` subclasses `TerminalView` and implements the `TerminalEngine` protocol,
the equivalent of Tabby's `Frontend`. `TerminalPane` talks only to that protocol, so
another engine (for example libghostty) can be swapped in later.

**PTY.** `PTYProcess` is our own `forkpty` wrapper instead of SwiftTerm's
`LocalProcessTerminalView`. Sessions have to survive their view moving between split
containers, and we need Tabby's environment, cwd inheritance and foreground-process lookup.
Reads are back-pressured (at most four 64 KB chunks queued on the main thread) like Tabby's
`PTYDataQueue`.

**Config compatibility.** `ConfigStore` reproduces `ConfigProxy`: non-empty mappings merge
key by key, arrays and `__nonStructural` mappings are replaced wholesale, and only values
that differ from `defaults.yaml` are saved. Unknown keys round-trip, so a Tabby
`config.yaml` survives import and re-export. YAML is read with YAML 1.2 booleans like
js-yaml.

**SSH, phase 1.** `SSHSession` writes a per-session `ssh_config`, runs
`/usr/bin/ssh -F <file> tabby-target` in a PTY and sets `SSH_ASKPASS_REQUIRE=force`. Every
prompt ssh would show goes to `tabby-askpass`, which forwards it over a Unix socket. The app
answers from the keychain or shows a native sheet. Keychain items use Tabby's keytar
names: service `ssh@host:port`, account = user. A `LocalCommand` hook reports successful
authentication, which is when remembered passwords are saved. This supports every key type,
agent, certificates, ProxyJump and port forwards with almost no protocol code.

The trade-off is that there is no in-process channel API. An SFTP panel, live port-forward
editing and channel multiplexing need a library backend (libssh2 or russh through FFI).
That backend will sit behind the same `TerminalSession` protocol, so the UI won't change.

**UI separation.** Views are SwiftUI over `@Observable` models (`WindowModel`, `TabModel`,
`TerminalPane`, `ThemeManager`). AppKit hosts the window, split tree and terminal view.
`ObservationLoop` bridges model changes to AppKit layout. The phase 2 design's tokens
(`docs/DESIGN-TOKENS.md`) come from `ChromeTheme` (colours mixed in OKLab from the active
terminal scheme) and `ChromeMetrics` (sizes × spaciness); every SwiftUI root applies
`chromeEnvironment()` and views read `@Environment(\.chrome)` / `\.metrics`. Shared controls
live in `Views/Components`; prompts are SwiftUI cards shown as window sheets
(`ChromeSheet`). Settings and Welcome are content tabs (`TabModel.content`), not windows.
`DesignSnapshotTests` renders the screens to PNG when `TABBYMAC_SNAPSHOT_DIR` is set.

**Commands.** Hotkey ids, menu items, context menus and the command palette all dispatch
through `MainWindowController.runCommand(_:)` using Tabby's hotkey ids.

## Reference map

| Tabby source | TabbyMac |
|---|---|
| `tabby-core/src/services/config.service.ts`, `configDefaults*.yaml`, `*/src/config.ts` | `TabbyCore/Config`, `Resources/defaults.yaml` |
| `tabby-core/src/services/profiles.service.ts`, `api/profileProvider.ts` | `TabbyCore/Profiles` |
| `tabby-core/src/services/hotkeys.service.ts`, `hotkeys.util.ts`, `hotkeys.ts` | `TabbyCore/Hotkeys`, `TabbyApp/Input` |
| `tabby-core/src/components/splitTab.component.ts` | `TabbyCore/Split`, `TabbyApp/Split` |
| `tabby-core/src/services/tabRecovery.service.ts` | `TabbyCore/Recovery`, `RecoveryCoordinator` |
| `tabby-core/src/services/themes.service.ts`, `tabby-terminal/src/colorSchemes.ts` | `TabbyCore/ColorSchemes`, `ThemeManager` |
| `tabby-terminal/src/api/baseTerminalTab.component.ts`, `connectableTerminalTab.component.ts` | `TerminalPane` |
| `tabby-terminal/src/frontends/xtermFrontend.ts` | `SwiftTermEngine` |
| `tabby-local/src/session.ts`, `app/lib/pty.ts`, `tabby-electron/src/shells` | `PTYProcess`, `LocalSession`, `ShellDetector` |
| `tabby-ssh/src/session/ssh.ts`, `services/passwordStorage.service.ts`, `sshImporters.ts` | `TabbySSH`, `SSHConfigParser`, `SSHConfigGenerator` |
| `tabby-core/src/components/appRoot.component.*`, `tabHeader.component.*` | `MainWindowController`, `TabBarView` |
| `tabby-core/src/components/selectorModal.component.*` | `SelectorPanel` |
| `tabby-settings/src/components/*` | `TabbyApp/Settings` |
| `tabby-electron/src/services/docking.service.ts` | `DockController` |

## Roadmap

1. **Phase 1 (this code).** Local shell, SSH, tabs, splits, hotkeys, settings, recovery.
   Verified by hand against [MANUAL-CHECKS.md](MANUAL-CHECKS.md): milestones M0–M5 passed on
   2026-10-22, except the notification check, which macOS blocked for local builds.
2. **Redesign and personal account (phase 2).** 2a: the Claude Design output
   (`docs/superpowers/specs/2026-10-22-phase-2-design.md`) applied to every view; on-screen
   checks in M6. 2b: account, end-to-end encrypted sync of profiles, passwords, keys,
   known hosts and settings through `tabby-sync-server`.
3. **SSH library backend.** libssh2 or russh behind `TerminalSession`. Adds the SFTP panel,
   live port-forward editor and in-app keyboard-interactive panel.
4. **Serial and telnet.** New `ProfileProvider`s and `SessionFactory`s, using ORSSerialPort
   or IOKit for serial.
5. **More of Tabby.** Vault, config sync, `tabby://` URL and CLI handlers, localization from
   `../locale/*.po`, process-completion notifications per tab, login scripts for local
   shells, SwiftTerm 2.x once Xcode 26 is the baseline.
