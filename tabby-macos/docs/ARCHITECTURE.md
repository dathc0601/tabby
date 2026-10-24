# TabbyMac architecture

TabbyMac ports Tabby's behaviour, not its code structure. Tabby is an Electron app built
from Angular plugins that register multi-providers; TabbyMac uses a handful of Swift
modules with plain protocols and registries instead.

## Modules

| Module | Platform | Role | Tabby counterpart |
|---|---|---|---|
| `TabbyCore` | macOS, Linux | Config store and migrations, profiles and groups, hotkeys and chord matching, split layout tree, recovery tokens, colour schemes and chrome palette, ssh_config import and generation, serial and telnet providers, stream processing, the telnet protocol, localization (`L()` over Tabby's `.po` catalogs), ZMODEM (`TabbyCore/ZModem`), link resolution and formatted copy (`TabbyCore/Terminal`) | `tabby-core`, parts of `tabby-terminal`, `tabby-ssh`, `tabby-community-color-schemes` |
| `TabbyTerminal` | macOS, Linux (except `SwiftTermEngine`) | `PTYProcess`, `TerminalSession`, `LocalSession`, `ProcessedSession`, `TerminalPane` controller, output processing, `ZModemBridge`, `SwiftTermEngine` view | `tabby-terminal`, `tabby-local`, `app/lib/pty.ts` |
| `TabbySSH` | macOS, Linux | `SSHSession` over system OpenSSH (the `openssh` backend), askpass server, password stores | `tabby-ssh` |
| `TabbySSHLib` | macOS | The `library` backend over libssh (`CLibSSH`): `SSHConnection`, `LibSSHSession`, `SSHConnector` (sharing, jump hosts), port forwards, `SFTPClient` | `tabby-ssh` (russh) |
| `TabbySerial` | macOS | `SerialPort` (termios, `IOSSIOSPEED`, exclusive open), `SerialPortList` (IOKit, hot-plug), `SerialSession` | `tabby-serial` (serialport) |
| `TabbyTelnet` | macOS | `TelnetSession` over Network.framework | `tabby-telnet` |
| `TabbyIPC` | macOS, Linux | Unix-socket messages between the app and `tabby-askpass` | none |
| `TabbyApp` | macOS | Window, tab bar, split views, hotkeys, menus, selector, settings, prompts | `tabby-core` components, `tabby-settings`, `tabby-electron` |
| `tabby-askpass` | macOS, Linux | `SSH_ASKPASS` helper | none |
| `TabbyCLIKit` | macOS, Linux | Tabby's command line and `tabbymac://` / `ssh://` / `telnet://` links parsed into one `CLIRequest` | `app/lib/cli.ts`, `app/lib/urlHandler.ts` |
| `tabby` | macOS (builds on Linux) | The command-line helper in `Contents/MacOS`; hands requests to the app as `tabbymac://` links | Tabby's own binary with arguments |
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

The trade-off is that there is no in-process channel API, which SFTP, live port forwards and
an in-app keyboard-interactive panel need. Since phase 3 this is the `openssh` backend,
chosen with `ssh.backend: openssh` in config.yaml or a profile's `backend` option.

**SSH, phase 3: the library backend (default).** `TabbySSHLib` runs SSH in-process over
libssh (spec: `docs/superpowers/specs/2026-10-23-phase-3-ssh-backend-design.md`).
- Each `SSHConnection` owns one libssh session on its own thread. That thread connects,
  checks the host key against the app's known_hosts and `~/.ssh/known_hosts` (hashed entries
  read too), and logs in with Tabby's plan (`SSHAuthPlan`: agent, keys, saved password,
  keyboard-interactive, prompt). Then it runs an `ssh_event` loop; other threads hand it work
  through a wake pipe, so no libssh call happens anywhere else.
