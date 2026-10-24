# Phase 7 design: settings and profile editors

## Context

Phases 1–6 are written; phase 6 waits for the owner's merge (PR #5). An audit of Electron
Tabby's settings pages and profile editor against TabbyMac (2026-10-25) found that the gap is
mostly in the editors: TabbyMac's core already resolves per-type and per-group profile
defaults, nested groups and a profile's environment, but there is no way to edit them. This
phase brings the editors to parity. macOS integration (menu-bar icon, updates, Finder
services, hide on focus loss), Tabby's vault, plugin features and the other languages are
later phases.

Owner instruction (2026-10-25): finish the M11 walk, then keep going through the next phases
without asking. Every choice below that Tabby leaves open, or where this port differs, is
marked ★ and goes to the ledger as a ruling.

The on-screen checks are M12 in `docs/MANUAL-CHECKS.md`.

## Profiles page

### Groups

Tabby: `tabby-settings/src/components/editProfileGroupModal.component.*`,
`profilesSettingsTab.component.ts`.

- **New profile group** opens the group editor for a new group (icon `far fa-folder`).
- A group row's pencil opens the **group editor**: Name, Parent group (any group that is not
  the group itself or one of its descendants, or "Ungrouped"), Icon, Color, and the list
  "Default profile group settings" / "These apply to all profiles of a given type in this
  group": one row per profile type, which opens the profile editor in group-defaults mode, and
  a reset button that removes that type's defaults. Save writes `groups[]`.
- A group row's trash asks "Delete "{name}"?" (Delete / Keep); when the group has profiles,
  then "Delete the group's profiles?" (Move to "Ungrouped" / Delete). Child groups move up to
  the deleted group's parent ★ (Tabby leaves them pointing at a missing parent). The group's
  `hotkeys.group-selectors.<id>` binding is removed, as Tabby does.
- Groups show as a tree: children indented under their parent, each group collapsible ★ the
  collapsed state is kept in the app's defaults (Tabby keeps it in localStorage).

### Default profile settings

"Default profile settings" / "These apply to all profiles of a given type" lists the profile
types; a row opens the profile editor in type-defaults mode (`profileDefaults.<type>`), its
reset button asks "Restore settings to defaults ?" (Delete / Keep) and clears them. These
already apply to new sessions (`ProfileRegistry.resolved()`).

### Hide and show

★ Hide and Show write Tabby's `profileBlacklist` (TabbyMac wrote its own `hidden` key and
could not hide built-in profiles). A hidden profile shows an eye-slash in the list and is left
out of selectors and menus; "Show hidden profiles" still lists them so they can be shown
again. A `hidden: true` written by earlier TabbyMac builds is moved into the blacklist when
the config loads.

### Advanced

