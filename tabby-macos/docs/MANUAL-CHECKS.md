# Manual checks

What to try by hand after a build, and what should happen. Unit tests cover the models;
this list covers what only shows up on screen or needs a real shell, keychain or sshd.
Run it from the `.app` built by Xcode, not `swift run`, because notifications and the
bundle identifier only exist there. For a clean run set `TABBYMAC_CONFIG_DIRECTORY` to an
empty folder first.

Mark items `[x]` when they pass. Anything that fails gets a line under **Findings** at
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

- [x] Quick connect `user@localhost` (first `ssh-keygen -R localhost -f <app known_hosts>` so the
      host is unknown): the host key sheet shows host, key type and the SHA256 fingerprint exactly
      as `ssh-keygen -l` prints it. "Accept and remember" writes the key to the app's
      `known_hosts` only; "Disconnect" ends with "Connection failed" and any key retries.
- [x] Password prompt appears as a native sheet; with "Remember in Keychain" a login keychain
      item `ssh@localhost:22` for that user exists after a successful login. The next
      connection says "Using saved password" and does not prompt. (A rebuilt app asks macOS for
      Keychain access again: ad-hoc signing.)
- [x] Wrong password: the prompt comes back; nothing is saved for a failed attempt. Cancel ends
      the attempt with "Authentication cancelled" (no empty password is sent).
- [x] Key auth with a passphrase-protected key: the passphrase prompt appears once.
- [x] Agent auth (`ssh-add -l` lists a key): connects without a prompt.
- [x] Keyboard-interactive: server prompts show as sheets (macOS sshd asks a single "Password:";
      several prompts in order need another server).
- [x] Jump host: a profile with a jump host connects through it (`ProxyJump`, the hop runs as
      `ssh -W`). `who am i` shows the jump host's address when it is a different machine.
- [x] Hosts from `~/.ssh/config` appear in the selector (under Built-in, as in Tabby) and in
      Settings → Profiles under "Imported from .ssh/config", with user, port, identity file and
      ProxyJump carried over. They are read-only; Duplicate one to edit it.
- [x] Local port forward `<free port> → localhost:22` in the profile (8080 may be taken, e.g. by
      a local httpd): `nc -z 127.0.0.1 <port>` succeeds while connected and fails about 10 s
      after disconnect once nothing uses it (the shared connection lingers for
      `ControlPersist 10s`, and each probe through the forward restarts that wait).
- [x] Type `~.` or use Shell → Disconnect: the tab stays, shows "Session closed. Press
      any key to restart.", and any key reconnects. `exit` in the remote shell closes the tab.
- [x] With Settings → SSH → "Warn when closing an open connection" on, ⌘W on a connected tab
      asks "Disconnect from localhost?" (Quit asks too). A profile overrides it with
      `warnOnClose: false` in its `options` (Config file page; the profile editor has no control
      for it yet).
- [x] Opening a second tab to the same host reuses the connection (no second prompt); ending
      that tab is not reported as "Connection failed".

M4 passed on 2026-10-22 (macOS 27.0.1, Xcode 27.1).

## M5 Settings and persistence

- [x] Settings → Color scheme: picking a scheme recolours the terminal and the chrome (tab
      bar, start page, selector) live; the preview swatches show all 16 colours.
- [x] Mode System / Dark / Light: switching macOS appearance swaps between the chosen dark
      and light schemes.
- [x] Appearance: font family and size, cursor shape and blink, bold-as-bright apply live.
- [x] Window: opacity, vibrancy and title bar style apply live.
- [x] Docking: each side (top, bottom, left, right) positions the first window at the
      configured size on the display under the mouse; always-on-top keeps it (and Settings)
      above other windows and turning it off lowers them; the global hotkey toggles it.
      ⌃Space is also macOS's "previous input source" shortcut: add a second binding to test.
- [x] Application → Import Tabby's `config.yaml`: profiles, hotkeys and scheme appear; the
      Electron files in `~/Library/Application Support/tabby/` are not modified
      (compare timestamps).
- [x] `config.yaml` after changing one setting contains only that key and `version`
      (diff-only save); unknown keys from an imported file survive a save.
- [x] Config file page: editing YAML and ⌘S applies it; invalid YAML, or YAML that is not a
      map, is rejected with a message.
- [x] Open three tabs with splits, custom titles and some output, quit, relaunch: tabs,
      split layout, titles and the last screen of each buffer are restored.
