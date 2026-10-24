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

- [x] Tab bar: 38 pt bar on the chrome colour, rounded 28 pt tabs, traffic lights centred in
      the bar; hover shows ⋯ and ×; pinned tabs are 92 pt; a tab colour is a 2 pt bar at the
      bottom; progress fills the tab and shows a percentage; activity shows a dot.
- [x] Twelve tabs in a narrow window: tabs shrink to 120 pt, then the strip scrolls, the
      active tab stays in view and "+N" lists the hidden ones. With Flex tabs on they shrink
      to 64 pt first.
- [ ] Dragging a tab along the strip shows an accent slot where it lands; Esc cancels.
      *Open: needs a mouse drag; the computer-use tool has none.*
- [x] Tabs on the left: a 200 pt column, "New tab ⌘T" row, toolbar in the footer.
- [x] Spaciness 0.8 / 1.5 scales the bar (30.4 / 57 pt), the tabs and the settings rows.
- [x] Vibrancy: the window turns translucent; the active tab stays readable.
- [x] ⌘, opens Settings as a tab (a second ⌘, focuses it); the sidebar search finds "dock"
      on the Window page; every page matches the canvas; nothing is cut off at 960 × 620.
- [x] Color scheme: clicking a tile recolours terminal and chrome live; the editor's wells
      change the scheme and Save as… adds a custom scheme.
- [x] Hotkeys: capturing ⌘T for "Split right" warns "Also used by New tab".
- [x] Profiles: the outline, the bottom bar and the editor sheet (all five pages) work; the
      password row says "Saved in Keychain" for a saved password without a Keychain prompt;
      Forget asks before deleting it; deleting a profile says its password stays.
- [x] Config file: line numbers and colours; typing a stray word shows the error and
      disables Save.
- [x] First launch with an empty config folder shows the Welcome tab; "Close and never show
      again" keeps it away after a relaunch.
- [x] Start page (close every tab): ↑ ↓ ↩ work, ⌘1–⌘3 open the recent profiles.
- [x] ⌘E selector: 660 pt wide under the tab bar, group headers, accent row with "↩ open",
      footer hints; an unknown host offers quick connect.
- [x] Search bar (⌘F): counter, Aa / .* / W toggles, ⇧↩ previous.
- [x] Paste of several lines shows the card; Esc cancels, ↩ pastes; host key and password
      prompts are cards too.
- [x] SSH tab: hovering the pane shows the status chip; Reconnect on a connected session asks
      first; stopping sshd shows Disconnected with Reconnect (no question); a "Reconnect"
      profile shows Reconnecting n/5 and gives up after five.
- [x] A command that ends in a background tab shows the "Process completed" toast with Show.
- [ ] Split panes: divider grip on hover, focused pane ring, others dimmed; ⌥⌘↩ maximises
      with the chip and Restore. Dragging a tab onto a pane shows the four targets and drops
      it as a split. *Passed except the drag onto a pane (needs a mouse drag).*
- [ ] Docked: no traffic lights, the global hotkey slides it in and out, dragging its free
      edge changes the size kept for next time. *Passed except dragging the edge (needs a
      mouse drag).*

M6 walked on 2026-10-23 (macOS 27.0.1, Xcode 27.1, built from `claude/modest-einstein-y8eodm`)
with `TABBYMAC_KEYCHAIN=memory` and `TABBYMAC_SYNC_URL=memory:`; SSH items against a throwaway
OpenSSH container on 127.0.0.1:2222. Every item passed after the fixes in Findings, except the
three mouse drags above. The "Saved in Keychain" row was checked with the in-memory keychain,
so "without a Keychain prompt" is still to be seen with the login keychain.

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

- [x] Toolbar person button opens Sign in; "Create account" → step 1 (strength meter, the
      passwords must match) → step 2 recovery key: Copy, Save as file…, Print work; Start
      syncing stays disabled until the checkbox is ticked; the avatar shows a check after the
      upload.
- [x] Private key prompt: a profile with a key file and an `~/.ssh/id_*` default identity
      are listed once; declined keys are not asked about again.
- [x] Second Mac: Sign in with the same email and password → "Welcome back" with the counts;
      profiles, groups, settings, known hosts appear; an SSH profile with a saved password
      and a key that only exists on the first Mac connects without a prompt.
