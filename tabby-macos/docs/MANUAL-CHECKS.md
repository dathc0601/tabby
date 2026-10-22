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

- [ ] The shell starts in the home directory with `TERM=xterm-256color`, `COLORTERM=truecolor`.
- [ ] `ls --color`, `vim`, `htop` or `top` render correctly; resizing the window reflows.
- [ ] `printf '\e]0;Hello\a'` sets the tab title; `cd /tmp` then ⌘T opens the new tab in
      `/private/tmp` (OSC 7, or the foreground process cwd, which macOS reports resolved).
- [ ] ⌘F opens the search bar: typing finds matches, the counter updates, ↩ / ↓ go to the
      next match and ⇧↩ / ↑ to the previous one, case / regex / whole-word toggles work,
      Esc closes.
- [ ] ⌘+ / ⌘- / ⌘0 zoom the focused pane's font. After a split the zoomed pane keeps its
      size and the new pane starts at the configured size, like a new tab (zoom is per pane,
      as in Tabby).
- [ ] Select text: copy on select (if enabled) puts it on the clipboard; ⌘C copies, ⌘V pastes,
      middle-click pastes, right-click follows the configured action (menu / paste / select).
- [ ] Paste two lines: the "Paste multiple lines?" sheet shows the trimmed preview; Paste sends
      them as `\r`-separated input; Cancel sends nothing.
- [ ] Run `printf '\e[?2004h'; cat -v` and paste a line: it shows as `^[[200~…^[[201~`.
      Plain `cat` shows no markers, because paste is only wrapped once the program turns
      bracketed paste on (as in Tabby). ^C, then `printf '\e[?2004l'`.
- [ ] `printf '\a'`: bell behaves as configured (off / visual flash / audible).
- [ ] `printf 'Downloading 37%%\n'`: the tab shows a thin 37 % progress line at the bottom of
      its header, which clears after about 5 s.
- [ ] `exit`: the tab closes (default) or, in a profile with "Keep the tab open after the
      process exits", shows the exit code and any key restarts the shell.

## M2 Tabs and splits

- [ ] ⌘T new tab, ⌘W close, ⌘⇧T reopen the closed tab with its profile and cwd.
- [ ] Right-click a tab: Rename, Duplicate, Pin, Colour, Close others / left / right work.
- [ ] Drag a tab to reorder; the active tab keeps its content.
- [ ] Settings → Window → tab bar position top / bottom / left / right: the strip moves and the
      terminal stays below / beside it without overlap.
- [ ] ⌘1…⌘9 switch by index. Bind "Next tab (MRU order)" in Settings → Hotkeys (no default): it
      switches to the most recently used tab.
- [ ] Split right / bottom / left / top (⌘D, ⌘⇧D and the others): the new pane gets focus and
      starts in the current directory.
- [ ] Drag a divider: both panes resize and the shells see the new size (`stty size`).
- [ ] Pane navigation shortcuts move focus in all four directions; previous / next cycle.
- [ ] Maximise pane toggles a single pane filling the tab; the others come back untouched.
- [ ] "Focus all panes" (broadcast): typing in one pane echoes in every pane of the tab.
- [ ] Explode tab: each pane becomes a tab. Combine tabs: all tabs become panes of one.
- [ ] Close a pane or tab whose shell has a running child (`sleep 100`): a confirmation
      sheet appears; cancelling keeps it.
- [ ] Save layout as profile: the new profile appears in the selector and reopens the layout.

## M3 Hotkeys, selector and menus

- [ ] Settings → Hotkeys lists every command with its macOS default; filtering works.
- [ ] Capture a new binding (e.g. ⌃⇧X for "New tab"): the sheet shows the chord as pressed,
      Save stores it, the menu item's shortcut updates, and `config.yaml` contains the diff.
- [ ] A two-key chord (e.g. ⌃A then C) works: the first stroke is swallowed and the second,
      within 2 s, runs the command. There is no on-screen indicator (Tabby has none).
- [ ] Reset returns the default and removes the key from `config.yaml`.
- [ ] ⌘E opens the profile selector: Recent, groups, Built-in, "Manage profiles" and
      quick connect `user@host:port`; fuzzy search, ↑↓, ↩ opens, Esc closes.
- [ ] ⌘⇧P opens the command palette; running "Toggle fullscreen" from it works.
- [ ] Ctrl-Space (global) shows / hides the window while another app is frontmost.
      Rebinding it in Settings → Hotkeys takes effect without a restart.
- [ ] Every menu item in Shell, Edit, View and Window does what its title says.

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
| 2026-10-22 | M2 | Found by reading before the M1–M5 run: with the tab bar on the left, the terminal's first row sat under the transparent title bar. | `a445b781` |
| 2026-10-22 | M4 | Found by reading: `ssh.warnOnClose` was never read, so closing a connected SSH tab, pane or window, or quitting, never asked. | `e5874d60` |
| 2026-10-22 | M4 | Found by reading: "Disconnect tab" dropped the session but left a dead pane with no message and no way to reconnect. | `5e8db557` |
| 2026-10-22 | M1 | Found by reading: ⇧↩ did nothing in the search bar. | `4ddb286f` |
| 2026-10-22 | M5 | Found by reading: the "process completed" notification needed the pane to be unfocused, and switching apps keeps it focused, so it never appeared. | `6654757c` |

Open: none.
