# Phase 7: settings and profile editors — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tabby's profile groups, type and group defaults, profile editor fields, appearance and colour-scheme options, profile sidebar and dynamic hotkeys, in TabbyMac.

**Architecture:** Tree, defaults, blacklist, selector filters, connection modes, the hotkey catalog and the 256-colour palette are pure TabbyCore code (Linux-tested). The SwiftUI editors in TabbyApp bind to them; the engine settings go through `TerminalSettings` into `SwiftTermEngine`.

**Tech Stack:** Swift 5.9 language mode, SwiftUI + AppKit, SwiftTerm 1.20.0, XCTest.

**Spec:** `tabby-macos/docs/superpowers/specs/2026-10-25-phase-7-design.md`

## Global Constraints

- TabbyCore stays Foundation + Yams (Linux). AppKit only in TabbyTerminal/TabbyApp.
- SwiftTerm pinned at 1.20.0; check API names in `.build/checkouts/SwiftTerm`.
- Every UI string through `L()`; after adding strings run `scripts/l10n-extract.sh` and add Vietnamese to `tabbymac/vi-VN.po` (CatalogTests fail otherwise).
- Config keys exactly Tabby's: `groups[].{name,parentGroupId,icon,color,defaults}`, `profileDefaults.<type>`, `profileBlacklist`, `terminal.showRecentProfiles` (number), `terminal.showBuiltinProfiles`, `options.env`, `options.socksProxyHost/Port`, `options.httpProxyHost/Port`, `forwardedPorts[].description`, `terminal.background` (`theme`|`colorScheme`), `terminal.linePadding`, `terminal.fontWeight`, `terminal.paletteGenerate`, `terminal.paletteHarmonious`, `appearance.dockScreen`, `terminal.hideTabOptionsButton`, `showProfileTree`, `accessibility.animations`, `hotkeys.profile.<name>`, `hotkeys.profile-selectors.<type>`, `hotkeys.group-selectors.<groupId>`, `hotkeys.settings-tab.<page>`.
- Tabby's strings verbatim where the spec quotes them.
- TDD: each test watched failing first; `swift build` and `swift test` before each commit; Linux docker run after Core changes; commit trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; personal identity only.
- Tests never touch the real Keychain, server, `~/.ssh` or the real UserDefaults domain (use a suite name per test).

## Review Focus

1. Imported groups whose `parentGroupId` is missing or forms a cycle: the tree shows every group and profile once and never loops (Task 1 test `testCyclesAndMissingParentsStillShowEverything`).
2. Profile ids with dots: the hotkey name is the id with `.` → `-` everywhere (rows, dispatch, deletion) (Task 1 `testDeletingAProfileRemovesItsHotkey`, Task 8 `testProfileRowsUseTabbysHotkeyName`).
3. Defaults mode: a field cleared in the editor removes the key instead of writing `""`, so it doesn't override the inherited value (Task 3 `testClearedDefaultsFieldsAreRemoved`).
4. Imported Tabby values the editors don't offer (an unmapped Font Awesome icon, a colour name or hex not in the list, `hidden: true` together with the blacklist) round-trip unchanged (Task 3 `testUnknownIconAndColourRoundTrip`, Task 1 `testLegacyHiddenMovesToTheBlacklist`).
5. A type default and a group default both set: the profile's own value wins, then the group's, then the type's (Task 1 `testDefaultsPrecedence`).

---

### Task 1: Core — group tree, group deletion, blacklist, type defaults, selector filters

**Files:**
- Modify: `Sources/TabbyCore/Profiles/ProfileRegistry.swift`
- Create: `Sources/TabbyCore/Profiles/ProfileTree.swift`
- Test: `Tests/TabbyCoreTests/ProfileTreeTests.swift`

