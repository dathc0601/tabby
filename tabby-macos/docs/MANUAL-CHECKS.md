# Manual checks

What to try by hand after a build, and what should happen. Unit tests cover the models;
this list covers what only shows up on screen or needs a real shell, keychain or sshd.
Run it from the `.app` built by Xcode, not `swift run`, because notifications and the
bundle identifier only exist there. For a clean run set `TABBYMAC_CONFIG_DIRECTORY` to an
empty folder first.

Mark items `[x]` when they pass. Anything that fails gets a line under **Open findings** at
the bottom with the commit that fixed it.

## M0 Build and launch

- [x] `swift build` and `swift test` finish without errors or warnings in our code.
- [x] `cd Xcode && xcodegen generate` then `xcodebuild … -skipPackagePluginValidation build`
      succeeds; `TabbyMac.app/Contents/MacOS/tabby-askpass` exists and is executable.
- [x] The app shows Tabby's icon in Finder, the Dock and the ⌘-Tab switcher.
- [x] First launch on an empty config directory: one window, one tab with the login shell,
      `config.yaml` is created and contains only a version key.
- [x] Close the last tab: the start page appears with the profile selector and recents.
- [x] Quit and relaunch: the previously open tab comes back (recovery on by default).

M0 passed on 2026-10-22 (macOS 27.0.1, Xcode 27.1).

## M1 Local terminal

- [x] The shell starts in the home directory with `TERM=xterm-256color`, `COLORTERM=truecolor`.
- [x] `ls --color`, `vim`, `htop` or `top` render correctly; resizing the window reflows.
- [x] `printf '\e]0;Hello\a'` sets the tab title; `cd /tmp` then ⌘T opens the new tab in
      `/private/tmp` (OSC 7, or the foreground process cwd, which macOS reports resolved).
- [x] ⌘F opens the search bar: typing finds matches, the counter updates, ↩ / ↓ go to the
      next match and ⇧↩ / ↑ to the previous one, case / regex / whole-word toggles work,
      Esc closes.
- [x] ⌘+ / ⌘- / ⌘0 zoom the focused pane's font. After a split the zoomed pane keeps its
      size and the new pane starts at the configured size, like a new tab (zoom is per pane,
      as in Tabby).
- [x] Select text: copy on select (if enabled) puts it on the clipboard; ⌘C copies, ⌘V pastes,
      middle-click pastes, right-click follows the configured action (menu / paste / select).
- [x] Paste two lines: the "Paste multiple lines?" sheet shows the trimmed preview; Paste sends
      them as `\r`-separated input; Cancel sends nothing.
- [x] Run `printf '\e[?2004h'; cat -v` and paste a line: it shows as `^[[200~…^[[201~`.
      Plain `cat` shows no markers, because paste is only wrapped once the program turns
      bracketed paste on (as in Tabby). ^C, then `printf '\e[?2004l'`.
- [x] `printf '\a'`: bell behaves as configured (off / visual flash / audible).
- [x] `printf 'Downloading 37%%\n'`: the tab shows a thin 37 % progress line at the bottom of
      its header, which clears after about 5 s.
- [x] `exit`: the tab closes (default) or, in a profile with "Keep the tab open after the
      process exits", shows the exit code and any key restarts the shell.

M1 passed on 2026-10-22 (macOS 27.0.1, Xcode 27.1).

## M2 Tabs and splits

- [x] ⌘T opens a new tab at the end of the strip, ⌘W closes, ⌘⇧T reopens the closed tab after
      the active one with its profile and cwd.
- [x] Right-click a tab: Rename, Duplicate (the copy opens next to the original), Pin (the tab
      joins the pinned group at the front; ⌘W and ⌘⇧←/→ leave it there), Colour (a bar along
      the bottom), Close others / left / right (idle tabs close, busy ones ask once, pinned
      tabs stay).
- [x] Drag a tab to reorder; the active tab keeps its content.
- [x] Settings → Window → tab bar position top / bottom / left / right: the strip moves and the
      terminal stays below / beside it without overlap.
- [x] With six or more tabs every tab stays visible, shrinking to fit; the + follows the last tab.
- [x] ⌘1…⌘9 switch by index. Bind "Next tab (MRU order)" in Settings → Hotkeys (no default): it
      switches to the most recently used tab.
- [x] Split right ⌘⇧D, down ⌘D, left / up from the Shell menu: the new pane gets focus and
      starts in the current directory.