- "Show recent profiles in selector" / "Set to 0 to disable recent profiles":
  `terminal.showRecentProfiles`, a number (Tabby's default 3).
- "Show built-in profiles in selector" / "If disabled, only custom profiles will show up in
  the profile selector": `terminal.showBuiltinProfiles`.
- Both rows show only when there are custom profiles, as in Tabby. The profile selector
  honours both.

## Profile editor

### Modes

The editor has three modes: a profile (as today), type defaults and group defaults. In the
defaults modes the title is "Defaults for {type}" ★ (Tabby keeps the profile header), and
the name, group, icon and colour fields are hidden; every other field edits the defaults.
Fields left empty are not written, so a type or group default only holds what was set.

### Common fields

- **Icon** ★ TabbyMac draws SF Symbols, mapped from Tabby's Font Awesome names. The mapping
  grows to about 120 names, and the picker becomes a searchable grid. A Font Awesome name
  without a mapping is kept as it is (it round-trips to Tabby) and shows as a generic symbol.
- **Color**: a colour well for any colour plus Tabby's named tab colours, written as Tabby
  writes them (`#rrggbb` or the name). A colour from an imported config that is not in the
  list still shows and is kept.
- **When the session ends**: "Reconnect" is offered only for connection types (SSH, telnet,
  serial), as in Tabby.
- **Split layouts** (`split-layout` profiles) show only the common fields. Before, they fell
  through to the local shell's page (a bug).

### Local shell

- **Environment**: rows of name = value with a trash button each, "Add", and the footer
  "Substitutions allowed." with the example link "extend PATH" (adds `PATH` =
  `${PATH}:/usr/local/bin` ★ Tabby's example is Windows-shaped). Written to `options.env`.
- **Working directory** gets a folder button (an open panel for folders).
- **Command line**: one line, split with shell quoting ★ Tabby's command-line editor has a
  one-line mode and a program + arguments mode; TabbyMac keeps the program field and an
  arguments list it already has, and adds the one-line field above them that fills both.

### SSH

- **Connection**: a menu with Direct, Proxy command ("Command's stdin/stdout is used instead
  of a network connection"), Jump host ("Connect to a different host first and use it as a
  proxy"), SOCKS proxy ("Connect through a proxy server") and HTTP proxy ("Using CONNECT
  method"). Each mode shows its own fields: proxy command; jump host; SOCKS host and port;
  HTTP host and port. Choosing a mode clears the other modes' options, as Tabby does.
- **Port forwards** get a description column (`forwardedPorts[].description`).
- **Username**: ★ an empty username keeps TabbyMac's fallback to the Mac user (OpenSSH's
  behaviour); Tabby asks for one. The field's placeholder says so.

## Other settings pages

### Appearance

- **Terminal background**: "From theme" / "From color scheme" (`terminal.background`).
- **Line padding** (`terminal.linePadding`, points): SwiftTerm's line spacing becomes
  (font size + 2 × padding) / font size, Tabby's formula.
- **Font weight**: 100–900 in steps of 100 (TabbyMac offered 300–700). A preview line shows
  the font, size and weight.
- **Fonts**: the picker lists monospaced fonts first and, below a divider, the others ★
  (Tabby lists every font).
- ★ `terminal.ligatures` and `terminal.fontWeightBold` are not ported: SwiftTerm 1.20 draws
  one glyph per cell and derives its bold face itself. The keys round-trip.

### Color scheme

- "Generate 256-color palette" (`terminal.paletteGenerate`) and "Harmonious palette"
  (`terminal.paletteHarmonious`, shown when generating): SwiftTerm's own
  `ansi256PaletteStrategy` (`.xterm`, `.base16Lab`, `.base16LabHarmonious`) matches Tabby's
  `generatePalette`. ★ Off now means the xterm cube, as in Tabby; TabbyMac drew the generated
  palette until now. Formatted copy uses the same palette.
- The scheme editor gets the cursor accent and selection foreground colours.
- Custom schemes (`terminal.customColorSchemes`) get a "Custom" badge, Rename and Delete
  (asking first).

### Window and Application

- **Display on** for the docked window: "Current screen" or one row per display
  (`appearance.dockScreen`, `NSScreenNumber`), as Tabby's picker.
- **Hide tab options button** (`terminal.hideTabOptionsButton`).
- **Show profile sidebar** (`showProfileTree`): a resizable sidebar at the window's leading
  edge with a filter field and the profile tree (groups collapsible, double-click or the play
  button opens a tab; hidden profiles left out). Its width is kept ★ in the app's defaults.
- **Window frame** ★ keeps TabbyMac's Native and Hidden title bar; Tabby's "Full" draws its
  own window buttons, which macOS already provides, and is read as Hidden title bar.
- **Enable animations** (`accessibility.animations`) on the Application page.

### Hotkeys

The hotkeys page lists, below the static commands:

- "New tab: {profile}" for every profile (`hotkeys.profile.<name>`, Tabby's
  `getProfileHotkeyName`);
- "Show {type} profile selector" for every type (`hotkeys.profile-selectors.<type>`), which
  opens the selector filtered to that type;
- "Show profile selector for group {name}" for every group (`hotkeys.group-selectors.<id>`),
  which opens the selector filtered to that group and its subgroups;
- "Open settings tab: {page}" for every settings page (`hotkeys.settings-tab.<page>`), which
  opens Settings on that page.

Deleting a profile or group removes its binding, as Tabby does.

## Out of scope

Menu-bar icon (`hideTray`), updates, Finder services, hiding the docked window on focus loss
(phase 8); the vault (phase 9); ligatures and a separate bold weight (SwiftTerm); Tabby's
config-sync page (replaced by TabbyMac's account); Windows- and Electron-only settings
(GPU, frontend, CSS, fluent background, ConPTY, identification, WinSCP, administrator,
parity mark/space).