- [x] Edit a profile on one Mac: within a minute the other shows it and a "Synced" toast.
- [x] Settings › Account & sync: Auto off stops automatic syncs; Sync now works; turning a
      part off keeps it out of both directions; Devices lists both Macs and Remove signs the
      other one out at its next sync.
- [x] Recovery key View… asks for the password; Regenerate… shows a new key and the old one
      no longer works with "Forgot password?"; Change password keeps the other Mac signed in.
- [x] "Forgot password?" with the recovery key sets a new password and restores the data.
- [x] Sign out → Keep a local copy leaves everything usable; Remove synced data deletes only
      what came from the account (`<config>/keys` emptied, `~/.ssh` untouched).
- [ ] Wrong password, no network and a stopped server show readable errors (sheet or toast),
      never a hang. *Wrong password and a stopped server passed; no network not walked (it
      needs a change to the Mac's network settings).*
- [x] Settings › Vault lists saved passwords; Show reveals one (with the login keychain it may
      ask for the Mac password; not under `TABBYMAC_KEYCHAIN=memory`), Remove deletes it here
      and, after a sync, on the other Mac.

M7 walked on 2026-10-23 with two copies (`TABBYMAC_KEYCHAIN=memory`) against a local server
(`docker compose` on 127.0.0.1:18080, since port 8080 was taken on the test Mac), not the live
one: creating an account on https://tabby-sync.dcstyle.info is the owner's call. Every item
passed after the fixes in Findings, except the no-network case. A short sign-up, sync and
delete-account run against the live server is still to do.

## M8 SSH library backend (phase 3)

Build the app as for M7 (it bundles libssh; `brew install libssh` first). Use a test config
folder (`TABBYMAC_CONFIG_DIRECTORY`). For a local server, turn on Remote Login (it needs
your Mac password, as in M4) or use a VPS you own. The integration tests already cover
logins, forwards, SFTP, proxies and agent forwarding against a throwaway sshd; these items
cover what only the window shows and what the test sshd can't do (PAM, 2FA, X11).

- [x] First connection: the host key card shows the type and fingerprint and "Remember in
      known_hosts"; unticked, the next connection asks again. With the key changed in
      known_hosts, the warning shows both fingerprints and Return rejects.
- [x] Password login asks once with "Remember in Keychain"; the next login says "Using saved
      password". A wrong saved password is deleted and asked for again.
- [x] An encrypted key asks for its passphrase once (Remember), not again afterwards.
- [x] A 2FA host (keyboard-interactive) shows the panel at the top of the pane: "prompt n of
      m", the instruction with clickable links, hidden field, Back, Cancel, Continue. Cancel
      ends the login; the terminal gets its full height back.
- [x] Two tabs of a profile open on one connection (second tab instant, no host key
      question); closing one leaves the other working.
- [x] Jump host profile: connects through the jump profile; a loop names both profiles.
- [x] Agent: a key only in the agent logs in; with Agent forwarding, `ssh-add -l` on the
      server lists it.
- [ ] X11 (XQuartz installed, server with xauth): `xeyes` from the server opens on this Mac.
      *Not walked: the test Mac has no XQuartz.*
- [x] Chip: Ports and SFTP buttons are enabled only while connected. Ports: add Local
      127.0.0.1:8000 → a web server, open it in a browser; Remote and Dynamic (browser SOCKS
      proxy) work; × puts the forward back in the form; a busy port shows the error.
- [x] A profile's saved forwards start on connect; a busy one shows a toast and the session
      carries on.
- [ ] SFTP (chip, ⌘ hotkey `open-sftp` if bound, pane menu "Open SFTP Panel"): opens at the
      shell's folder when it reports one (OSC 7), else the last one, else /; breadcrumb and
      typed path (double-click); Filter; Go up; click a folder / a link / a file (save
      panel); drop files and a folder from Finder; Create directory opens it; Delete asks;
      Download directory into "Download here" with "name (1)" on a clash; Edit locally
      re-uploads on save; a click on the terminal above closes the panel. *Everything but the
      drop from Finder passed (the harness cannot drag).*
- [ ] Transfers: the tab bar button appears with the first transfer and opens its popover;
      progress, speed, cancel, Show in Finder; Clear finished asks while one runs. *All but
      Show in Finder, which was not clicked.*
- [x] Profile editor: Test connection reports "Connected as … · key fingerprint" or the
      reason; its questions appear over the editor. Ciphers, keep-alive count, ready
      timeout, Backspace (Ctrl-H shows `^H` in `cat -v`) and "Reopen in the last directory"
      save and take effect.
- [ ] Settings › SSH: a custom agent socket and an X11 display are used. *The agent socket
      passed; the X11 display needs XQuartz.*
- [ ] `ssh.backend: openssh` in config.yaml: SSH tabs use the system client again (M4 passes);
      a profile's `backend: library` overrides it. *The switch and the override passed (a login
      with each); M4 was not walked again on the system client.*