- [x] Drag a divider: both panes resize and the shells see the new size (`stty size`).
- [x] Pane navigation shortcuts move focus in all four directions; previous / next cycle.
- [x] Maximise pane toggles a single pane filling the tab; the others come back untouched.
- [x] Broadcast (⌘⇧I, View → Broadcast Input to All Panes): every pane shows the focus ring,
      typing and pasting reach every pane of the tab; ⌘⇧I again turns it off.
- [x] Explode tab (⌘⇧.): the first pane stays, the others become tabs at the end. Combine tabs
      (⌘⇧,): every pane joins the active tab in an even grid.
- [x] Close a pane or tab whose shell has a running child (`sleep 100`): a confirmation
      sheet appears; cancelling keeps it.
- [x] Save layout as profile: the new profile appears in the selector and reopens the layout.

M2 passed on 2026-10-22 (macOS 27.0.1, Xcode 27.1).

## M3 Hotkeys, selector and menus

- [x] Settings → Hotkeys lists every command with its macOS default; filtering works.
- [x] Capture a new binding (e.g. ⌃⇧X for "New tab"): the sheet shows the chord as pressed,
      Save adds it next to the existing ones and `config.yaml` contains the diff. Menus show a
      command's first binding, so the menu item changes once ⌘T is removed.
- [x] A two-key chord (e.g. ⌃A then C) works: the first stroke is swallowed and the second,
      within 2 s, runs the command. There is no on-screen indicator (Tabby has none).
- [x] Reset returns the default and removes the key from `config.yaml`.
- [x] ⌘E opens the profile selector: Recent, groups, Built-in (the `~/.ssh/config` hosts are
      listed there, as in Tabby), "Manage profiles" and quick connect `user@host:port`; fuzzy
      search, ↑↓, ↩ opens, Esc closes.
- [x] ⌘⇧P opens the command palette; running "Toggle fullscreen" from it works.
- [x] The global show/hide hotkey shows / hides the window while another app is frontmost, and
      rebinding it in Settings → Hotkeys takes effect without a restart. Its default ⌃Space is
      also macOS's "Select the previous input source" shortcut (as with Tabby's default), so
      where that is on, test with another binding.
- [x] Every menu item in Shell, Edit, View and Window does what its title says, and macOS adds
      no window-tab items or second "Enter Full Screen" of its own.

M3 passed on 2026-10-22 (macOS 27.0.1, Xcode 27.1).

## M4 SSH

Needs a reachable sshd (a local one via System Settings → Sharing → Remote Login is fine).

- [ ] Quick connect `user@localhost` (first `ssh-keygen -R localhost` so the host is unknown):
      the host key sheet shows host, key type and SHA256 fingerprint. "Accept and remember" writes the
      key to the app's `known_hosts`; "Disconnect" ends with "Connection failed" and any key retries.
- [ ] Password prompt appears as a native sheet; with "Remember in Keychain" a login keychain
      item `ssh@localhost:22` for that user exists after a successful login. The next
      connection does not prompt.
- [ ] Wrong password: the prompt comes back; the remembered one is not overwritten by a
      failed attempt.