**Interfaces — Produces:**
- `public struct ProfileTreeNode: Identifiable { public let group: ProfileGroup?; public var children: [ProfileTreeNode]; public var profiles: [Profile]; public var id: String }` — `group == nil` is "Ungrouped" (id `""`); built-ins form a node with a synthetic group `ProfileGroup(id: "builtin:<group name>", name: <name>, editable: false)`.
- `ProfileRegistry.tree(_ profiles: [Profile]) -> [ProfileTreeNode]` — roots sorted by name, user groups before built-in ones, children nested by `parentGroupId`; missing parent or cycle → treated as root.
- `ProfileRegistry.descendants(of groupId: String) -> Set<String>`; `validParents(for groupId: String) -> [ProfileGroup]` (excludes self and descendants).
- `ProfileRegistry.delete(groupId:deleteProfiles:)` — also re-parents child groups to the deleted group's parent and removes `hotkeys.group-selectors.<id>`.
- `ProfileRegistry.delete(profileId:)` — also removes `hotkeys.profile.<hotkeyName>`.
- `Profile.hotkeyName: String` (id with `.` → `-`); `hotkeyId` becomes `"profile." + hotkeyName`.
- `ProfileRegistry.isHidden(_ p: Profile) -> Bool`; `setHidden(_ p: Profile, _ hidden: Bool)` (writes `profileBlacklist`); `migrateLegacyHidden()` (moves `hidden: true` into the blacklist, removes the flag), called from `AppServices` after load and after import.
- `allProfiles(includeBuiltin:includeHidden:)` — `includeHidden: true` now includes blacklisted profiles.
- `ProfileRegistry.typeDefaults(_ type: String) -> ConfigValue`; `setTypeDefaults(_ type: String, _ value: ConfigValue?)` (nil removes).
- `selectorEntries(query:type:groupId:)` — `type` keeps only that type; `groupId` keeps that group and its descendants (recent and built-in entries left out when either is set).

- [ ] **Step 1: Write the failing tests** in `ProfileTreeTests` (Linux-safe, `ConfigStore` built in memory as other Core tests do):
  - `testGroupsNestUnderTheirParent`: groups A, B(parent A), profiles p1∈A, p2∈B, p3 ungrouped → roots `["A", "Ungrouped"]`, `A.children.map(\.group?.name) == ["B"]`, `A.profiles == [p1]`, `B.profiles == [p2]`.
  - `testCyclesAndMissingParentsStillShowEverything`: A(parent B), B(parent A), C(parent "gone") → every group appears exactly once, no infinite loop.
  - `testValidParentsExcludeSelfAndDescendants`: A > B > C, D → `validParents(for: "A") == [D]`.
  - `testDeletingAGroupReparentsChildrenAndDropsItsHotkey`: A > B, `hotkeys.group-selectors.A` set → after `delete(groupId: "A")`, B has no parent and the hotkey key is gone; profiles of A have no group (or are deleted with `deleteProfiles: true`).
  - `testDeletingAProfileRemovesItsHotkey`: profile id `ssh:custom:a.b:1`, `hotkeys.profile.ssh:custom:a-b:1` set → removed.
  - `testHideWritesTheBlacklist` and `testLegacyHiddenMovesToTheBlacklist` (built-in `local:default` hideable; `hidden: true` → blacklist, flag removed; `allProfiles(includeHidden: false)` excludes, `true` includes).
  - `testDefaultsPrecedence`: `profileDefaults.ssh.port = 2200`, group G `defaults.ssh.port = 2222`, profile in G without port → `resolved(p).options.port == 2222`; with `port: 22` → 22; outside G → 2200.
  - `testSelectorFiltersByTypeAndGroup`.
- [ ] **Step 2:** `swift test --filter ProfileTreeTests` → fails to compile (missing API).
- [ ] **Step 3:** Implement the interfaces above.
- [ ] **Step 4:** `swift test --filter ProfileTreeTests` → pass; full `swift test`; Linux docker run.
- [ ] **Step 5:** Commit `tabby-macos: profile tree, group deletion, blacklist and type defaults (7.1)`.

### Task 2: Profiles page — tree, group editor, defaults, advanced, hide