- [x] The panels follow the colour scheme (switch schemes with the SFTP and 2FA panels open).

M8 walked on 2026-10-23 against throwaway servers in Docker on 127.0.0.1: an OpenSSH server
(password, plain, encrypted and agent-only keys, a web server on its port 8080, OSC 7 in the
prompt) and a scripted keyboard-interactive server (two prompts with a link, then a second
round). The agent was a separate `ssh-agent` holding one test key, set as Settings › SSH ›
SSH agent, with `SSH_AUTH_SOCK` unset. For "a busy port", use one that a program you started
listens on: binding 127.0.0.1 succeeds next to another program's wildcard listener (OpenSSH
behaves the same), so the forward would take that program's local traffic. Every walked item
passed after the fixes in Findings. Left for the owner: X11 with XQuartz, dropping files from
Finder, Show in Finder, and M4 again with `ssh.backend: openssh`.

## M9 Serial and telnet (phase 4)

Build the app as for M7 and use a test config folder (`TABBYMAC_CONFIG_DIRECTORY`). No
hardware is needed for most items:

- **A serial device:** `scripts/fake-serial-device.py --link ~/tabbymac-m9/tty` plays a device
  on a pseudo-terminal and prints every chunk it receives. It answers `AT` with `OK`, `login`
  with a login prompt, and `bin` with the bytes 00–1f. Ctrl-C unplugs it.
- **A telnet server:** `docker run --rm -d --name tabbymac-m9-telnetd -p 127.0.0.1:2323:23
  busybox telnetd -F -l /bin/sh`.
- **A raw socket peer:** `nc -l 127.0.0.1 <port>` on a port nothing else listens on.

The integration tests already cover the port settings, hang-up, telnet negotiation and the
stream modes, so these items cover what only the window shows. Never open a port you don't
own: only list it.

- [x] ⌥K (Show Serial connections) lists the "Serial connection" template, saved serial
      profiles and one profile per external port. The Mac's internal ports (debug console,
      Bluetooth) get none. *The New menu on Settings › Profiles was not opened on screen (unit
      test and snapshots only).*
- [x] The template asks for the port (a typed path such as `~/tabbymac-m9/tty` is offered
      as "Use /Users/…/tabbymac-m9/tty"), then the baud rate (115200 selected; typing 250000 offers it as a custom
      rate). The tab opens with " Serial  Port opened"; `AT` answers `OK`.
- [x] Chip: `tty · 115200`, Connected; its Baud rate button changes the rate and the label.
      The rate survives quitting and relaunching (no questions on restore). *The label and
      the restore passed; the Baud rate button (now a popover) was walked in M9b.*
- [x] Line by line: `> ` prompt; typing edits locally; Return sends the line (the device
      prints it); device output clears the prompt and it comes back. Hexadecimal input
      `41 54 0d` sends `AT\r`; Hexadecimal output shows `bin` as a dump.
- [x] Newlines: "Force CRLF" input newlines makes the device receive `\r\n` for Return.
- [x] Unplugging (Ctrl-C the device) prints "Port closed" and "… session closed", then "Press
      any key to restart"; with the device running again, a key reconnects.
- [x] A second tab on the same port says it is busy; `close` + Return in Auto mode closes
      the tab when the port then goes away.
- [x] A login script on a serial profile (expect `login:`, send `root`) answers the device's
      `login` prompt.
