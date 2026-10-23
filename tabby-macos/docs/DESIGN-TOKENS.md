# Design tokens (phase 2 redesign)

Source: the Claude Design canvases of 2026-10-22 (`Tabby Boards` → tokens, tabs and
components boards; `Tabby Redesign` → type, spacing and icon tables). The chrome takes all
of its colours from the active terminal colour scheme, so every screen is the same set of
components under different schemes. Code: `TabbyCore/ColorSchemes/ChromeTheme.swift`
(colours), `TabbyCore/ColorSchemes/ChromeMetrics.swift` (sizes), environment keys in
`TabbyApp/Views/Theme/ChromeEnvironment.swift`.

## Colour tokens

Mixing is done in OKLab. `bg`/`fg` are the scheme background and foreground, ANSI n is
`scheme.colors[n]`.

| Token | Derived from | Used for |
|---|---|---|
| `surface` | bg | Window, terminal, active tab |
| `surfaceChrome` | mix(bg, black 8%) | Tab bar, sidebars |
| `surfaceRaised` | mix(bg, white 10%) | Popovers, sheets, menus |
| `fill` | fg @ 8% | Hover, control wells |
| `fillStrong` | fg @ 14% | Pressed, keycaps, buttons |
| `border` | fg @ 16% | Hairlines, outlines |
| `separator` | fg @ 10% | List rows, pane dividers |
| `text` | fg | Primary text |
| `textMuted` | mix(fg 64%, bg) | Secondary text, inactive tabs |
| `textFaint` | mix(fg 42%, bg) | Tab index, placeholders |
| `accent` | ANSI 4 (blue) | Selection, focus, default button |
| `accentFill` | accent @ 20% | Progress, drop zones, toggles on |
| `onAccent` | black or white, whichever contrasts more with accent | Text on accent |
| `danger` | ANSI 1 (red) | Destructive, disconnected |
| `success` | ANSI 2 (green) | Connected, completed |
| `warning` | ANSI 3 (yellow) | Connecting, host-key prompts |

`text` keeps the user's minimum-contrast setting against `surface`.

**Vibrancy:** `NSVisualEffectView` (`.underWindowBackground`, `.behindWindow`) under the
whole window; `surface` drops to 68% alpha, `surfaceChrome` to 45%, the active tab stays at
70%.

## Metrics

Everything that scales is multiplied by `appearance.spaciness` (0.8–1.5).

| Metric | 0.8 | 1.0 | 1.5 |
|---|---|---|---|
| Tab bar height | 30.4 | 38 | 57 |
| Tab height | 22.4 | 28 | 42 |
| Form row (one line) | 32 | 40 | 60 |
| Form row with subtitle | 41.6 | 52 | 78 |
| Selector row | 27.2 | 34 | 51 |

Spacing scale `sp-2 … sp-24` = 2, 4, 6, 8, 12, 16, 20, 24 pt × spaciness.

## Type

| Role | Font |
|---|---|
| Large title | SF Pro 26 / 600 |
| Title | SF Pro 20 / 600 |
| Headline | SF Pro 15 / 600 |
| Body | SF Pro 13 / 400 (500 emphasised) |
| Callout | SF Pro 12.5 / 400 |
| Caption | SF Pro 12 / 400 |
| Group header | SF Pro 11 / 600 |
| Terminal | Menlo 14, 18 pt line (user setting) |
| Mono UI | Menlo 12 |
| Tab index | Menlo 10.5 |

## Tab