**Files:**
- Modify: `Sources/TabbyApp/Settings/ProfilesSettingsView.swift` (page body, `GroupRow`, `ProfileListRow`, menu)
- Create: `Sources/TabbyApp/Settings/ProfileGroupEditor.swift`
- Create: `Sources/TabbyApp/Settings/ProfileIconPicker.swift` (shared with Task 3)
- Test: `Tests/TabbyAppTests/ProfilesPageTests.swift`

**Interfaces — Consumes:** Task 1. **Produces:**
- `struct ProfileGroupEditorSheet: View` init `(group: ProfileGroup, isNew: Bool, done: (ProfileGroup?) -> Void, editDefaults: (ProfileGroup, String) -> Void)`.
- `enum ProfileGroupActions { @MainActor static func delete(_ g: ProfileGroup, registry: ProfileRegistry, ask: (String, [String]) async -> Int) async }` — first question `Delete "{name}"?` buttons `[Delete, Keep]`; when it has profiles, `Delete the group's profiles?` buttons `[Move to "Ungrouped", Delete]`. The `ask` closure is injectable for tests; the default shows `Prompts`.
- `struct ProfileIconPicker: View` init `(icon: Binding<String?>)` — a button showing the symbol that opens a popover with a search field and a grid of `ProfileIcons.catalog`.
- `ProfileIcons.catalog: [(fa: String, symbol: String)]` (~120 Font Awesome names → SF Symbols, in `TabBarView.swift`'s `ProfileIcons`), `symbol(for:)` reads it, unknown → `"questionmark.square.dashed"` ★ instead of terminal.
- Collapse state: `UserDefaults` key `profilesPage.collapsedGroups` (array of group ids; `""` for Ungrouped).

- [ ] **Step 1: Write the failing tests** (`ProfilesPageTests`, `TestApp.boot()`):
  - `testGroupDeletionAsksTwiceWithTabbysWords`: injected `ask` records messages/buttons; answering `0` then `0` keeps the profiles ungrouped; `0` then `1` deletes them; `1` first keeps everything.
  - `testHideAndShowUseTheBlacklist`: the page's hide action on `local:default` → `profileBlacklist == ["local:default"]`.
  - `testAdvancedRowsShowOnlyWithCustomProfiles`: helper `ProfilesSettingsView.showsAdvanced(registry:)` false with no user profiles, true with one.
  - `testIconCatalogMapsTabbyNames`: `ProfileIcons.symbol(for: "fas fa-server") == "server.rack"`, `"far fa-folder" == "folder"`, unknown `"fas fa-dragon"` → `"questionmark.square.dashed"`; every catalog symbol exists (`NSImage(systemSymbolName:)` non-nil).
- [ ] **Step 2:** run → compile failures.
- [ ] **Step 3:** Implement: the page renders `registry.tree(...)` recursively (indent 16 pt per depth, chevron, group icon/colour, count; pencil and trash on hover for editable groups); "New ▸ New profile group" opens the group editor with icon `far fa-folder`; the group editor (Name, Parent group picker from `validParents`, `ProfileIconPicker`, colour well + named colours, the "Default profile group settings" list with reset buttons per `ProfileTypes.creatable`); a section "Default profile settings" listing types with reset (asks `Restore settings to defaults ?` Delete/Keep); Advanced rows "Show recent profiles in selector" (stepper/number field, 0…, default 3) and "Show built-in profiles in selector" (toggle), shown when `showsAdvanced`; Hide/Show via `registry.setHidden`, eye-slash on hidden rows, "Show hidden" includes the blacklist.
- [ ] **Step 4:** tests pass; `swift test`; snapshot `DesignSnapshotTests` en/de/vi still pass (update snapshot expectations if they compare structure); add strings + vi.
- [ ] **Step 5:** Commit `tabby-macos: profile groups, defaults and hiding on the Profiles page (7.2)`.

### Task 3: Profile editor — modes and common fields

**Files:**
- Modify: `Sources/TabbyApp/Settings/ProfilesSettingsView.swift` (`EditableProfile`, `ProfileEditorSheet`, `ColourSwatches`)
- Test: `Tests/TabbyAppTests/ProfileEditorModeTests.swift`

**Interfaces — Consumes:** Tasks 1–2. **Produces:**
- `enum ProfileEditorMode: Equatable { case profile; case typeDefaults(String); case groupDefaults(groupId: String, type: String) }`; `EditableProfile` gains `mode: ProfileEditorMode` (default `.profile`).
- `ProfileEditorSheet.finalized(_ p: Profile, mode:) -> Profile` strips `""` strings and empty arrays from `options` in defaults modes.
- `static func defaultsValue(from p: Profile) -> ConfigValue` (what a defaults editor writes: `options` plus non-default common keys) and `static func profile(fromDefaults: ConfigValue, type: String) -> Profile`.
- `static func sessionEndChoices(for type: String) -> [SessionEndBehavior]` — `.reconnect` only for `ssh`, `telnet`, `serial`.
- `static func pages(for type: String) -> [Page]` — `split-layout` → `[]` (only the common fields).
- `TabColors.named: [(name: String, value: String)]` = Tabby's TAB_COLORS (Blue `#0275d8`, Green `#5cb85c`, Orange `#f0ad4e`, Purple `#613d7c`, Red `#d9534f`, Yellow `#ffd500`).

- [ ] **Step 1: Write the failing tests:**
  - `testClearedDefaultsFieldsAreRemoved`: a type-defaults profile with `options.port = ""`, `options.user = "root"` → `defaultsValue` has `user` and no `port`.
  - `testDefaultsModeTitleAndHiddenFields`: `ProfileEditorSheet.title(for: .typeDefaults("ssh"))` == `"Defaults for SSH"`; `showsIdentityFields(.typeDefaults("ssh")) == false`.
  - `testReconnectOnlyForConnections`: `sessionEndChoices(for: "local")` lacks `.reconnect`; `"ssh"` has it.
  - `testSplitLayoutShowsOnlyCommonFields`: `pages(for: "split-layout") == []`.
  - `testUnknownIconAndColourRoundTrip`: profile `icon: "fas fa-dragon"`, `color: "teal"` → through the editor's `finalized` unchanged.
- [ ] **Step 2:** run → fail.
- [ ] **Step 3:** Implement; the page's defaults rows (Task 2) open the sheet with `.typeDefaults` / `.groupDefaults` and save through `setTypeDefaults` / group `defaults[type]`. Colour row: `ColorPicker` (writes `#rrggbb`) + the named swatches + "No color"; a colour not in the list shows as a custom swatch.
- [ ] **Step 4:** tests pass; full suite; strings + vi.
- [ ] **Step 5:** Commit `tabby-macos: profile editor modes, icons and colours (7.3)`.

### Task 4: Local and SSH editor fields

**Files:**
- Create: `Sources/TabbyCore/Profiles/SSHConnectionMode.swift`
- Create: `Sources/TabbyApp/Settings/EnvironmentEditor.swift`
- Modify: `Sources/TabbyApp/Settings/ProfilesSettingsView.swift` (`localGeneral`, `sshGeneral`, `PortForwardsEditor`)
- Test: `Tests/TabbyCoreTests/SSHConnectionModeTests.swift`, `Tests/TabbyAppTests/ProfileEditorFieldsTests.swift`

**Interfaces — Produces:**
- `public enum SSHConnectionMode: String, CaseIterable { case direct, proxyCommand, jumpHost, socksProxy, httpProxy; public init(options: ConfigValue); public func apply(to options: inout ConfigValue) }` — `init` mirrors Tabby (`proxyCommand` set → proxyCommand; `jumpHost` → jumpHost; `socksProxyHost` → socksProxy; `httpProxyHost` → httpProxy; else direct); `apply` clears the other modes' keys (`proxyCommand`, `jumpHost`, `socksProxyHost/Port`, `httpProxyHost/Port`).
- `struct EnvironmentEditor: View` init `(env: Binding<ConfigValue?>)` — rows name = value, trash, "Add", footer "Substitutions allowed." + "Example:" link "extend PATH" (adds `PATH` = `${PATH}:/usr/local/bin`); empty names are dropped on write.
- `enum CommandLineField { static func join(command: String, args: [String]) -> String; static func split(_ line: String) -> (command: String, args: [String]) }` using `ShellWords` (TabbyCLIKit).

- [ ] **Step 1: Write the failing tests:**
  - Core `testModeFromOptions` (each case) and `testApplyClearsTheOtherModes`.
  - App `testEnvironmentRowsWriteTheEnv` (add, rename, delete → `options.env`), `testExtendPathExample`, `testCommandLineRoundTrip` (`split("/bin/zsh -l -c 'echo hi'") == ("/bin/zsh", ["-l", "-c", "echo hi"])`, join back), `testPortForwardDescriptionIsWritten`.
- [ ] **Step 2:** run → fail.
- [ ] **Step 3:** Implement: local page gets the one-line command field over Command/Arguments, a folder button on Working directory (`NSOpenPanel` folders), the Environment group; SSH page gets the Connection menu with Tabby's labels and descriptions and the per-mode fields (SOCKS/HTTP host + port), the Username placeholder `L("Your Mac user name ({name})")`; port forwards get a Description column.
- [ ] **Step 4:** tests pass; full suite; Linux docker; strings + vi.
- [ ] **Step 5:** Commit `tabby-macos: environment, command line and SSH connection modes in the editor (7.4)`.

### Task 5: Appearance and colour scheme

**Files:**
- Modify: `Sources/TabbyTerminal/TerminalSettings.swift`, `Sources/TabbyTerminal/SwiftTermEngine.swift`, `Sources/TabbyApp/Settings/SettingsView.swift` (Appearance), `Sources/TabbyApp/Settings/ColorSchemeSettingsView.swift`
- Create: `Sources/TabbyCore/ColorSchemes/Palette256.swift`
- Modify: `Sources/TabbyCore/Terminal/TerminalText.swift` (HTML palette)
- Test: `Tests/TabbyCoreTests/Palette256Tests.swift`, `Tests/TabbyTerminalTests/EngineAppearanceTests.swift`, `Tests/TabbyAppTests/ColorSchemeEditingTests.swift`

**Interfaces — Produces:**
- `TerminalSettings.linePadding: Double`, `.paletteGenerate: Bool`, `.paletteHarmonious: Bool`.
- `SwiftTermEngine.lineSpacing(fontSize: Double, padding: Double) -> CGFloat` = `max(1, (fontSize + 2 * padding) / fontSize)`; engine sets `lineSpacing` and `terminal.options.ansi256PaletteStrategy` (`.xterm` / `.base16Lab` / `.base16LabHarmonious`), rebuilding the palette (re-install the 16 colours after changing the strategy).
- `public enum Palette256 { public static func generate(colors: [String], background: String, foreground: String, harmonious: Bool) -> [String] }` — port of Tabby's `generatePalette` (LAB lerp, 240 entries, keeps user colours beyond 16); `public static func xterm(_ index: Int) -> RGB` (the existing cube/grey ramp, moved here).
- `TerminalHTML.render(... palette: [CellColor])` uses the generated palette when `paletteGenerate`.
- `ColorSchemeStore` (existing custom-scheme storage in TabbyApp): `rename(_ name: String, to: String)`, `delete(_ name: String)`.

- [ ] **Step 1: Write the failing tests:**
  - `Palette256Tests.testMatchesTabbysGenerator`: for Tabby's default scheme colours, compare a handful of indices (16, 21, 196, 231, 232, 255) to values computed by running Tabby's `generatePalette` once (record them in the test; compute with `node -e` against `../tabby-terminal/src/generatePalette.ts` transpiled, or by hand from its formulas) — exact hex match.
  - `testHarmoniousKeepsLightOrder`: light scheme → index 16 equals the background with `harmonious` and the foreground without.
  - `EngineAppearanceTests.testLinePaddingSetsLineSpacing` (fontSize 14, padding 2 → 18/14), `testPaletteSettingPicksTheStrategy`.
  - `ColorSchemeEditingTests.testRenameAndDeleteCustomScheme` (config `terminal.customColorSchemes` updated; a profile using the deleted scheme falls back to none).
- [ ] **Step 2:** run → fail.
- [ ] **Step 3:** Implement; Appearance page: "Terminal background" picker (From theme / From color scheme), "Line padding" stepper (0–10), font weight picker 100–900, preview line, fonts list monospaced then others; Color scheme page: "Generate 256-color palette", "Harmonious palette" (only when generating), cursor accent and selection foreground wells in the scheme editor, "Custom" badge, Rename…, Delete… (asks first).
- [ ] **Step 4:** tests pass; full suite; Linux docker; snapshots en/de/vi; strings + vi.
- [ ] **Step 5:** Commit `tabby-macos: line padding, palettes, fonts and custom schemes (7.5)`.

### Task 6: Window and Application rows

**Files:**
- Modify: `Sources/TabbyApp/Settings/SettingsView.swift`, `Sources/TabbyApp/Views/TabBarView.swift` (options button), `Sources/TabbyApp/App/AppDelegate.swift` (`DockController.screen(for:)` unchanged), `Sources/TabbyApp/Window/MainWindowController.swift` (frame `full` → thin)
- Test: `Tests/TabbyAppTests/WindowSettingsTests.swift`

**Interfaces — Produces:** `DockScreens.choices() -> [(title: String, value: ConfigValue)]` ("Current screen" = `"current"` as Tabby, then each `NSScreen` by `localizedName`, value `NSScreenNumber`); `TabBarView` hides its "…" options button when `terminal.hideTabOptionsButton`.

- [ ] **Step 1: Failing tests:** `testDockScreenChoicesStartWithCurrent`, `testHideTabOptionsButton` (tab bar model/flag), `testFullFrameIsReadAsThin`, `testAnimationsRowWritesTheKey`.
- [ ] **Step 2:** run → fail. **Step 3:** implement rows: Window › Dock "Display on"; Window › Tabs "Show tab options button" (inverted binding); Application › "Enable animations". **Step 4:** pass; suite; strings + vi. **Step 5:** Commit `tabby-macos: Display on, tab options button, animations (7.6)`.

### Task 7: Profile sidebar

**Files:**
- Create: `Sources/TabbyApp/Views/ProfileTreeView.swift`
- Modify: `Sources/TabbyApp/Window/MainWindowController.swift` (root layout: sidebar column, grabber), `Sources/TabbyApp/Settings/SettingsView.swift` (Window › "Show profile sidebar" / "Displays a full tree of profiles in the sidebar.")
- Test: `Tests/TabbyAppTests/ProfileSidebarTests.swift`

**Interfaces — Consumes:** `ProfileRegistry.tree`, `isHidden`. **Produces:** `struct ProfileTreeView: View` init `(open: (Profile) -> Void)`; root view property `sidebarWidth` (UserDefaults `profileSidebar.width`, default 250, clamped 150…500); collapse state in `profileSidebar.collapsedGroups`.

- [ ] **Step 1: Failing tests:** `testSidebarShowsWhenTheSettingIsOn` (root lays out a sidebar of width 250 and moves content right), `testSidebarFilterAndHiddenProfiles` (helper `ProfileTreeView.visibleTree(filter:registry:)` excludes blacklisted and filters by name), `testDoubleClickOpensATab` (calls `open`).
- [ ] **Step 2:** fail. **Step 3:** implement (filter field "Filter", group rows with chevrons, profile rows with icon and a play button on hover, double-click opens; grabber resizes; in Hidden title bar frame the sidebar leaves 28 pt at the top for the window buttons and the tab bar's leading inset drops to its normal padding). **Step 4:** pass; suite; snapshot of the window with the sidebar; strings + vi. **Step 5:** Commit `tabby-macos: the profile sidebar (7.7)`.

### Task 8: Dynamic hotkeys

**Files:**
- Modify: `Sources/TabbyCore/Hotkeys/HotkeyCatalog.swift`, `Sources/TabbyApp/Settings/HotkeysSettingsView.swift`, `Sources/TabbyApp/Commands/Commands.swift`, `Sources/TabbyApp/Settings/SettingsView.swift` (`SettingsSection.tabbyId`)
- Test: `Tests/TabbyCoreTests/DynamicHotkeyTests.swift`, `Tests/TabbyAppTests/DynamicHotkeyDispatchTests.swift`

**Interfaces — Produces:**
- `HotkeyCatalog.Entry.arguments: [String: String]` (title = `L(key, arguments)`).
- `HotkeyCatalog.dynamicEntries(profiles: [Profile], types: [(id: String, name: String)], groups: [ProfileGroup], settingsPages: [(id: String, title: String)]) -> [Entry]` — ids `profile.<hotkeyName>` ("New tab: {profile}"), `profile-selectors.<type>` ("Show {type} profile selector"), `group-selectors.<id>` ("Show profile selector for group {name}"), `settings-tab.<id>` ("Open settings tab: {tab}"); group `Lkey("Profiles")` for the first three, `Lkey("Application")` for the last.
- `SettingsSection.tabbyId: String?` — Tabby ids: appearance `terminal-appearance`, colorScheme `terminal-color-scheme`, terminal `terminal`, window `window`, profiles `profiles`, ssh `ssh`, hotkeys `hotkeys`, vault `vault`, account `config-sync`; ★ TabbyMac-only pages `application`, `config-file`.
- Dispatch in `Commands.swift`: `profile-selectors.<type>` → `showProfileSelector(type:)`; `group-selectors.<id>` → `showProfileSelector(groupId:)`; `settings-tab.<id>` → open Settings on that section.

- [ ] **Step 1: Failing tests:** Core `testDynamicEntriesUseTabbysIdsAndWords` (a profile id with dots → `profile.local:custom:a-b:1`, title "New tab: A"), `testProfileRowsUseTabbysHotkeyName`; App `testTypeSelectorHotkeyFiltersByType`, `testGroupSelectorHotkeyIncludesSubgroups`, `testSettingsTabHotkeyOpensThePage`, `testHotkeysPageListsDynamicRows`.
- [ ] **Step 2:** fail. **Step 3:** implement; the page shows the dynamic entries under their groups after the static ones; the matcher already flattens nested maps. **Step 4:** pass; suite; Linux docker; strings + vi. **Step 5:** Commit `tabby-macos: hotkeys for profiles, types, groups and settings pages (7.8)`.

### Task 9: Close-out

- [ ] Docs: `docs/ARCHITECTURE.md` (mapping table rows, roadmap 7 done, next 8), `README.md`, `CLAUDE.md` status, `docs/DESIGN-TOKENS.md` (group tree indent, sidebar).
- [ ] `docs/MANUAL-CHECKS.md` **M12**: group editor (rename, parent, icon, colour, defaults, delete both ways); type defaults reach a new tab; hide/show a built-in; advanced rows change the selector; editor defaults mode; env var reaches the shell (`echo $FOO`); SSH SOCKS/HTTP mode fields; port forward description; line padding and palette visible; custom scheme rename/delete; Display on; tab options button; animations; profile sidebar (filter, double-click, resize); dynamic hotkeys (bind "New tab: X", a type selector, a group selector, a settings page).
- [ ] Walk M12 with computer use (owner away: the Mac is free; posted events for drags); findings RED→GREEN.
- [ ] Final whole-branch review by a fresh reviewer (most capable model) over `git merge-base claude/phase-6-terminal-parity HEAD..HEAD`; fix Critical/Important RED→GREEN; minors to the ledger.
- [ ] Push (identity check), draft PR #6 based on `claude/phase-6-terminal-parity`, body with behaviour changes (palette default now xterm cube; Hide writes the blacklist; Reconnect hidden for local), mark ready once M12 is walked.
