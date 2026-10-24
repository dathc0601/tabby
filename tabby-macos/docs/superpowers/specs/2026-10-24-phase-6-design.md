# Phase 6 design: terminal and tab parity

## Context

Phases 1–5 are merged to `master`. A feature-gap audit of the Electron app in `../`
against TabbyMac (2026-10-24) found about forty built-ins still missing. The owner chose
the group a user meets every day in the terminal and the tab bar for this phase. The
settings and profile editors, macOS integration (Dock menu, Finder services, menu bar
icon, updates), the vault, ports of popular plugins and TabbyMac's strings in Tabby's
other 23 languages are later phases. SwiftTerm stays at 1.20.0: 2.0 is not released yet
(the newest tags, 1.99.0 and 1.99.1, are previews that need Swift 6.2).

Owner decisions (2026-10-24):
- Phase 6 is terminal and tab parity.
- The other languages are a phase of their own, later.
- The phase 5 on-screen checks (M10) are walked first.

Places where this port deliberately differs from Tabby are marked ★. The on-screen checks
are M11 in `docs/MANUAL-CHECKS.md`.

## Terminal text

### Export to file

Tabby: `tabby-electron/src/terminalContextMenu.ts`. The pane menu and the tab menu get
"Export to file" (command id `export-buffer` ★, Tabby has none; no default hotkey). A save
panel suggests `terminal.txt`, in the pane's directory when it is a local shell ★. The whole
buffer, scrollback included, is written as UTF-8 text, then the toast "Saved to {path}".
★ A write error shows a warning toast (Tabby lets it fall through). ★ The user's selection
stays as it was (Tabby's `selectAll` loses it).

### Copy with formatting

Tabby: `terminal.copyAsHTML`, default on, Settings › Terminal › Clipboard "Copy with
formatting". Every copy puts plain text on the clipboard, and also HTML when the setting is
on and the text is shorter than 32 768 characters. Copy means ⌘C, `ctrl-c` with a
selection, copy on select and the right-click copy mode.

The HTML is a `<pre>` with the scheme's background and foreground and the font family, and
one `<span>` per run of equal attributes: colour, background colour, bold, italic,
underline, strike-through, dim as opacity 0.5, inverse swapping the two colours ★. Colours
come from the profile's colour scheme: the 16 scheme colours (bold text in bright colours
when `terminal.drawBoldTextInBrightColors` is on), the xterm 6×6×6 cube and grey ramp for
the rest ★, and true colours as they are. ★ SwiftTerm keeps its palette private, so
colours a program changes with OSC 4 are not seen. Text is HTML-escaped, wide characters
are written once, and trailing spaces are trimmed per line.

### Word separators

Tabby: `terminal.wordSeparator`, default `` ()[]{}'"`` (a space first), Settings ›
Terminal "Word separators" / "Double-click selection will stop at these characters". A
double-click selects the run around the clicked character that contains none of these
characters; a click on a separator selects that character alone. ★ A space always
separates. ★ A change applies at once (Tabby re-reads it on focus).

## Panes

### Rename pane and the pane label