| Part | Spec |
|---|---|
| Bar | 38 pt × spaciness, `surfaceChrome`, separator hairline below |
| Tab | 28 pt × spaciness, radius 7, padding 9 leading / 6 trailing, 2 pt gap |
| Width | fixed 120–200 pt (default 176); pinned 92 pt; flex tabs share the strip down to 64 pt |
| Index | Menlo 10.5, `textFaint` |
| Title | SF 13, 400 inactive / 500 active |
| Active | `surface` background, 0.5 pt `border` ring, 1 pt shadow |
| Hover | `fill` background, shows ⋯ (options) and × |
| Close / options | 18 × 18 pt, glyph 14 pt |
| User colour | 2 pt bar at the bottom (leading edge when vertical) |
| Activity | 6 pt dot |
| Progress | `accentFill` fill behind the tab plus a "42%" label |
| Dragging | lifted 3 pt with a large shadow; an accent slot opens at the drop index |
| Overflow (fixed) | strip scrolls, "+N" menu lists hidden tabs, active tab kept in view |
| Vertical bar | 200 pt column, 30 pt rows, "New tab ⌘T" row, toolbar in the footer |

## Components

| Component | Spec |
|---|---|
| Push button | 24 pt regular, 28 pt large, radius 6; default (accent), secondary (`fillStrong`), destructive (`danger`), disabled |
| Toolbar icon button | 28 × 28 pt, SF Symbol 15 pt; normal `textMuted`, hover `fill`, pressed `fillStrong`, active `accentFill` + `accent` |
| Keycap | `fillStrong` capsule, SF 11 / 500 |
| Connection chip | dot + address + state; Connecting… (warning), Connected (success), Disconnected (danger, Reconnect in accent), Reconnecting n/5 (warning). Address: SSH `user@host:port`, Serial `<device> · <baud>`, Telnet `host:port`. Buttons after a separator: SSH SFTP + Ports, Serial Baud rate, Telnet none; `textMuted` when connected, `textFaint` + disabled otherwise, `fillStrong` while their popover is open |
| Pane label | in a split, `n · title` at the pane's top-right (8 pt right, 6 pt top), 20 pt high, radius 5, `fill`, 11 pt `textMuted`; hidden while the chip shows |
| Popover | system popover chrome, 6 pt inset (baud rate, 320 pt) or 14–16 pt (transfers 380 pt, ports 420 pt); rows 26 pt, checked row `accent` checkmark + "In use" |
| Selector panel | 660 pt, 44 pt below the tab bar; search 52 pt; group headers 11 pt; rows 34 pt (selected: `accent` fill, "↩ open"); dimmed rows `textMuted`/`textFaint`; empty state icon + title + subtitle; footer hints + an optional trailing hint |
| Confirmation alert | `NSAlert`; a destructive confirm has no ↩ (Cancel answers esc); Quit is the default button |
| Toast | `surfaceRaised`, radius 10, icon + title + detail, bottom-right of the window |
| Visual bell | 150 ms flash of the pane |

## Icons (SF Symbols)

| Use | Symbol |
|---|---|
| New tab | `plus` |
| Profiles | `rectangle.stack` |
| New terminal | `terminal` |
| Settings | `gearshape` |
| Update | `gift` |
| Transfers | `arrow.up.arrow.down` |
| Tab options | `ellipsis` |
| Close | `xmark` |
| Pinned | `pin.fill` |
| Search | `magnifyingglass` |
| Match case / regex / whole word | `textformat` / `asterisk` / `textformat.abc` |
| Pane tools | `wrench.and.screwdriver` |
| SSH profile | `server.rack` |
| Serial profile, port | `cable.connector` |
| Telnet profile | `network` |
| Baud rate | `speedometer` |
| Free-input row ("Use …") | `pencil` |
| Template ("Serial connection") | `plus` |
| SFTP | `folder` |
| Ports | `point.3.connected.trianglepath.dotted` |
| Host key, vault | `key` |
| Auth prompt | `lock` |
| Paste | `doc.on.clipboard` |
| Reconnect | `arrow.clockwise` |
| Split | `rectangle.split.2x1` |
| Maximise | `arrow.up.left.and.arrow.down.right` |
| Hotkeys | `keyboard` |
| Colour scheme | `paintpalette` |
| Appearance | `paintbrush` |
| Window | `macwindow` |
| Config file | `curlybraces` |
| Quick connect | `bolt` |
| Completed | `checkmark.circle.fill` |
| Account | `person.crop.circle` |
| Sync | `arrow.triangle.2.circlepath` |