- [ ] Run `sleep 5; exit` in a tab, switch to another app before it finishes: a "process
      completed" notification appears (needs the `.app` and notification permission).
      Blocked on the M5 Mac: macOS answers the permission request with UNErrorDomain 1 ("not
      allowed for this application") for every locally built app, a minimal probe app too,
      so nothing can be shown. TabbyMac logs that reason to stderr.

M5 passed on 2026-10-22 (macOS 27.0.1, Xcode 27.1), except the notification item, which macOS
blocks on that Mac.

## M6 Phase 2 redesign

Compare with the Claude Design canvases (`Tabby Design Canvas.zip`, not in git) and
`docs/DESIGN-TOKENS.md`. `TABBYMAC_SNAPSHOT_DIR=<dir> swift test --filter DesignSnapshotTests`
renders the main screens to PNG without a display; these items cover what only the real
window shows (traffic lights, hover, drag and drop, sheets, animation).

- [ ] Tab bar: 38 pt bar on the chrome colour, rounded 28 pt tabs, traffic lights centred in
      the bar; hover shows ⋯ and ×; pinned tabs are 92 pt; a tab colour is a 2 pt bar at the
      bottom; progress fills the tab and shows a percentage; activity shows a dot.
- [ ] Twelve tabs in a narrow window: tabs shrink to 120 pt, then the strip scrolls, the
      active tab stays in view and "+N" lists the hidden ones. With Flex tabs on they shrink
      to 64 pt first.
- [ ] Dragging a tab along the strip shows an accent slot where it lands; Esc cancels.
- [ ] Tabs on the left: a 200 pt column, "New tab ⌘T" row, toolbar in the footer.
- [ ] Spaciness 0.8 / 1.5 scales the bar (30.4 / 57 pt), the tabs and the settings rows.
- [ ] Vibrancy: the window turns translucent; the active tab stays readable.
- [ ] ⌘, opens Settings as a tab (a second ⌘, focuses it); the sidebar search finds "dock"
      on the Window page; every page matches the canvas; nothing is cut off at 960 × 620.
- [ ] Color scheme: clicking a tile recolours terminal and chrome live; the editor's wells
      change the scheme and Save as… adds a custom scheme.
- [ ] Hotkeys: capturing ⌘T for "Split right" warns "Also used by New tab".
- [ ] Profiles: the outline, the bottom bar and the editor sheet (all five pages) work; the
      password row says "Saved in Keychain" for a saved password without a Keychain prompt;
      Forget asks before deleting it; deleting a profile says its password stays.
- [ ] Config file: line numbers and colours; typing a stray word shows the error and
      disables Save.
- [ ] First launch with an empty config folder shows the Welcome tab; "Close and never show
      again" keeps it away after a relaunch.
- [ ] Start page (close every tab): ↑ ↓ ↩ work, ⌘1–⌘3 open the recent profiles.
- [ ] ⌘E selector: 660 pt wide under the tab bar, group headers, accent row with "↩ open",
      footer hints; an unknown host offers quick connect.
- [ ] Search bar (⌘F): counter, Aa / .* / W toggles, ⇧↩ previous.
- [ ] Paste of several lines shows the card; Esc cancels, ↩ pastes; host key and password
      prompts are cards too.
- [ ] SSH tab: hovering the pane shows the status chip; Reconnect on a connected session asks
      first; stopping sshd shows Disconnected with Reconnect (no question); a "Reconnect"
      profile shows Reconnecting n/5 and gives up after five.
- [ ] A command that ends in a background tab shows the "Process completed" toast with Show.
- [ ] Split panes: divider grip on hover, focused pane ring, others dimmed; ⌥⌘↩ maximises
      with the chip and Restore. Dragging a tab onto a pane shows the four targets and drops
      it as a split.
- [ ] Docked: no traffic lights, the global hotkey slides it in and out, dragging its free
      edge changes the size kept for next time.

## M7 Personal account and sync

Two copies of the app act as two Macs. Build once, with a fixed output folder:

```sh
cd Xcode && xcodegen generate && cd ..
xcodebuild -project Xcode/TabbyMac.xcodeproj -scheme TabbyMac -configuration Debug \
  -derivedDataPath Xcode/build -skipPackagePluginValidation build
APP=Xcode/build/Build/Products/Debug/TabbyMac.app/Contents/MacOS/TabbyMac
mkdir -p ~/tabbymac-m7/a/home/.ssh ~/tabbymac-m7/b/home/.ssh
```

Start each copy from the binary (not `open`, which drops the environment), each in its own
Terminal window:

```sh
TABBYMAC_CONFIG_DIRECTORY=~/tabbymac-m7/a TABBYMAC_SYNC_HOME=~/tabbymac-m7/a/home \
  TABBYMAC_KEYCHAIN=memory "$APP"
TABBYMAC_CONFIG_DIRECTORY=~/tabbymac-m7/b TABBYMAC_SYNC_HOME=~/tabbymac-m7/b/home \
  TABBYMAC_KEYCHAIN=memory "$APP"
```

- **Server.** Without `TABBYMAC_SYNC_URL` the copies use the real server,
  `https://tabby-sync.dcstyle.info`. Use a throwaway email and finish with Settings › Account &
  sync › Delete account…. For a local server instead, fill `../tabby-sync-server/.env` as its
  README shows, `docker compose -f ../tabby-sync-server/compose.yaml up -d --build`, and add
  `TABBYMAC_SYNC_URL=http://localhost:8080` to both commands. `TABBYMAC_SYNC_URL=memory:` runs
  one copy against an in-memory server for UI-only checks; `AppClientEndToEndTests` in
  `tabby-sync-server` runs the whole flow without a UI.
- **`TABBYMAC_KEYCHAIN=memory` is required.** Without it both copies share the login
  keychain: they would upload its SSH passwords (Electron Tabby's too, same item names) and
  "Remove synced data" could delete them. With it, passwords and the account session live in
  memory: quitting a copy signs it out, and nothing asks for the Mac password.
- **`TABBYMAC_SYNC_HOME` only changes what sync reads** (the `~/.ssh/id_*` default identities it
  offers to upload). ssh itself, the synced-key fallback and the `~/.ssh/config` import still
  use the real home folder. For "a key that only exists on the first Mac", create it under
  `~/tabbymac-m7/a/home/.ssh/` with a name that does not exist in the real `~/.ssh`, name it in
  the profile with its full path, and check on copy B that the profile connects through the
  synced copy in `~/tabbymac-m7/b/keys/`.
- Afterwards: quit both copies and `rm -rf ~/tabbymac-m7`.

- [ ] Toolbar person button opens Sign in; "Create account" → step 1 (strength meter, the
      passwords must match) → step 2 recovery key: Copy, Save as file…, Print work; Start
      syncing stays disabled until the checkbox is ticked; the avatar shows a check after the
      upload.
- [ ] Private key prompt: a profile with a key file and an `~/.ssh/id_*` default identity
      are listed once; declined keys are not asked about again.
- [ ] Second Mac: Sign in with the same email and password → "Welcome back" with the counts;
      profiles, groups, settings, known hosts appear; an SSH profile with a saved password
      and a key that only exists on the first Mac connects without a prompt.
- [ ] Edit a profile on one Mac: within a minute the other shows it and a "Synced" toast.
- [ ] Settings › Account & sync: Auto off stops automatic syncs; Sync now works; turning a
      part off keeps it out of both directions; Devices lists both Macs and Remove signs the
      other one out at its next sync.
- [ ] Recovery key View… asks for the password; Regenerate… shows a new key and the old one
      no longer works with "Forgot password?"; Change password keeps the other Mac signed in.
- [ ] "Forgot password?" with the recovery key sets a new password and restores the data.
- [ ] Sign out → Keep a local copy leaves everything usable; Remove synced data deletes only
      what came from the account (`<config>/keys` emptied, `~/.ssh` untouched).
- [ ] Wrong password, no network and a stopped server show readable errors (sheet or toast),
      never a hang.
- [ ] Settings › Vault lists saved passwords; Show reveals one (with the login keychain it may
      ask for the Mac password; not under `TABBYMAC_KEYCHAIN=memory`), Remove deletes it here
      and, after a sync, on the other Mac.

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
| 2026-10-22 | M4 | The host key sheet hyphenated the SHA256 fingerprint where it wrapped, so it no longer matched `ssh-keygen -l`. | `19219298` |
| 2026-10-22 | M4 | Cancelling a password prompt made ssh send an empty password (a failed login on the server, then the prompt again, until "Too many authentication failures"); and ssh ignored the SIGHUP meant to end it. | `00929404`, `30e3cd37` |
| 2026-10-22 | M4 | A tab on a shared (ControlMaster) connection printed "Connection failed" when it closed normally. | `00929404` |
| 2026-10-22 | M2 | With ten or more tabs the tab index wrapped and titles turned into stray glyphs. | `d86a27ea` |
| 2026-10-22 | M5 | The Config file page and the Tabby import accepted YAML that is not a map (a stray word, a list), which wiped every setting and profile. | `84a11b96` |
| 2026-10-22 | M5 | Turning off "Always on top" while docked left the window above every other window until it was undocked. | `359419e4` |
| 2026-10-22 | M5 | The always-on-top docked window covered the Settings window as soon as a side was picked, and whenever Settings was opened while docked. | `7887307e` |
| 2026-10-22 | M5 | The window docked on whichever display it was on, not on the one under the mouse (Tabby's `dockScreen: current`); `dockScreen` ids from Tabby configs were ignored. | `9e97a6ba` |
| 2026-10-22 | M5 | Only the first `toggle-window` binding was registered, so a second one did nothing while macOS keeps ⌃Space; `hacks.globalHotkey: true` from a Tabby config registered a key named "True". | `29a0819b` |
| 2026-10-22 | M5 | The notification permission error was dropped, so a missing "process completed" banner gave no reason. | `bce4ebf9` |

Open: the M5 notification item, blocked by macOS on the test Mac (see the item).