Tabby: `CommonOptionsContextMenu` in `tabby-core/src/tabContextMenu.ts`. The pane menu of a
tab with two or more panes gets "Rename pane" and the check item "Show pane label"
(enabled only when the pane has a custom title). A new custom title turns the label on. The
label is the custom title, centred 6 pt below the pane's top, white 12 pt text on 70 %
black, one line with an ellipsis. It hides while another pane is maximized and while the
rearrange overlay shows. `customTitleVisible` is kept in the recovery token
(`tabCustomTitleVisible`). ★ A split tab's title stays TabbyMac's (its custom title, else
the focused pane's); Tabby joins all pane titles with " | ".

### Rearranging panes

Tabby: hotkey `rearrange-panes`, default the modifier-only chord ⌃⇧, active while held.
Each pane shows a 50 % black overlay with a label (an icon and the pane's title) that can be
dragged. Drop zones insert the pane: at the outer edges of the whole layout, between
siblings, and on the perpendicular edges of each pane. A pane dropped on the tab bar becomes
a tab of its own. There is no swap and no keyboard move, as in Tabby.

Modifier-only bindings fire when the pressed modifiers equal the binding and end when they
stop matching. ★ Only `rearrange-panes` uses them; other modifier-only bindings stay inert.

### Focus follows mouse

Tabby: `terminal.focusFollowsMouse`, Settings › Window › Panes "Focus follows mouse" /
"Moving the mouse over an inactive pane will cause it to activate". Moving the pointer over
a pane focuses it, except while a divider is dragged. ★ Applies at once (Tabby asks for a
restart).

### Broadcast to every tab

Tabby: `MultifocusService.focusAllTabs`, hotkey `focus-all-tabs` (⌘⌥⇧I). Input typed into
the current pane, and pastes ★, go to every pane of every tab in the window ★ (Tabby has
one window). Every pane shows the focus ring, a 5 pt red border runs around the window's
content, and a banner says "Broadcast mode. Click anywhere to cancel.". It ends on a left
click in a terminal, when the pane loses focus or the tab changes, and ★ when the command
runs again. The pane and tab menus get "Broadcast Input to All Tabs" ★ (TabbyMac's wording
beside its "Broadcast Input to All Panes"), checked while on.

## Directories and files

### OSC 1337 CurrentDir

Tabby: `tabby-terminal/src/middleware/oscProcessing.ts`. `ESC ] 1337 ; CurrentDir=<path>`
sets the pane's reported directory, as OSC 7 already does. ★ The value is everything after
the first `=` (Tabby cuts it at a second one). ★ `~` is expanded only for local panes
(Tabby expands it with the local home for SSH too). Other 1337 keys are ignored.

### Dropping files

Tabby: `tabby-electron/src/pathDrop.ts`. Files dropped from Finder on a pane focus it and
type each path in single quotes (`'` becomes `'\''`, control characters removed), followed
by a space, each wrapped in bracketed paste when the pane uses it. ★ Always shell quoting
(there is no cmd or PowerShell on macOS).

### New terminal and New with profile

Tabby: `tabby-local/src/tabContextMenu.ts`. The pane and tab menus get "New terminal" (a
new tab with the pane's profile when it is a local shell, else the default profile, in the
pane's current directory when the profile sets none) and "New with profile" ▸ (the local
profiles: custom ones sorted by "group / name", then the built-in ones; a new tab in the
profile's directory, else the pane's; a directory that does not exist is dropped). Both
always open a tab. ★ The tab menu acts on the focused pane too (Tabby's tab header loses the
directory).

### Save as profile

Tabby: `SaveAsProfileContextMenu` in `tabby-terminal/src/tabContextMenu.ts`. The pane and tab
menus get "Save as profile". It asks for a name ("New profile name", the profile's name
filled in) and saves a new profile with the pane's profile type, options plus `cwd` (the
pane's current directory), group, icon, colour, `disableDynamicTitle` and
`behaviorOnSessionEnd`, then the toast "Saved". ★ The confirm button says "Save".

## Links

Tabby: `tabby-linkifier`. `clickableLinks.modifier`: none (default), ⌥, Shift or ⌘;
Settings › Terminal "Require a key to click links" / "When enabled, links are only
clickable while holding this key". ★ The default follows Tabby, so a plain click opens a
link; TabbyMac needed ⌘ until now. A Tabby config's `ctrlKey` is read, but not offered.

What is a link: SwiftTerm's own detection (URLs with a scheme, paths starting with `/`,
`~/`, `./`, `../`, or `dir/file.ext`, OSC 8 hyperlinks), plus Tabby's `www.` and
`user@host` forms and bare IPv4 addresses (opened as `http://`). What a click does:
`ssh://` and `telnet://` open a quick-connect tab ★; other URLs open in their app; a path is
`~`-expanded, resolved against the pane's directory, stripped of a `:line:col` suffix, and
opened in its default app if it exists on this Mac. OSC 8 links are followed only for
`http:`, `https:` and `file:` without a host. ★ With ⌥ or Shift as the key, links are not
underlined on hover (SwiftTerm only draws that for ⌘). ★ A click never runs anything: a
program, script or app bundle is shown in Finder instead of opened.

## ZMODEM

Tabby: `tabby-terminal/src/features/zmodem.ts` with zmodem.js. TabbyMac implements the
protocol itself in TabbyCore (Foundation only, tested on Linux too): CRC-16 and CRC-32,
hex and binary headers, ZDLE escaping, a receiver and a sender, and a detector that spots
`**\x18B00` (the remote runs `sz`) and `**\x18B01` (the remote runs `rz`) in the output.

On detection the app asks "Accept a ZMODEM session?" / "If you have not requested it, it
could be a sign of malicious activity." / Accept / Reject. ★ The question names the tab that
asks and doesn't switch to it; after a refusal further requests are ignored for 2 s, then 4 s,
doubling up to a minute; more than 1 MiB of output while the question is up refuses the
session. Receiving: one save panel per
offered file (cancel skips the file), written with mode 0644. Sending: an open panel that
takes several files. Progress lines are written into the terminal in Tabby's style
(` ZMODEM `, ` Offered `, ` NN% `, ` Received `, ` Sent `, ` Canceled `, ` Rejected `,
` Error `, ` Complete `), and each file is a row in the transfers popover. Keys still go to
the remote; a lone Ctrl-C cancels. The shell prompt that `sz` leaves is held until
" Complete " is written. ★ The popover's × cancels the ZMODEM transfer (Tabby only closes
the file). ★ The status words are translated (Tabby leaves them English). There is no
setting: ZMODEM works in every session type. Over telnet, binary data relies on the server:
like Tabby, TabbyMac doesn't negotiate telnet's binary mode. ★ When sending, TabbyMac asks for
an acknowledgement every 64 KiB and keeps at most 256 KiB ahead of it (lrzsz's window), so a
big file never piles up in memory and cancelling takes effect at once.

## Small settings

- `terminal.sixel`, Settings › Terminal "Sixel graphics support (experimental)" / "Display
  images via Sixel escape sequences". ★ SwiftTerm 1.20 always draws sixel images, so the
  switch only changes whether the terminal tells programs it supports them.
- `terminal.searchRegexAlwaysEnabled` is not ported: nothing in Tabby reads it.

## Out of scope

Swapping panes or moving them with the keyboard (Tabby has neither); the pane toolbar;
turning sixel drawing off; hover underlines for ⌥/Shift link modes; ZMODEM resume; the
settings and profile editors, Dock menu, Finder services, menu bar icon, updater, vault,
plugin ports, other languages and SwiftTerm 2.0 (later phases); ⌘⌫ on destructive alerts
(phase 4 leftover).