- [x] Telnet profile to 127.0.0.1:2323: "Connecting to 127.0.0.1", "Connected", a shell;
      `stty size` matches the pane and follows a resize; chip `127.0.0.1:2323`; Quick connect
      `127.0.0.1:2323` works too.
- [x] ⌘W on a connected telnet tab asks "Disconnect from 127.0.0.1?" (quitting asks the
      same); `exit` in the shell prints "Connection closed" and "127.0.0.1: session closed",
      and a key reconnects.
- [x] A raw socket (the "Raw socket connection" defaults: local echo, CRLF output) to an
      `nc -l` peer: typed lines are echoed locally and reach the peer with no telnet bytes;
      the peer's LF lines show properly.
- [x] Quitting and relaunching restores the serial and telnet tabs with their settings; they
      connect again without asking anything.
- [ ] Profile editor: the Serial and Telnet pages save their settings (device menu, baud rate
      menu with "Ask every time", data/stop bits, parity, flow control, stream processing,
      "Clear terminal after connection"); Settings › SSH › Quick connect uses lists SSH,
      Serial and Telnet; the Hotkeys page lists the serial and telnet entries. *Not walked on
      screen: covered by unit tests (pages, saving Normal/Keep, the picker's providers) and
      `DesignSnapshotTests.testSerialAndTelnetScreens`.*

M9 walked on 2026-10-23 with `scripts/fake-serial-device.py` behind `~/tabbymac-m9/tty`, a
busybox telnetd in Docker on 127.0.0.1:2323 and a small TCP peer for the raw socket. The test
profiles were written into the test config with ⌘⌥1–6 hotkeys so most items ran with the app
in the background. Two fixes came out of it (Findings). The foreground part stopped early
because the owner was using the Mac. Left for the owner:
- the items above marked as not walked;
- a real USB-serial adapter: Reconnect right after closing, a paste of 10 KB at 9600 baud,
  a rate above 230400 (custom rates fail on a pty by design), another app holding the port
  (exclusive mode), unplugging the cable;
- a real telnet device (a switch or router console).

## M9b Designed serial and telnet screens (milestone 4.5)

The Claude Design canvas "Tabby Connections" (C1–C10), applied in milestone 4.5. Same setup
as M9 (fake device, busybox telnetd); `DesignSnapshotTests.testSerialAndTelnetScreens`
renders the static screens, so these items cover what moves or needs the real window.

- [x] C1: a split with a serial and a telnet pane shows `2 · Core switch`-style labels at the
      top right; hovering a pane shows its chip in the label's place; a single pane has no
      label. Serial tabs use the `cable.connector` icon. *Tab icons are off by default
      (`terminal.showTabProfileIcon`); the icon was checked in the selectors and the editor.*
- [x] C2: the chip's Baud rate opens the popover (button shown pressed): 115200 checked and
      "In use"; clicking 9600 applies it (chip label changes, popover closes); a Custom rate
      and Return apply it; a rate the port refuses shows "Could not change the baud rate".
      *250000 on the pty showed the toast; clicking 9600 changed the chip to `tty · 9600`.*
- [x] C3: a profile with no rate opens the baud-rate list with 115200 selected and in view;
      typing 250000 offers `Use custom rate “250000”`.
- [x] C4: a profile with no device lists ports, then the Mac's own ports dimmed under "Built
      in"; a typed path is offered first.
- [x] C5: ⌥K lists saved serial profiles, the "Serial connection" template ("Asks for the
      port and baud rate"), then ports, with `⌥K serial` in the footer; typing
      `<path>@9600` offers "Quick connect" first ("… at 9600 baud").
- [x] C6/C7: the editor's Serial and Telnet pages: header tile in the profile colour, Device
      menu (ports, separator, built-in ports), data bits / stop bits / parity as segments,
      the design's footer and subtitle; Telnet Host with the inline Port. The New menu lists
      Local terminal, SSH, Serial and Telnet connection; the list shows "Serial"/"Telnet"
      badges and serial profiles as `path · baud` or "Ask every time". *Walked: the Serial
      General page and its Device menu, the list and the New menu (icons missing: Findings).
      The Advanced page's segments and the Telnet page: snapshots.*
- [x] C8: ⌘E with `127.0.0.1:2323` typed shows the matching profiles in their groups, then
      "Quick connect · SSH connection / Serial connection / Telnet connection".
- [x] C9: an error line starts with a black ` X ` on red and the message in the normal colour;
      the hexdump's offset is dim; a closed connection says "Press any key to reconnect".
      *A second tab on the busy port showed the error line; the hexdump is in the snapshot.*
- [x] C10: ⌘W on a connected telnet tab asks "Close this tab?" with Cancel / Close; Return
      does not close it, Escape cancels; quitting asks "Quit TabbyMac?" with Quit as the
      default. *Both alerts listed the same warning once per pane (Findings).*

M9b walked on 2026-10-23 with the same fake device and a busybox telnetd, keys sent to the
app's process where possible and clicks only after re-reading the window's position. The
Mac's own serial port (an LG monitor) was listed, never opened. Three fixes came out of it
(Findings). Left for the owner: the items in M9 still marked open, and real hardware.

## M10 Localization, notifications, links and the command line (phase 5)

Run the app built by Xcode with its own config folder (as in M9), a busybox telnetd on
127.0.0.1:2323 and, for the helper, `TabbyMac.app/Contents/MacOS/tabby`. Links are opened
with `open -a <the built TabbyMac.app> <link>`, so the Mac's default ssh:// and telnet://
apps stay as they are.

- [x] Settings › Application › Language: Deutsch changes the menu bar ("Einstellungen…"),
      the settings sidebar and pages, and the start page at once; Tiếng Việt translates every
      screen; Automatic goes back to the system language. No label is cut off.
- [x] Notify when done: run `sleep 8` in a tab; the tab's menu and the pane's menu show
      "Current process: sleep" and "Notify when done"; tick it, switch to another tab; when
      `sleep` ends a "Process completed" toast names it, and Show focuses the pane. A banner
      also appears where macOS allows this build to post them.
- [x] Notify on activity: tick it on an idle tab, then `sleep 3; echo done` there: a "Tab
      activity" toast appears once.
- [x] Bell: Settings › Terminal › Flash the Dock icon on; `sleep 3; printf '\a'` in a tab,
      switch to another app: the Dock icon bounces once. A bell in a background tab marks it.
- [x] Links: `open -a TabbyMac.app "telnet://127.0.0.1:2323"` opens a telnet tab that
      connects; `"ssh://me@127.0.0.1:2222"` opens an SSH tab for me@127.0.0.1:2222;
      `"tabbymac://open?directory=/tmp"` opens a shell in /tmp. Settings › Application ›
      Links names the app that opens ssh:// links now.
- [ ] The default-handler button: "Use TabbyMac" makes macOS ask, and afterwards ssh://
      links open in TabbyMac. *Left to the owner: it changes a system-wide default.*
- [x] Command line: `tabby open <dir>`, `tabby run ls -la` (after the "Run …?" alert),
      `tabby profile "<name>"`, `echo hi | tabby paste` (after "Paste …?"),
      `tabby quickConnect telnet 127.0.0.1:2323` and `tabby <dir>/script.sh` each open the
      tab in the running app and bring it to the front; `tabby --help` prints the commands;
      `tabby recent x` exits with status 2. Settings › Application › Command-line tool
      copies the install command.

Walked on 2026-10-24 with computer use (fixes in the Findings table). The banner itself
stays unchecked: macOS refuses banners to this ad-hoc build, so the toast was checked. The
default-handler item is the owner's. A telnet quick connect uses the line editor (Tabby's
`inputMode: readline`), so against busybox, which echoes too, each line shows twice after a
"> " prompt, as in Tabby.

## M11 Terminal and tab parity (phase 6)

Run the app built by Xcode with its own config folder (as in M10), the busybox telnetd on
127.0.0.1:2323, and lrzsz in Docker (`scripts/lrzsz-image.sh`, then
`docker run --rm -it tabbymac-lrzsz:1 bash` in a local tab). Links that would open a browser
or another app are left to the owner.

- [ ] Export to file (pane menu and tab menu): the save panel suggests terminal.txt; the
      file holds the whole buffer with its scrollback; a toast says "Saved to <path>".
- [ ] Copy with formatting: `printf '\e[31mred\e[0m plain'`, select it, ⌘C: the clipboard
      holds HTML as well as text; turned off in Settings › Terminal, text only.
- [ ] Word separators: a double-click on `/usr/local/bin:x` selects all of it; with " /" in
      Settings › Terminal › Word separators it selects `usr`.
- [ ] In a split: the pane menu offers "Rename pane"; a name shows as a label at the pane's
      top; "Show pane label" hides it. A single pane has no "Rename pane".
- [ ] Holding ⌃⇧ shows a label on every pane; letting go hides them. *Dragging a label onto
      another pane's side, an outer edge or the tab bar is a mouse drag: left to the owner.*
- [ ] Focus follows mouse (Settings › Window › Panes): moving the pointer over another pane
      focuses it.
- [ ] ⌘⌥⇧I (or the menus' "Broadcast Input to All Tabs"): a red border and the banner
      "Broadcast mode. Click anywhere to cancel."; what is typed reaches every tab; a click in
      a terminal ends it.
- [ ] *Dropping files from Finder on a pane types their quoted paths: a mouse drag, left to
      the owner.*
- [ ] OSC 1337: in a telnet tab, `printf '\033]1337;CurrentDir=/tmp\a'`, then "Save as
      profile": the new profile in config.yaml has `cwd: /tmp`.
- [ ] New terminal / New with profile ▸ (pane menu and tab menu): from a shell in a folder,
      the new tab opens in that folder; the submenu lists the local profiles.
- [ ] Save as profile: asks for a name; the new profile keeps the pane's folder; "Saved".
- [ ] Links: a plain click on an `ssh://` link opens a tab; with "Require a key to click
      links" set to ⌘, a plain click doesn't and a ⌘-click does. *Web, address and file links
      open other apps: left to the owner (unit tests cover what they resolve to).*
- [ ] ZMODEM: `sz` in the container asks "Accept a ZMODEM session?"; Accept, a save panel,
      the status lines (ZMODEM, Offered, %, Received, Complete) and a transfers row; the file
      matches. `rz` asks again, an open panel, "Sent"; the container has the file. Reject
      tells sz no. Ctrl-C during a big `sz` cancels the file.
- [ ] Settings › Terminal shows "Sixel graphics support (experimental)" (on by default).

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
| 2026-10-23 | M6 | The terminal touched the window edge; Tabby keeps a margin of `30 × spaciness − 15` px around it, in the terminal background. | `e2a50abc` |
| 2026-10-23 | M6 | A restored window showed its active first tab partly under the traffic lights; the strip only scrolled when the active tab changed. | `8c432b72` |
| 2026-10-23 | M6 | In a 706 pt window the Color scheme page was wider than the window and pushed the Settings sidebar off the left edge; the editor's labels broke mid-word. | `1190903d`, `50899592` |
| 2026-10-23 | M6 | The SSH chip showed the port with the locale's digit grouping (`:2.222` on a Mac set to Vietnamese). | `3180e9d2` |
| 2026-10-23 | M6 | The SSH chip sat at the pane's top left, over the first line, instead of the top right. | `147ac741` |
| 2026-10-23 | M6 | After the last tab closed, the start page ignored ↑ ↓ ↩. | `5006c3ea` |
| 2026-10-23 | M6 | At 706 pt the Config file header squeezed "Show defaults" into a column of letters and cut a YAML error to "Not…". | `3518434d` |
| 2026-10-23 | M6 | Quitting with a second, empty window lost every tab: AppKit closes the windows after the save on quit, and each close saved again; the empty one went last. | `13fc2e89` |
| 2026-10-23 | M6 | After ⌘F the first keys typed went nowhere: the search bar's host, not its field, was made first responder. | `3fcddedd` |
| 2026-10-23 | M6 | A background tab's password card covered the tab in front and took its keys; the OpenSSH presenter also used whichever window was key. Cards now open on the session's window with its tab in front. | `90214324` |
| 2026-10-23 | M6 | Follow-up to `8c432b72`: the deferred scroll could run during another view update, which SwiftUI traps (a test run crashed). | `e216b757` |
| 2026-10-23 | M7 | With Auto off, the other Mac's changes still arrived and local ones still went up: the 60 s poll ignored the setting. | `0e6552d3` |
| 2026-10-23 | M7 | Sync counts read "1 passwords · 1 keys". | `9f5010e2` |
| 2026-10-23 | M7 | A Mac removed from another Mac stayed signed in: with nothing to upload, the poll dropped the 401 from its "has the vault changed" request. | `37b8d43f` |
| 2026-10-23 | M7 | A Mac signing in with its own copy of a key already in the account was asked to upload it. | `1cf35b68` |
| 2026-10-23 | M7 | Regenerate… showed the sign-up step ("Step 2 of 2", "Start syncing"); View… put the key in a footer below the fold; their password cards did not say which password. | `b2d9f530` |
| 2026-10-23 | M7 | On the recovery card a key that no longer works said "The email or password is not right." | `aed87b85` |
| 2026-10-23 | M7 | Change password… took the new password once, so a typo left only the recovery key. | `71cd4725` |
| 2026-10-23 | M7 | At 706 pt the signed-out Account card put its title one word a line and cut "Create account". | `c99a7dca` |
| 2026-10-23 | M7 | After signing in again, the sign-out card said "0 keys" and then emptied `<config>/keys`. | `b74bfb47` |
| 2026-10-23 | M8 | The keyboard-interactive panel's field never had the keys: the pane made the panel's host first responder, and a new field after Continue or Back had no focus. | `28ab6e7c` |
| 2026-10-23 | M8 | A jump host failed with "Receiving banner: too large banner": a direct-tcpip channel's first bytes (the target sshd's banner) arrived with the open confirmation and went to a placeholder handler. | `0d0a4822` |
| 2026-10-23 | M8 | The chip's Ports button opened an empty bubble the first time: the popover was built before its model was set. | `2382074b` |
| 2026-10-23 | M8 | Remote forwards failed with "Global request tcpip-forward failed" once a keep-alive had gone out: libssh took the keep-alive's late refusal as tcpip-forward's answer and never sent it. | `a9b31c53` |
| 2026-10-23 | M8 | A background tab's forward toast brought that tab to the front; at restore it slid under another tab's password card. | `ec8b9228` |
| 2026-10-23 | M8 | With the pointer resting over the selector, the row that slid under it took the selection, and Return opened Quick connect instead of the profile. | `05742116` |
| 2026-10-23 | M8 | Double-clicking the SFTP breadcrumb showed the path field without the keys. | `ac5d6443` |
| 2026-10-23 | M8 | Edit locally never uploaded a change written into the file in place (shell, editors that overwrite); only the folder was watched. | `a0ace81c` |
| 2026-10-23 | M8 | config.yaml edited by hand while the app ran was overwritten at quit, though nothing had changed in the app. | `53c4c4b5` |
| 2026-10-23 | M9 | A new telnet tab to busybox showed extra prompts: the pane sent the same window size more than once and the shell redraws on every NAWS. | `e916c03f` |
| 2026-10-23 | M9 | A telnet profile made with New → Telnet (local echo, Tabby's default) showed every key twice against a shell that echoes. Local echo now stands aside while the server echoes. | `cc2b1be2` |
| 2026-10-23 | M9b | The selector panel was 32 pt taller than its content, an empty band above the search field (the title bar's height, added by the hosting view). | `0008aee6` |
| 2026-10-23 | M9b | Closing a split tab with two panes on one host, or quitting, listed "Disconnect from 127.0.0.1?" twice. | `af98c0f9` |
| 2026-10-23 | M9b | The New menu on Settings › Profiles showed no type icons (design C7). | `847c06fb` |
| 2026-10-24 | M10 | After a live language switch, the settings sidebar, the path rows and the Settings tab's title kept the old language until clicked (views that read no observed state are not redrawn). | `fe0b0989` |
| 2026-10-24 | M10 | With the pointer resting on a tab, the tab menu lacked "Notify when done" for a process started since: SwiftUI built the menu at the header's last redraw. It is now built when it opens; its "…" form drops below the button. | `fe0b0989`, `20c007ac` |
| 2026-10-24 | M10 | `tabby run` ran in the active tab's folder instead of the caller's; so did every local profile with its own directory. | `fe0b0989` |

Open: the M5 notification item, blocked by macOS on the test Mac (see the item).
