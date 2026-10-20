# Claude Design prompt (phase 0)

Paste everything below the line into Claude Design, then attach screenshots of the current
Tabby app (main window dark and light, settings pages, profile selector, profile editor,
hotkeys page, an SSH session). The brief lists every screen the native app has, so the
designs map one-to-one onto the SwiftUI views in `Sources/TabbyApp/Views` and
`Sources/TabbyApp/Settings`.

---

# Redesign brief: Tabby for macOS (native Swift rewrite)

## What you are designing
I am rebuilding Tabby, a cross-platform terminal emulator and SSH client, as a **native macOS app in
Swift (SwiftUI + AppKit)**. The attached screenshots show the current Electron version. I want a
fresh, native-feeling design for every screen below, not a pixel copy. Keep Tabby's identity
(dense, developer-oriented, tab-centric, colour-scheme driven) but make it feel at home on macOS 14+.

## Product facts the design must respect
- The window is **frameless with a hidden title bar**: the traffic lights sit inside the tab bar
  row, inset about 14pt from the left and 11pt from the top. The tab bar is the drag region.
- Users can put the tab bar on the **top, bottom, left or right** edge. Design top as the primary,
  then show left (a 200pt vertical column) as a variant.
- **The UI chrome takes its colours from the active terminal colour scheme**: window background =
  scheme background, accent = scheme ANSI blue (colour 4), danger = ANSI red, success = ANSI green,
  warning = ANSI yellow, text = scheme foreground. Every screen must work in dark and light, and
  with arbitrary schemes (e.g. Dracula, Solarized Light, Gruvbox). Define the design with semantic
  tokens (surface, surface-raised, text, text-muted, accent, border, danger…) derived from those
  scheme colours plus a "spaciness" multiplier (0.8–1.5) that scales paddings and the tab bar height
  (base tab bar height is 38pt).
- Optional **vibrancy** (translucent blurred window background) and window opacity. Show one
  variant with vibrancy on.
- Terminal area is a monospace grid (default Menlo 14pt). Do not restyle terminal content; design
  the chrome around it.
- Target implementation: SwiftUI views plus AppKit for the window, tab bar and terminal. Prefer
  native controls (toggles, pickers, sidebar lists, sheets, popovers, HUD panels) and SF Symbols.
  Avoid web-only patterns (hover-only affordances must have a visible alternative, no custom
  scrollbars, no non-native form controls).
- Keyboard-first: every screen must show keyboard hints where Tabby has them (selector shows
  "↩ open" / "⌫ back", hotkey editor shows captured chords like ⌘⇧D).

## Screens to design (in priority order)

1. **Main window, tabs on top** (primary). Elements, left to right: traffic-light inset; tab strip
   where each tab shows an index number (1…9), optional profile icon, title, an optional thin colour
   bar (user-assigned tab colour), an activity dot, an in-tab progress bar (percentage detected from
   output), a pin indicator, a "tab options" (⋯) button and a close (×) button on hover; a "+"
   new-tab button; toolbar buttons on the right (Profiles & connections, New terminal, Settings, and
   an "update available" gift icon); a file-transfers dropdown that appears only when transfers are
   active. Show states: active tab, inactive, hovered, pinned, with colour bar, with progress,
   dragging to reorder, 12+ tabs overflowing (fixed width vs "flex tabs" that stretch).
2. **Split panes** inside one tab: nested horizontal/vertical splits with draggable dividers, a
   focused-pane indicator, optional pane labels, a "maximised pane" state, and the four drop zones
   (top/right/bottom/left) shown while dragging a tab into a pane.
3. **Start page** (shown when there are no tabs): logo, a list of actions (Profile selector, up to 3
   recent profiles), footer with GitHub / Report a problem / version.
4. **Welcome / first-run tab**: language picker, colour-scheme mode (System / Dark / Light),
   analytics toggle, global hotkey toggle (Ctrl-Space), "Close and never show again".
5. **Selector / command palette** (floating panel, ⌘E / ⌘⇧P): large search field, grouped results
   (Recent, user groups, Built-in, "Manage profiles", "Quick connect: user@host"), each row with
   icon, name, group path, optional colour; keyboard hints; empty state.
6. **Terminal search bar** (⌘F): query field, "n / m" counter, previous/next, toggles for case
   sensitivity, regex, whole word, close. Docked at the top-right of the terminal pane.
7. **Terminal overlays**: hover toolbar (wrench button, pin/unpin), multi-line paste warning dialog
   ("Paste multiple lines?" with preview, Paste / Cancel), visual bell flash, "process completed"
   toast, link hover state, tab/terminal context menus (Close, Close others/left/right, Split ↑→↓←,
   Rename, Duplicate, Pin, Colour submenu, Save layout as profile, Notify when done, Switch
   profile; Copy, Paste, Copy current path, Focus all panes).
8. **SSH tab chrome**: the small hover status chip with a connection dot and `user@host:port`,
   Reconnect / SFTP / Ports buttons; connecting / connected / disconnected / reconnecting states;
   the **host key verification** dialog (host, key type, SHA256 fingerprint, Accept / Reject);
   the **keyboard-interactive auth** panel (prompt + input, remember toggle); the **password prompt**
   with "Remember in Keychain".
9. **Settings** (opens as a tab, with a vertical section list on the left): Application,
   Appearance, Color scheme (picker with live preview swatches of all 16 colours, dark + light
   selection, custom scheme editor), Terminal, Window (frame, tabs location, spaciness, vibrancy,
   opacity, docking, quake hotkey), Hotkeys (filterable list, chord editor and capture dialog),
   Profiles & connections (tree of groups and profiles with new/duplicate/delete/hide, default
   profile), SSH, Config file (raw YAML editor). Design the shell plus at least Appearance, Color
   scheme, Hotkeys and Profiles in full; others can be lower fidelity.
10. **Profile editor sheet**: common fields (name, group, icon, colour, behaviour on session end:
    Auto / Keep / Reconnect / Close), then type-specific sections. Local: command, args, working
    directory, environment. SSH: General (host, port, username, auth method, password, private
    keys, jump host, proxy), Ports (forwarded ports list), Advanced (X11, agent forwarding,
    keep-alive), Colors, Login scripts.
11. **Small modals**: Rename tab, generic prompt (text/password with "Remember" checkbox),
    Unlock vault (passphrase + "remember for…"), Safe-mode error.
12. **Dock / "Quake" mode**: the window docked to the top edge of the screen at 50% height,
    always on top, no traffic lights, with a subtle grab edge.

## Deliverables
- A design system page: colour token table (showing how tokens derive from a terminal scheme, with
  three example schemes: Tabby Default dark, Tabby Default Light, and one vivid community scheme),
  type scale (UI font SF Pro, terminal font Menlo), spacing scale with the spaciness multiplier,
  icon set (SF Symbols names), tab and button component specs with all states.
- Every screen above in dark and light, at 1280×800 window size; plus the left-tabs variant and the
  vibrancy variant of screen 1.
- Component specs with sizes in points, so they can be implemented in SwiftUI/AppKit, and a short
  note per screen on which parts should be AppKit (tab bar, splits, terminal) vs SwiftUI.
- Keep text content realistic: shell prompts, `user@host`, real colour-scheme names.

## Attached
Screenshots of the current app: main window (dark), SSH session (light), settings pages, profile
selector, profile editor, hotkeys page. Use them for feature inventory, not as the visual target.