- [ ] Key auth with a passphrase-protected key: the passphrase prompt appears once.
- [ ] Agent auth (`ssh-add -l` lists a key): connects without a prompt.
- [ ] Keyboard-interactive: each server prompt shows as a sheet in order.
- [ ] Jump host: a profile with a jump host connects through it (`who am i` on the target
      shows the jump host's address).
- [ ] Hosts from `~/.ssh/config` appear in the selector and Settings → Profiles under
      "Imported from .ssh/config", with user, port, identity file and ProxyJump carried over.
      They are read-only; Duplicate one to edit it.
- [ ] Local port forward `8080 → localhost:22` in the profile: `nc -z localhost 8080` succeeds
      while connected and fails about 10 s after disconnect (the shared connection lingers
      for `ControlPersist 10s`).
- [ ] Type `~.` or use Shell → Disconnect: the tab stays, shows "Session closed. Press
      any key to restart.", and any key reconnects. `exit` in the remote shell closes the tab.
- [ ] With Settings → SSH → "Warn when closing an open connection" on, ⌘W on a connected tab
      asks "Disconnect from localhost?". A profile overrides it with `warnOnClose: false` in its
      `options` (Config file page; the profile editor has no control for it yet).
- [ ] Opening a second tab to the same host reuses the connection (no second prompt).

## M5 Settings and persistence

- [ ] Settings → Color scheme: picking a scheme recolours the terminal and the chrome (tab
      bar, start page, selector) live; the preview swatches show all 16 colours.
- [ ] Mode System / Dark / Light: switching macOS appearance swaps between the chosen dark
      and light schemes.
- [ ] Appearance: font family and size, cursor shape and blink, bold-as-bright apply live.
- [ ] Window: opacity, vibrancy and title bar style apply live.
- [ ] Docking: each side (top, bottom, left, right) positions the first window at the
      configured size; always-on-top keeps it above other windows; the global hotkey toggles it.
- [ ] Application → Import Tabby's `config.yaml`: profiles, hotkeys and scheme appear; the
      Electron files in `~/Library/Application Support/tabby/` are not modified
      (compare timestamps).
- [ ] `config.yaml` after changing one setting contains only that key and `version`
      (diff-only save); unknown keys from an imported file survive a save.
- [ ] Config file page: editing YAML and ⌘S applies it; invalid YAML is rejected with a message.
- [ ] Open three tabs with splits, custom titles and some output, quit, relaunch: tabs,
      split layout, titles and the last screen of each buffer are restored.
- [ ] Run `sleep 5; exit` in a tab, switch to another app before it finishes: a "process
      completed" notification appears (needs the `.app` and notification permission).

## Findings

| Date | Milestone | Finding | Fix |
|---|---|---|---|
| 2026-10-21 | M0 | Closing a tab (seen with SSH tabs) crashed in `_dispatch_semaphore_dispose` from `PTYProcess.deinit`: output blocks queued on the main queue signalled the back-pressure semaphore through a weak reference, so the signals were lost after dealloc. Same trap killed the CI test run. | `acf887f7` |
| 2026-10-21 | M0 | `recoveryState()` right after a tab opened recorded the app's own cwd: `proc_pidinfo` on a forked child reports the parent's directory until the child has exec'd. | `424ed008` |
| 2026-10-22 | M0 | No `config.yaml` after the first launch; it was only written after the first settings change. | `50f2fa90` |
| 2026-10-22 | M2 | Found by reading before the M1–M5 run: with the tab bar on the left, the terminal's first row sat under the transparent title bar. | `68a22092` |
| 2026-10-22 | M4 | Found by reading: `ssh.warnOnClose` was never read, so closing a connected SSH tab, pane or window, or quitting, never asked. | `8e6a165f` |
| 2026-10-22 | M4 | Found by reading: "Disconnect tab" dropped the session but left a dead pane with no message and no way to reconnect. | `19e359fb` |
| 2026-10-22 | M1 | Found by reading: ⇧↩ did nothing in the search bar. | `070c18ef` |
| 2026-10-22 | M5 | Found by reading: the "process completed" notification needed the pane to be unfocused, and switching apps keeps it focused, so it never appeared. | `e2a5c05e` |
| 2026-10-22 | M2 | Found by reading: broadcast showed no indicator and a paste reached only the focused pane. | `de35e3ed` |
| 2026-10-22 | M2 | Found by reading: duplicated and reopened tabs opened at the end of the strip, not next to the original / active tab. | `8089cb4e` |
| 2026-10-22 | M2 | Found by reading: pinned tabs were not grouped at the front, ⌘W closed them, and Close others / left / right closed busy tabs without asking. | `400ccb0c` |
| 2026-10-22 | M2 | Found by reading: combine put every pane in one row, and explode inserted the new tabs after the active one. | `34839fda` |
| 2026-10-22 | M2 | Found by reading: ⌘T inserted after the active tab (Tabby appends), which could put a new tab inside the pinned group. | `73ba56bd` |
| 2026-10-22 | M2 | The tab strip clipped every tab past the second: the tab scroll view and the window drag area split the free width. | `be59569c` |
| 2026-10-22 | M2 | Under `swift test` the "process completed" banner raised (`bundleProxyForCurrentProcess is nil`): xctest's main bundle has an identifier but is no app. | `97ef7449` |
| 2026-10-22 | M2 | The tab colour was drawn along the top, where it looked like the active-tab marker; Tabby draws it along the bottom. | `f4104929` |
| 2026-10-22 | M3 | macOS added greyed window-tab items (Show Tab Bar, Merge All Windows, …) next to TabbyMac's own tab commands, and a second "Enter Full Screen", to the menus. | `1d4d0152` |

Open: none.