- Channels use libssh's callback tables. Local sockets are joined to channels by
  flow-controlled bridges (1 MiB buffer, the server's window as back-pressure), which carry
  jump hosts, local and dynamic (SOCKS5) forwards, remote forwards, agent forwarding and X11.
- `SSHConnector` shares connections between tabs (`reuseSession`, Tabby's key) in place of
  ControlMaster, and builds jump-host chains.
- `SFTPClient` moves 256 KiB per step, so shells keep running during transfers.
- `LibSSHSession` is the `TerminalSession`. Its questions go to `LibSSHPromptPresenter`
  (cards, and the keyboard-interactive panel in the pane).
- The app bundles libssh and libcrypto (`scripts/bundle-libssh.sh`, from Homebrew's
  `libssh`). They are built for the build Mac's macOS, so the script raises the app's
  `LSMinimumSystemVersion` to theirs (with a build warning). Building them from source for
  macOS 14 is a follow-up.
- Tests run against a throwaway unprivileged `/usr/sbin/sshd` on a free port
  (`Tests/TabbySSHLibTests/TestSSHD.swift`); nothing touches `~/.ssh`.

**Serial and telnet, phase 4.** Spec:
`docs/superpowers/specs/2026-10-23-phase-4-serial-telnet-design.md`.
- The byte-level logic is in TabbyCore and tested on Linux. `StreamProcessor` is Tabby's
  `TerminalStreamProcessor`: local echo, a line editor for the line-by-line and hex input
  modes, hexdump output, newline translation. `TelnetProtocol` is the negotiation, as a state
  machine.
- `ProcessedSession` (TabbyTerminal) wraps a raw serial or telnet session with the profile's
  stream processing. Service lines skip it, as in Tabby. SSH and local sessions are not
  wrapped.
- `SerialPort` opens `/dev/cu.*` in raw mode with the profile's line settings. Rates termios
  lacks go through `IOSSIOSPEED`. The port is exclusive (`TIOCEXCL`, plus a per-process list).
  Reads run on a dispatch source, and a read of nothing is the device going away.
  `SerialPortList` follows IOKit hot-plug.
- A serial profile without a port or rate asks for them before its tab opens (`WindowModel`
  → `completeSerialProfile`). The answers stay with the tab and its recovery token.
- `TelnetSession` runs on `NWConnection`. A connection is a raw socket until the peer sends
  IAC.
- Login scripts and `clearServiceMessagesOnConnect` now apply to every type. Tests use pty
  pairs and an in-process scripted TCP server (`Tests/Support`).

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

**Localization (phase 5).** Every user-visible string goes through `L("English", [args])`
(TabbyCore, thread-safe). The catalogs are Tabby's own gettext files, copied from
`../locale` by `scripts/sync-locale.sh`, plus TabbyMac's: `tabbymac/tabbymac.pot` (written
by `scripts/l10n-extract.sh`) and `tabbymac/vi-VN.po`. The lookup also matches a msgid
that differs only in case or a trailing "…"/":", so TabbyMac's title-case menus still
find Tabby's translations. `language` in config.yaml (null: the system's languages)
applies live. `CatalogTests` fails on a key missing from the catalogs, an out-of-date
template, a Vietnamese gap, or a user-visible literal that skips `L()`.

**Links and the command line (phase 5).** `TabbyCLIKit` parses `tabby open/run/profile/
paste/recent/quickConnect/<path>` and `tabbymac://`, `ssh://` and `telnet://` links into a
`CLIRequest`. The `tabby` helper resolves paths where it runs and opens the request as a
`tabbymac://` link with its own app (NSWorkspace launches it or hands the link to the
running one), so no socket or single-instance lock is needed. `CLIRouter` in the app does
what Tabby's `CLIHandler`s do; requests that arrive before the first window wait.

