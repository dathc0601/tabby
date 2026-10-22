# Phase 2 design: redesign (2a) and personal account + sync (2b)

Written 2026-10-22 from the Claude Design canvases (`Tabby Design Canvas.zip`, kept out of git;
re-attach it to compare screens) and the owner's decisions. Token, metric, type and icon
tables: [DESIGN-TOKENS.md](../../DESIGN-TOKENS.md).


## Context

Phase 1c closed on 2026-10-22: TabbyMac (`tabby-macos/`) passes M0–M5, CI is green, the
branch `claude/modest-einstein-y8eodm` on `dathc0601/tabby` is in sync. The owner generated
the redesign in Claude Design (`Tabby Design Canvas.zip`, extracted read-only to the
scratchpad) and added a feature that Tabby does not have: a **personal account** whose
profiles, connections, passwords, private keys, known hosts and settings sync through our
own server, so a second Mac is ready to connect right after sign-in.

Decisions taken in this conversation (the owner's):
- **Sequence:** 2a redesign first, checked on screen; 2b account & sync built on the new
  components.
- **Backend:** a new service in this repo, `tabby-sync-server/`, Swift (Hummingbird 2 +
  Fluent, SQLite for dev / Postgres for prod), shipped as a Docker image the owner deploys.
- **Encryption:** password-derived end-to-end encryption, recovery key at sign-up, **no**
  device-approval flow (the A7 "Approve this Mac" screen is deferred).
- **Sign-in:** email + password only (passkey and GitHub deferred).
- **Settings opens as a tab**, as in the design and in Electron Tabby.
- **2a includes new behaviour:** welcome tab, tab overflow + drag polish, in-app toasts,
  drop zones when dragging a tab into a pane.
- **Server URL** is built in as `https://sync.dcstyle.info` (a constant the owner can
  change in code); registration is open (rate-limited per IP); **no self-hosted / change
  server UI**: the "Sync server" and "Self-hosted URL" rows of A4 are dropped.
- **Private keys that sync:** keys named in a profile's `privateKeys` **and** ssh's
  default identities (`~/.ssh/id_rsa`, `id_ecdsa`, `id_ed25519`, `id_dsa`, …), each
  confirmed once per key file in a sheet before its first upload. Hosts imported from
  `~/.ssh/config` are never uploaded (they re-import on the other Mac).
- **Design canvases stay out of git.** This session reads the extracted copy in the
  scratchpad (an extracted copy outside the repo); later sessions need the zip re-attached.

Settled by me after the builder check (override if wrong): the Vault settings page is a
Keychain-backed list of the synced secrets with no unlock modal (Tabby's passphrase vault
is not ported; the "Use vault for passwords" toggle and the unlock-vault modal are
dropped); the recovery key is kept encrypted in the vault so "View…" can show it after a
password re-entry, "Regenerate…" re-wraps; a recovery-key sign-in exists so a forgotten
password without a signed-in Mac does not lose the account; the Appearance rows
"Interface follows colour scheme" and "Accent source" are hidden until such a mode
exists; plain `http://` is accepted for `localhost`/`127.0.0.1` only (tests and Docker).

Calls I made (override any of them): scrypt instead of Argon2id (memory-hard like
Argon2id and already in `swift-crypto`'s `_CryptoExtras`, which also ships PBKDF2; no
Argon2 exists in swift-crypto or CryptoKit, and parameters are versioned so Argon2id can
replace it later); one encrypted snapshot blob
with a revision number and optimistic concurrency instead of per-item sync; the
encryption key is random and wrapped (Bitwarden model) so a password change never
re-encrypts the vault; the tab bar stays SwiftUI (the design note says NSView, but the
current hosting already is the drag region and works); Argon2/PBKDF2, HKDF and AES-GCM
come from `swift-crypto` so the protocol target also tests on Linux.

Standing constraints: personal identity `dcstylexf <dcstylexf@gmail.com>`, every `gh` call
pinned with `GH_TOKEN="$(gh auth token --user dathc0601)"`, identity check before every
push, TabbyCore stays Foundation + Yams, SwiftTerm pinned to 1.20.0, edit
`Xcode/project.yml` never the xcodeproj, TDD (watch the test fail first), `swift build` +
`swift test` before each commit, one commit per step, push and watch CI.

## Design reference (from the canvas; what the code must match)

**Tokens** (board `tokens`; derive once per scheme change, OKLab mixing):

| token | from | used for |
|---|---|---|
| surface | scheme.background | window, terminal, active tab |
| surface-chrome | mix(bg, black 8%) | tab bar, sidebars |
| surface-raised | mix(bg, white 10%) | popovers, sheets, menus |
| fill / fill-strong | fg @ 8% / 14% | hover, wells / pressed, keycaps |
| border / separator | fg @ 16% / 10% | hairlines / list rows, dividers |
| text / text-muted / text-faint | fg / mix(fg 64%, bg) / mix(fg 42%, bg) | primary / secondary, inactive tabs / index, placeholders |
| accent / accent-fill / on-accent | ANSI 4 / accent @ 20% / black-or-white ≥ 4.5:1 | selection, focus / progress, drop zones / text on accent |
| danger / success / warning | ANSI 1 / 2 / 3 | destructive, disconnected / connected / connecting |

Vibrancy: `NSVisualEffectView(.underWindowBackground, .behindWindow)`; surface at 68 %
alpha, chrome at 45 %, active tab at 70 %.

**Metrics × spaciness (0.8–1.5):** tab bar 38, tab 28, form row 40 (52 with subtitle),
selector row 34, spacing scale sp-2…sp-24 (= 2,4,6,8,12,16,20,24 pt). Tab: radius 7,
padding 9 lead / 6 trail, 2 pt gap, fixed width 120–200 (default 176), pinned 92, flex
min 64, index Menlo 10.5 in text-faint, title SF 13 (500 when active), close/options
18×18 glyph 14, user colour bar 2 pt, progress = accent-fill + %, activity 6 pt dot,
dragging lifted 3 pt with an accent slot. Vertical bar: 200 pt column, 30 pt rows, "New
tab ⌘T" row, toolbar in the footer, colour bar on the leading edge. Overflow: fixed-width
tabs scroll with a "+N" menu of hidden tabs and the active tab scrolled into view; flex
tabs shrink to 64 then scroll.

**Type:** large title 26/600, title 20/600, headline 15/600, body 13/400 (13/500
emphasised), callout 12.5, caption 12, group header 11/600, mono UI Menlo 12.

**Screens** (ids from `Tabby Redesign.dc.html`; A-series from `Tabby Account.dc.html`):
main, mainLeft, mainVibrant, split (drop zones), splitMax (chip + Restore ⌘⇧↩), start,
welcome, selector (660 wide, 44 pt below the bar, ⌘E/⌘⇧P, footer hints, quick-connect
empty state), overlays (search bar with counter + Aa/.*/W, hover toolbar, link hint,
process-completed toast), paste (card over the pane), menus (native, colour submenu with
swatches, "Notify when done"), ssh (status chip Connecting/Connected/Disconnected/
Reconnecting n/5 with Reconnect; SFTP and Ports buttons only once phase 3 exists; host-key
sheet), sshAuth (deferred to phase 3: needs the library backend), appearance, colors,
hotkeys, profiles, editor (sheet, segmented General/Ports/Advanced/Colours/Login scripts),
window, terminal, ssh settings, config (YAML with scheme-coloured syntax + "Valid YAML"),
modals (rename, prompt + Remember, SSH password + Keychain, unlock vault → 2b, selector
empty state; safe-mode error not applicable), quake (bottom corners, 10 pt grab edge,
slide). Account: A1 signIn, A2 register, A3 recovery key, A4/A5 Settings › Account & sync
(signed out / in: avatar, status, what to sync, server, devices, security), A6 toolbar
avatar + popover (pending changes, devices, Sync now ⌘⇧S, settings, Sign out), A8 restore
progress, A9 sign-out choice. A7 approve-device: deferred.

Current state that the redesign replaces (see inventory): `ChromeTheme` has 16 differently
named tokens, 6 unused, RGB mixing; views read `AppServices.shared.theme.chrome`
directly (no environment); spaciness scales only the tab-bar height; Settings is a
separate `NSWindow`; no welcome tab, toasts, overflow menu, drop zones, vault or sync.

---

## Part 2a: redesign

Each milestone: tests first where logic is testable, `swift build`, `swift test`, commit,
push, CI, then an on-screen check with the zavora computer-use MCP against the design
(launch with `TABBYMAC_CONFIG_DIRECTORY=$HOME/tabbymac-test`). Findings get their own
commits. New checklist section **M6** in `docs/MANUAL-CHECKS.md` lists the on-screen items
per milestone.

### 2a.0 Design spec in the repo
Write `tabby-macos/docs/superpowers/specs/2026-10-22-phase-2-design.md` (the design
reference above plus the 2b protocol below, as prose, with the screen ids so a later
session can find them in the zip) so the plan survives this session. Add
`docs/DESIGN-TOKENS.md` with the token/metric tables. Add `Tabby Design Canvas.zip` to
`.gitignore`. Commit.

### 2a.1 Design system (TabbyCore + TabbyApp)
- `TabbyCore/ColorSchemes/RGBColor.swift`: add OKLab conversion and `mixOKLab(_:_:)`;
  keep `mix` for existing callers. Test: known pairs (black/white 50 % ≈ #777 in OKLab,
  not #808080) and round-trip.
- `TabbyCore/ColorSchemes/ChromeTheme.swift`: regenerate the token set to the table above
  (rename: `surface`, `surfaceChrome`, `surfaceRaised`, `fill`, `fillStrong`, `border`,
  `separator`, `text`, `textMuted`, `textFaint`, `accent`, `accentFill`, `onAccent`,
  `danger`, `success`, `warning`), with `vibrancy` alphas. Keep the contrast floor for
  `text`/`textMuted`. Update `RecoveryAndSchemeTests.testChromeTheme`.
- New `TabbyCore/ColorSchemes/ChromeMetrics.swift`: `struct ChromeMetrics(spaciness:)`
  with `tabBar`, `tab`, `formRow`, `formRowTall`, `selectorRow`, `space(_:)`. Test: 0.8 /
  1.0 / 1.5 give 30.4 / 38 / 57 for the bar.
- `TabbyApp/App/ThemeManager.swift`: expose `metrics`; `TabbyApp/Views/Theme/
  ChromeEnvironment.swift`: `EnvironmentKey`s `\.chrome`, `\.metrics`, and
  `View.chromeEnvironment()` applied at every `NSHostingView` root. Replace direct
  `AppServices.shared.theme.chrome` reads in SwiftUI views with `@Environment`.
- New `TabbyApp/Views/Components/`: `PushButton` (24/28 pt, radius 6, default/secondary/
  destructive), `IconButton` (28×28, 15 pt symbol, hover/pressed/active), `Keycap`,
  `GroupHeader`, `StatusDot`, `ToastView` (used in 2a.5). SF Symbol names from the icon
  table (plus, rectangle.stack, terminal, gearshape, gift, arrow.up.arrow.down, ellipsis,
  xmark, pin.fill, magnifyingglass, textformat, asterisk, textformat.abc,
  wrench.and.screwdriver, server.rack, folder, point.3.connected.trianglepath.dotted, key,
  lock, doc.on.clipboard, arrow.clockwise, rectangle.split.2x1,
  arrow.up.left.and.arrow.down.right, keyboard, paintpalette, paintbrush, macwindow,
  curlybraces, bolt, checkmark.circle.fill).

### 2a.2 Tab bar and window chrome
Files: `Views/TabBarView.swift`, `Window/MainWindowController.swift`, `Model/TabModel.swift`.
- Tab geometry per the metrics; hover shows ⋯ (opens `TabContextMenu`) and ×; pinned tabs
  92 pt leading; colour bar 2 pt (leading edge when vertical); progress fill; activity dot.
- Overflow: fixed-width tabs in a horizontal `ScrollView` that scrolls the active tab into
  view (`ScrollViewReader`), with a "+N" `Menu` of the tabs outside the visible range
  (measure with `GeometryReader`/`onGeometryChange`); flex tabs shrink to 64 then scroll.
  Model-level test: `TabStripLayout` (pure function: available width, tab count, flex, →
  widths + hidden count) in TabbyApp, unit-tested without a window.
- Drag reorder: lifted 3 pt, accent slot at the drop index (keep `.draggable` /
  `.dropDestination`, add the slot indicator); Esc cancels.
- Vertical bar: 200 pt column, 30 pt rows, "New tab ⌘T" row, footer toolbar.
- Vibrancy: switch to `.underWindowBackground` + `.behindWindow` and the token alphas.
- Keep `WindowSmokeTests` passing: the bar is still `NSHostingView<TabBarView>`,
  `WindowDragArea.DragView` keeps its minimum 24 pt; adjust the ≤24.5 assertion if the
  layout changes it deliberately.

### 2a.3 Content tabs: Settings as a tab, Welcome, Start page
- `Model/TabModel.swift`: a tab's content becomes an enum: `.terminal(SplitLayout)` or
  `.view(ContentTabKind)` with `ContentTabKind` = `.settings(section)`, `.welcome`.
  `WindowModel` gains `openSettings(section:)` (focus the existing settings tab if one is
  open, as Tabby's `settings-tab` does) and `openWelcome()`. Recovery token types
  `app:settings` and `app:welcome` (Tabby's ids) in `TabbyCore/Recovery`.
- `MainWindowController`: the content area hosts an `NSHostingView` for `.view` tabs;
  `SettingsWindowController` goes away. `⌘,` and the toolbar gear open the tab.
  `DockController.level` no longer touches a Settings window.
- Tests: `TabManagementTests` gains "settings tab is a singleton and is skipped by
  close-others busy check"; `DockingTests.testSettingsFloatsWithTheDockedWindow` and
  `WindowSmokeTests.testSettingsWindowKeepsItsSize` are replaced by "settings tab opens and
  is restored by recovery".
- Welcome tab: `Views/WelcomeView.swift` (language picker is a stub listing English only
  until localization in phase 5; appearance System/Dark/Light; analytics toggle stored as
  `enableAnalytics`; global hotkey toggle writes `hotkeys.toggle-window`; "Close and never
  show again" sets `enableWelcomeTab: false`). Shown on first launch when
  `enableWelcomeTab` is true and no recovery exists.
- Start page: restyle to the design (logo, three rows with ↩ focus, recents with ⌘1–⌘3,
  footer GitHub / Report a problem / version).

### 2a.4 Settings pages and the profile editor
Files: `Settings/*.swift` (new `SettingsTabView.swift` replaces the window controller's
root view; `ConfigBinding` is reused as is).
- Shell: 220 pt sidebar with the three groups from the canvas (Application, Appearance,
  Color scheme, Terminal, Window | Profiles & connections, SSH, Hotkeys, Vault | Plugins,
  Account & sync, Config file). The Vault row appears in 2b (synced secrets list), the
  Account & sync row shows a "coming in 2b" placeholder, and the Plugins row is dropped
  (no plugins in TabbyMac). Search field filters rows by label.
  Content is `Form(.grouped)` at most 760 pt wide, rows 40/52 pt × spaciness.
- Pages per the canvas forms: Appearance (theme segment, font, size, line height,
  ligatures, cursor, tabs group; the "interface follows colour scheme" and "accent
  source" rows are left out), Window (frame,
  tab location segment, spaciness slider, vibrancy + material, opacity, dock group with the
  global hotkey keycap), Terminal, SSH (agent, keep-alive, host-key warning, known hosts
  path, import toggle), Color scheme (dark/light mode cards with a live mini terminal,
  filterable grid of swatch tiles, custom editor with 4 wells + 16 ANSI), Hotkeys (grouped
  by area, keycaps with ×, capture popover with conflict warning and "Add second chord",
  Restore defaults), Profiles (outline list with group chevrons and counts, type badge,
  default and hidden markers, bottom bar + − Duplicate Hide New group, ↩ opens the editor,
  "Default profile for new tabs" popup), Config file (`NSTextView` with scheme-coloured
  YAML, line numbers, "Valid YAML" / error indicator, Show in Finder, Save ⌘S).
- Profile editor sheet: common block (name, group popup, icon & colour picker with
  swatches, "When session ends" segment) above a segmented General / Ports / Advanced /
  Colours / Login scripts; SSH General adds the password row ("Saved in Keychain" with
  Change… / Forget) and jump-host popup; "Test connection" deferred to phase 3.
- Only config keys Tabby already has; new UI-only toggles that have no Tabby key
  (accent source, close-button mode) get keys under `appearance.` documented in
  `defaults.yaml`.

### 2a.5 Selector, search, prompts, SSH chip, toasts, menus
- `Views/SelectorPanel.swift`: 660 wide, 44 pt below the bar, accent-selected row, 11 pt
  group headers, footer hints, empty state with quick-connect. Same panel for ⌘E/⌘⇧P.
- `Views/SearchBarView.swift`: counter "n / m", Aa / .* / W toggles, ↑ ↓ ×.
- Prompts: paste warning becomes a SwiftUI card sheet (`NSWindow.beginSheet` with an
  `NSHostingController`, still `attachedSheet`), host-key dialog likewise (keep the
  fingerprint in a selectable text field: update `PromptTests`), rename and generic
  prompt with Remember. Close confirmations stay `NSAlert` (TabManagementTests rely on
  sheets only).
- SSH status chip: SwiftUI overlay on pane hover with the four states and Reconnect;
  tab icon tinted by state. Needs `TerminalPane` to expose a connection state
  (`connecting/connected/disconnected/reconnecting(n, of)`); SSHSession already knows
  auth success via the LocalCommand hook.
- Toasts: `App/ToastCenter.swift` (`@Observable`, queue with auto-dismiss) and a
  bottom-right overlay in `WindowRootView`; "Process completed" toast when the tab is not
  active or the app is inactive (replaces the always-blocked system notification path on
  the test Mac; keep `UNUserNotificationCenter` as well when it is allowed). Visual bell:
  150 ms flash of the pane.
- Context menus: colour submenu with swatches, "Notify when done" check, Split submenu.

### 2a.6 Splits and quake polish
- `Split/SplitTreeView.swift`: 1 pt dividers with a 6 pt hit area and an accent grip on
  hover; focused pane 1.5 pt accent inset and optional label; maximised pane chip with a
  minimap and "Restore ⌘⇧↩".
- Drop zones: dragging a tab header over a pane shows four 36 pt targets; dropping calls
  `WindowModel.combine`/split with the chosen side. Model test: side → split direction
  mapping (`DropZoneTests` in the design's terminal mock-up is the spirit).
- Quake: bottom corners only, 10 pt grab edge, slide animation on toggle.

### 2a.7 Close-out
- `docs/MANUAL-CHECKS.md` M6 walked with computer use; findings table rows.
- `docs/ARCHITECTURE.md` (UI separation paragraph, roadmap), `CLAUDE.md` status.
- Memory `tabby-macos-status.md`.

## Part 2b: personal account and sync

### Protocol and crypto (my calls, versioned so they can change)
- **Keys.** `masterKey = scrypt(password, salt = 16 random bytes, N = 2^17, r = 8,
  p = 1, 32 bytes)` (`kdf: {name: "scrypt", n, r, p, salt}` stored per account and
  returned by the pre-login call; `KDF.Scrypt.deriveKey(from:salt:outputByteCount:rounds:
  blockSize:parallelism:)` in `_CryptoExtras`, verified in swift-crypto 3.15.1). `authKey = HKDF(masterKey, info "tabby-auth")`,
  `wrapKey = HKDF(masterKey, info "tabby-wrap")`. `encKey` = 32 random bytes made at
  sign-up; stored on the server as `wrappedByPassword = AES-GCM(wrapKey, encKey)` and
  `wrappedByRecovery = AES-GCM(recoveryKey, encKey)`. Recovery key = 32 random bytes shown
  as 8 groups of 4 base32 chars (A3); `recoveryAuthKey = HKDF(recoveryKey,
  "tabby-recovery-auth")` is stored hashed on the server so the key can also sign in, and
  the key itself is kept in the vault as a secret of type `account:recovery-key` so A5
  "View…" can show it after the password is re-entered. Password change re-wraps; the
  vault is untouched. Server stores `SHA256(authKey ‖ serverSalt)` and the same for the
  recovery auth key; it never sees the password, the recovery key or `encKey`.
- **Snapshot** (`SyncSnapshot`, JSON): `{formatVersion, createdAt, deviceId, sections:
  {settings: {updatedAt, yaml}, profiles: {updatedAt, items: [Profile + modifiedAt],
  groups, deleted: [{id, at}]}, secrets: {updatedAt, items: [{type, key, value}]}
  (types `ssh:password`, `ssh:key-passphrase`, `file` as in Tabby's vault), keyFiles:
  {items: [{id: sha512, name, contents}]}, knownHosts: {updatedAt, text}}}`. Settings yaml
  = the user layer of `config.yaml` minus `account`, `appearance.dockScreen`, recovery
  state. Encrypted as `AES-256-GCM(encKey, nonce, snapshotJSON)`.
- **Merge** (`SyncMerger`, pure, unit-tested): profiles by id, newer `modifiedAt` wins,
  tombstones delete, both sides' unknown profiles are kept; secrets by `(type, key)` newer
  wins; settings and knownHosts: newer section wins. Local wins ties.
- **Scheduling** (`SyncEngine`): upload debounced 5 s after a config, Keychain or key
  change; download at launch, on `Sync now` (⌘⇧S, hotkey id `sync-now`), and every 60 s
  via `GET /v1/vault/head`. 409 on upload → download, merge, re-upload.
- **Private keys.** Key files named in user profiles' `privateKeys` plus ssh's default
  identities under `~/.ssh/` (the list ssh tries when a profile names none) are uploaded
  by content, keyed by the SHA-512 id `SSHSession.keyID` already computes, after a one-time
  per-file confirmation sheet (`account.approvedKeyFiles: [id]` records the answers; a
  declined file is not asked about again until it changes). On another Mac a file is
  written to `<configDir>/keys/<id>` (0600); a profile path becomes `vault://<id>` and a
  default identity is added to the generated `ssh_config` as an `IdentityFile`;
  `SSHSession` resolves `vault://` to that file (Tabby's `VaultFileProvider`). Passwords
  and passphrases are read from / written to the Keychain through the existing
  `PasswordStore` protocol (`ssh@host:port` / account = user); it gains `listItems()`
  (`SecItemCopyMatching` with `kSecReturnAttributes`, filtered to the `ssh@` and
  `ssh-private-key:` services) so `SnapshotBuilder` can enumerate what TabbyMac saved.

### HTTP API (`tabby-sync-server`, prefix `/v1`, TLS required by the client)
- `GET /account/kdf?email=` → `{kdf}` (pre-login)
- `POST /account` `{email, authKey, kdf, wrappedByPassword, wrappedByRecovery,
  device}` → `{token, account}`
- `POST /session` `{email, authKey, device: {name, model, os}}` → `{token, account,
  device}`; `DELETE /session`
- `GET /account`; `PATCH /account/password` `{authKey, newAuthKey, newKdf,
  newWrappedByPassword}`; `DELETE /account`
- `POST /session/recovery` `{email, recoveryAuthKey, device}` → `{token, account,
  wrappedByRecovery}`: the client unwraps `encKey` and must then call `PATCH
  /account/password` (the token is limited to that and `GET /vault` until it does);
  `PUT /account/recovery` `{recoveryAuthKey, wrappedByRecovery}` regenerates the key.
- Registration (`POST /account`) also sends `recoveryAuthKey`; the server stores its
  salted hash.
- `GET /vault` → `{revision, modifiedAt, deviceId, nonce, ciphertext}`; `PUT /vault`
  with `If-Match: <revision>` → `{revision}` or 409; `GET /vault/head`
- `GET /devices`; `DELETE /devices/{id}` (revokes its token)
- Bearer tokens: random 32 bytes, stored hashed, one per device. Rate limit `POST
  /session` and `POST /account` per IP.

### Packages and targets
- New target **`TabbySyncProtocol`** in `tabby-macos/Package.swift` (Foundation +
  `swift-crypto` pinned `"3.0.0"..<"4.0.0"`: 3.15.1 is tools-version 5.10, so it builds
  with the CI's Xcode 16.4; 5.x needs tools 6.2): DTOs, `SyncSnapshot`, `SyncMerger`,
  `VaultCrypto` (scrypt from `_CryptoExtras`, HKDF and AES-GCM from `Crypto`,
  recovery-key base32). Tests run on macOS and Linux CI. TabbyCore is not touched by it.
- New package **`tabby-sync-server/`** (tools-version 6.0, built with the `swift:6.2`
  Linux image in CI and with Xcode 27 locally; Hummingbird 2.28 needs tools 6.2, so the
  macOS 15 / Xcode 16.4 app job never builds it): Hummingbird 2 (`from: "2.5.0"`),
  `hummingbird-fluent` with `FluentSQLiteDriver` and `FluentPostgresDriver`, depends on
  `../tabby-macos` for `TabbySyncProtocol`. Models: `Account`, `Device`, `Vault`. `Tests/` use Hummingbird's
  test client with SQLite in memory. `Dockerfile` (static Linux build), `compose.yaml`
  (Postgres), `README.md` with deploy notes for the owner's host. CI job "Sync server
  (Linux)" in `.github/workflows/tabby-macos.yml`.
- App side (`TabbyApp`): `Account/AccountService.swift` (session, Keychain item service
  `tabbymac-account` holding token + encKey when "Keep me signed in"), `Account/
  SyncEngine.swift`, `Account/SnapshotBuilder.swift` (config ↔ snapshot, Keychain
  enumeration from profiles, key files), `Account/KeyFileStore.swift` (`vault://`),
  config keys `account: {email, deviceId, auto: true, parts: {profiles, secrets,
  knownHosts, settings}, approvedKeyFiles: []}` in `defaults.yaml`; the server URL is
  the constant `SyncServer.defaultURL = https://sync.dcstyle.info` in `AccountService`
  (overridable only by the `TABBYMAC_SYNC_URL` environment variable, for tests).

### 2b milestones
1. `TabbySyncProtocol`: crypto round-trips (wrong key fails, tamper fails, recovery
   unwrap), snapshot encode/decode, merger cases. Linux CI green.
2. Server: endpoints with tests (register → login → put vault → 409 on stale revision →
   head → device revoke → password change keeps the vault readable). Docker image builds.
3. Client core: `AccountService` + `SyncEngine` + `SnapshotBuilder` + `KeyFileStore`,
   unit-tested against a local server started by the test (`swift run` of the server
   package, SQLite) or an in-process `URLProtocol` stub for the pure client logic.
4. UI on the 2a components: A1 sign-in sheet (email, password, keep me signed in,
   "Forgot password?" → recovery-key sign-in then set a new password; no server field),
   A2/A3 register + recovery key (copy, save as file, print; checkbox gate), the key-file
   confirmation sheet, A4/A5 Settings › Account & sync without the Server group (A5 keeps
   account, status, what to sync, devices, security with Recovery key View… /
   Regenerate…, Change password…, Delete account…), A6 toolbar avatar with badge +
   popover, A8 restore progress, A9 sign-out (keep local copy / remove synced data from
   this Mac), toasts for sync results, Vault sidebar row with the Keychain-backed list of
   synced secrets (show / rename / remove).
5. End-to-end on this Mac: server in Docker, two app instances with different
   `TABBYMAC_CONFIG_DIRECTORY`s acting as two Macs; sign up on A, sign in on B, profile +
   password + key file appear on B and the SSH profile connects without a prompt. New
   checklist section **M7**. Docs: `docs/SYNC-PROTOCOL.md`, ARCHITECTURE, CLAUDE.md,
   memory.

## Out of scope (recorded so nobody builds them by accident)
Device approval (A7), passkey and GitHub sign-in, email verification / forgot-password
email, self-hosted or user-changeable server, Tabby's passphrase vault and whole-config
encryption, uploading hosts imported from `~/.ssh/config`, "Open tabs & layout" sync,
SFTP / transfers popover / Ports editor / inline keyboard-interactive panel (phase 3),
localization beyond English (phase 5), plugins page, "interface follows colour scheme"
off mode and system-accent source.

## Verification
- `swift build` and `swift test` in `tabby-macos/` (macOS) and `tabby-sync-server/`;
  CI green on the macOS and both Linux jobs after every push.
- Token test pins the OKLab derivation; metrics test pins spaciness; `TabStripLayout`,
  `SyncMerger`, `VaultCrypto` and server tests cover the logic without a screen.
- M6 (redesign) and M7 (account & sync) walked on screen with computer use, every item
  ticked or in the Findings table with a commit.
- Every commit author/committer `dcstylexf <dcstylexf@gmail.com>`; no work-account
  identifiers anywhere.