**Notifications (phase 5).** "Notify when done" polls the pane's foreground process once
a second (Tabby's `CompletionObserver`); "Notify on activity" fires on the next output.
`Notifier` posts banners carrying the pane id, so opening one focuses that pane; an
in-app toast shows as well, because macOS refuses banners to ad-hoc signed builds.

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
| `tabby-serial/src/*` | `TabbyCore/Serial`, `TabbySerial`, `SerialSelectors` |
| `tabby-telnet/src/*` | `TabbyCore/Telnet`, `TabbyTelnet` |
| `tabby-terminal/src/middleware/streamProcessing.ts`, `loginScriptProcessing.ts` | `StreamProcessor`, `ProcessedSession`, `LoginScriptRunner` |
| `tabby-core/src/services/locale.service.ts`, `locale/*.po` | `TabbyCore/L10n`, `Resources/locale` |
| `app/lib/cli.ts`, `app/lib/urlHandler.ts`, `*/src/cli.ts` (`CLIHandler`s) | `TabbyCLIKit`, `TabbyCLI` (`tabby`), `CLIRouter` |
| `tabby-core/src/tabContextMenu.ts` (`TaskCompletionContextMenu`), `app.service.ts` (`CompletionObserver`) | `NotifyMenu`, `TerminalPane.setNotifyWhenDone`, `Notifier` |
| `tabby-core/src/tabContextMenu.ts` (`CommonOptionsContextMenu`), `splitTabPaneLabel.component.ts`, `splitTabDropZone.component.ts` | `TabMenu`, `PaneLabels.swift` (`PaneTitleLabel`, `RearrangeOverlayView`), `SplitTreeView.paneDropZone`, `SplitLayout.move` |
| `tabby-terminal/src/services/multifocus.service.ts` | `WindowModel.broadcastAllTabs`, `BroadcastIndicatorView` |
| `tabby-terminal/src/tabContextMenu.ts` (`SaveAsProfileContextMenu`), `tabby-local/src/tabContextMenu.ts` (`NewTabContextMenu`) | `saveAsProfile`, `openNewTerminal`, `NewTabMenu` |
| `tabby-electron/src/terminalContextMenu.ts`, `pathDrop.ts` | `exportBuffer`, `dropFiles`, `PathDrop` |
| `tabby-terminal/src/frontends/xtermFrontend.ts` (`copyAsHTML`, `wordSeparator`) | `TerminalHTML`, `WordSelection`, `SwiftTermEngine.copySelection` |
| `tabby-terminal/src/middleware/oscProcessing.ts` | `TerminalOSC`, `SwiftTermEngine.iTermContent` |
| `tabby-linkifier/src/*` | `LinkTarget`, `LinkDetector`, `LinkModifier`, `MainWindowController.openLink` |
| `tabby-terminal/src/features/zmodem.ts` (zmodem.js) | `TabbyCore/ZModem`, `ZModemBridge`, `ZModemUI` |

## Roadmap

1. **Phase 1 (this code).** Local shell, SSH, tabs, splits, hotkeys, settings, recovery.
   Verified by hand against [MANUAL-CHECKS.md](MANUAL-CHECKS.md): milestones M0–M5 passed on
   2026-10-22, except the notification check, which macOS blocked for local builds.
2. **Redesign and personal account (phase 2).** 2a: the Claude Design output
   (`docs/superpowers/specs/2026-10-22-phase-2-design.md`) applied to every view; on-screen
   checks in M6. 2b: account, end-to-end encrypted sync of profiles, passwords, keys,
   known hosts and settings through `tabby-sync-server`, deployed at
   https://tabby-sync.dcstyle.info on 2026-10-22; on-screen checks in M7. M6 and M7 walked on
   2026-10-23.
3. **SSH library backend (phase 3).** libssh behind `TerminalSession`: SFTP panel and
   transfers, live port forwards, the keyboard-interactive panel, shared connections, jump
   hosts, SOCKS/HTTP proxies, agent and X11 forwarding, Test connection. On-screen checks in
   M8.
4. **Serial and telnet (phase 4).** Serial ports over termios and IOKit, telnet and raw
   sockets over Network.framework, Tabby's stream processing, login scripts for every type.
   The screens follow the owner's Claude Design canvas "Tabby Connections". On-screen
   checks in M9 and M9b.
5. **More of Tabby (phase 5).** Localization from Tabby's catalogs plus Vietnamese,
   per-tab "Notify when done" and "Notify on activity", the bell's Dock flash, `ssh://` and
   `telnet://` links, the `tabby` command line. On-screen checks in M10.
6. **Terminal and tab parity (phase 6).** Export to file, copy with formatting, word
   separators, pane labels and rearranging panes, focus follows mouse, broadcast to every
   tab, OSC 1337 folders, dropped files, New terminal / New with profile, Save as profile,
   Tabby's link options, ZMODEM, the Sixel switch. On-screen checks in M11.
7. **Next.** The settings and profile editors Tabby has and TabbyMac lacks (group editing,
   per-group and per-type defaults, the environment editor), macOS integration (Dock menu,
   Finder services, menu bar icon, updates), Tabby's vault; native versions of popular
   plugins; TabbyMac's own strings in Tabby's other languages; SwiftTerm 2.0 once it is
   released (1.99 previews need Swift 6.2).
