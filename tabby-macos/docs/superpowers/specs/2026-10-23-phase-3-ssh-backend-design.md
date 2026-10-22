# Phase 3 design: SSH library backend (libssh), SFTP, live port forwards

Written 2026-10-23 from the owner's decisions, a survey of the current SSH stack and a
catalogue of Electron Tabby's SSH plugin (`../tabby-ssh/src`). The Claude Design canvases
draw the SSH status chip (with SFTP and Ports buttons), the host-key sheet, the
keyboard-interactive panel (`sshAuth`), the transfers popover and the "Test connection"
button. They have no SFTP browser or port-forward editor, so this document defines those
layouts.

## Context

Phase 1 runs `/usr/bin/ssh` in a PTY with a generated `ssh_config` and answers its prompts
through `tabby-askpass`. That supports every ssh feature with little code, but it has no
channel API. Tabby's SFTP panel, its live port-forward editor and its inline
keyboard-interactive panel all need channels, so phase 3 adds an in-process SSH client.

Owner decisions (2026-10-23):
- **Library:** libssh (C, LGPL 2.1, linked dynamically and bundled in the app).
- **Fallback:** the OpenSSH backend stays, selected by `ssh.backend: openssh` in config.yaml
  (no UI). The library backend is the default.
- **Scope:** SFTP panel; live port forwards; keyboard-interactive panel; agent forwarding;
  X11; transfers popover; SFTP "Edit locally" and folder download; "Test connection" in the
  profile editor.

## Architecture

| Piece | Where | Platforms |
|---|---|---|
| Auth plan, forward model + descriptions, SOCKS5 and HTTP CONNECT handshakes, X11 display parsing, SFTP path / sort / filter / mode string, transfer progress maths | `TabbyCore/SSH/` (Foundation only) | macOS, Linux |
| `CLibSSH` system library (`module.modulemap`, `pkgConfig: "libssh"`) | `Sources/CLibSSH` | macOS (Homebrew `libssh`) |
| `SSHConnection` (one libssh session on its own queue), `LibSSHSession: TerminalSession`, `SSHMultiplexer`, forwards runtime, `SFTPClient`, X11 and agent channels | `TabbyApp`-facing target `TabbySSHLib` | macOS |
| Prompts, keyboard-interactive panel, Ports popover, SFTP panel, transfers popover, Test connection | `TabbyApp` | macOS |

- `TabbyAccount` does not depend on `TabbySSHLib`, so the sync server and the Linux CI jobs
  never build or link libssh.
- `SSHSessionFactory` picks the backend per profile from `ssh.backend` (global) or
  `options.backend` (per profile), both `library` (default) or `openssh`.
- The app bundle carries `libssh.4.dylib` and its OpenSSL libraries in
  `Contents/Frameworks`. `scripts/bundle-libssh.sh` runs as an Xcode build phase: it copies
  them from Homebrew, rewrites install names to `@rpath`, and ad-hoc signs them. The app
  runs on a Mac without Homebrew.

### Threading

- Each `SSHConnection` owns its `ssh_session` and makes every libssh call on its own serial
  queue (blocking mode, short timeouts).
- A poll loop on that queue reads the shell channels, forward channels, X11 and agent
  channels with `ssh_channel_select`/`ssh_channel_poll_timeout`.
- Results reach the UI through the existing `TerminalSession` callbacks, which run on the
  main queue.
- Nothing blocks the main thread. Today's 2 s `ssh -O check` probe and the 600 s askpass
  threads go away on this backend.

### Session sharing (replaces ControlMaster)

When `reuseSession` is on (the default), `SSHMultiplexer` keys connections like Tabby does:
`host:port:user:proxyCommand:socksHost:socksPort:httpHost:httpPort`, plus `$<jumpKey>` for
jump hosts. Connections are reference-counted. A second tab on the same key opens a new shell
channel, and the connection closes when its last channel does.

## Connection and authentication

**Transport priority** (Tabby): proxy command, then jump host, then SOCKS, then HTTP CONNECT,
then direct TCP.
- **Proxy command:** `SSH_OPTIONS_PROXYCOMMAND`. libssh expands `%h` and `%p`; Tabby did
  not.
- **Jump host:** the jump profile's connection, through the multiplexer, opens a
  `direct-tcpip` channel to `host:port`, bridged over a socketpair handed to libssh as
  `SSH_OPTIONS_FD`. Jump chains recurse; a loop is an error, as today.
- **SOCKS5 / HTTP CONNECT:** handshake in Swift on a connected socket, then
  `SSH_OPTIONS_FD`. Ports default to 1080 / 8080.

**Options:**
- `keepaliveInterval` (ms, rounded to seconds) and `keepaliveCountMax`.
- `readyTimeout` → `SSH_OPTIONS_TIMEOUT`.
- `algorithms` lists are sent as given, not re-sorted: Tabby sorts them alphabetically,
  which reorders preference.
- `skipBanner` hides the issue banner.
- `term` (empty means `xterm-256color`).

**Host keys:**
- `SSH_OPTIONS_KNOWNHOSTS` is the app's `<config>/known_hosts` (already synced line by line).
  `SSH_OPTIONS_GLOBAL_KNOWNHOSTS` is `~/.ssh/known_hosts`, read only.
- Unknown key: the host-key card with "Remember in known_hosts" (design `ssh` screen).
  Accept + remember writes the line; accept alone allows this connection only.
- Changed key: the same card with Tabby's warning ("Warning: remote host's key has suddenly
  changed!" and "You could be under a man-in-the-middle attack…") and the last known
  fingerprint.
- `ssh.verifyHostKeys: false` accepts any key.
- The terminal always shows `Host key fingerprint:` with the algorithm and the SHA256
  fingerprint.

**Auth plan** (Tabby's `ssh.ts` order; pure and unit-tested in TabbyCore):
1. `none`
2. `agent`: first one entry per configured key that has a `.pub` next to it (agent
   identity), then all agent keys
3. `publickey`: one entry per `privateKeys` entry (`%h`/`%r` substituted). When the profile
   names none, `~/.ssh/id_*` without `.pub`. Synced copies come from `SyncedKeys.resolve`.
4. saved password (the profile's `password`, then the Keychain)
5. `keyboard-interactive` with the saved password filled into password-like prompts
6. plain `keyboard-interactive`
7. password prompt

**Narrowing the plan:**
- Each step is skipped unless the server's `userauth_list` allows its method.
- `partialSuccess` replaces the allowed list and adds a fresh keyboard-interactive round
  (2FA).
- `auth` set to `password`, `publicKey`, `agent` or `keyboardInteractive` restricts the plan
  to that family plus `none`.
- An empty user prompts "Username for <host>". `$VAR` usernames expand from the
  environment.

**Fixes to Tabby quirks:**
- A failed auth does not retry the whole connection without sharing (Tabby prompts twice).
- Only the saved password that was rejected is deleted, not every stored password.
- `hostbased` is dropped.
- Passwords and passphrases are saved only after authentication succeeds, as phase 1 does.

**Private keys:**
- Imported with `ssh_pki_import_privkey_file`.
- Encrypted keys use the saved passphrase (`ssh-private-key:<sha512>`) first. If that is
  rejected, the passphrase card appears with Remember.
- A public key file named as a private key is skipped, with Tabby's message.

**Agent and forwarding:**
- The agent is `ssh.agentPath` or `SSH_AUTH_SOCK`, which must be a Unix socket, with Tabby's
  warnings otherwise.
- With `agentForward`, the shell channel requests agent forwarding and incoming
  `auth-agent@openssh.com` channels are bridged to the agent socket.

**X11:**
- `x11` requests `MIT-MAGIC-COOKIE-1` with a random cookie on screen 0.
- Incoming X11 channels connect to `ssh.x11Display`, else `$DISPLAY`, else `localhost:0`,
  parsed like Tabby: `[host]:N[.S]` → TCP 6000+N; `unix` or empty host →
  `/tmp/.X11-unix/XN`; a leading `/` → a socket path.
- Errors use Tabby's text.

**Messages:** service lines use the cyan ` SSH ` badge and Tabby's text:
- "Connecting to <profile name>"
- "Using saved password"
- "Trying private key: <name>"
- "Host key fingerprint:"
- "<host>: session closed"
- red ` X ` errors such as "Authentication rejected"
- "Press any key to reconnect"
- "Keyboard-interactive auth requested: <name>"

### Session behaviour kept from phase 1

- `behaviorOnSessionEnd`, reconnect with backoff (1, 2, 4, 8, 16 s, at most 5 attempts),
  `warnOnClose`, and login scripts (`LoginScriptRunner`).
- `cwd` via a leading-space `cd -- '<dir>'`.
- Recovery token `app:ssh-tab`.
- New: `rememberCwd` works, because `workingDirectory()` returns the OSC 7 directory.
  `input.backspace` (`backspace` / `ctrl-h` / `ctrl-?` / `delete`) is added to `SSHOptions`
  and applied in `TerminalPane.send`.

## Keyboard-interactive panel (design `sshAuth`)

- A strip docked at the top of the pane that pushes the terminal down; the PTY is resized.
- Styling: `surfaceChrome` background with a 2 pt `accent` bottom edge.
- Header: lock icon, the host, then "keyboard-interactive · prompt n of m".
- Body: the instruction, kept as written, with URLs as links; the prompt label; one field,
  secure when `echo` is false, monospaced, 28 pt.
- A Remember switch, shown only for password-like prompts (the text contains "password"
  and `echo` is false); it saves to the Keychain after success.
- Buttons: Cancel (disconnects; Tabby has none) and Continue ↩. Back appears on prompt 2
  and later.
- Password-like prompts are pre-filled from the saved password, but the panel still waits
  for Continue (as Tabby does). A round with no prompts is answered without UI.

## Port forwards

- **Model** (TabbyCore): `ForwardedPort` from the profile (`type` Local / Remote / Dynamic,
  `host` default `127.0.0.1`, `port`, `targetAddress`, `targetPort`, `description`).
  `description` reads like Tabby: `(local) h:p → (remote) ta:tp`, `(remote) h:p → (local)
  ta:tp`, `(dynamic) h:p`.
- **Local:** a listening socket on the connection queue; each accept opens `direct-tcpip`
  to the target.
- **Dynamic:** a no-auth SOCKS5 server (CONNECT only) whose target comes from the request.
- **Remote:** `ssh_channel_listen_forward`, then accepted channels are matched on bound port
  and connect to `targetAddress:targetPort` here. Unmatched ones are refused with Tabby's
  message.
- Profile forwards start after authentication. A failure never ends the session; it shows
  the toast "Failed to forward port <description>".
- **Ports popover** (chip "Ports" button, enabled when connected; 420 pt wide):
  - Rows: type badge, `host:port → target:port` (or "SOCKS proxy"), description, and a
    status dot (listening / failed, with the error on hover).
  - × on hover stops the forward and puts it back in the form, which is how Tabby edits.
  - Form "Add a port forward": Local / Remote / Dynamic segment, `host : port →
    targetAddress : targetPort` (the target replaced by "SOCKS proxy" for Dynamic),
    Description, and the "Forward port" button. Initial values are Local `127.0.0.1:8000 →
    127.0.0.1:80`.
  - Toasts: "Forwarded …", "Failed to forward port …", "Stopped forwarding …".
- Live changes apply to this connection only. The profile editor's Ports page edits the
  saved list, and its footer says so.

## SFTP panel

- **Opening:** from the chip's "SFTP" button, the `open-sftp` hotkey (now handled), or the
  tab context menu "Open SFTP panel". It needs a connected library-backend session.
- **Layout:** slides up over the bottom 80 % of the pane in 100 ms, on a `surfaceRaised`
  sheet with a 1 pt `border`. A click in the terminal or × closes it.
- **Start path:** the pane's OSC 7 directory, else the last panel path, else `/`.
- **Header** (38 pt):
  - Breadcrumb: a bold root "SFTP" (goes to `/`) and one button per path component.
    Double-clicking the breadcrumb turns it into a path field: ↩ goes there, Esc cancels.
  - Buttons: Refresh, Filter, Create directory, Upload files, Upload folder, ×.
- **Filter:** a field with placeholder "Filter…". Esc clears it, and it resets on
  navigation. With no matches: "No files match the filter “…”".
- **List** (`selectorRow` height):
  - A "Go up" row (except at `/` or while filtering).
  - Columns: icon by type, name, size (files only), modified, and the mode as
    `SGdrwxrwxrwx` in Menlo 12 (S and G are setuid and setgid).
  - Directories first, then by name with `localizedStandardCompare`.
  - Status lines: "Connecting", "Loading".
- **Click:** a directory opens; a symlink is resolved (`readlink` + `stat`) and then opened
  or downloaded; a file is downloaded through a save panel.
- **Drop from Finder:** files and folders upload recursively into the current folder, with
  an `accentFill` drop hint.
- **Context menu:**
  - Copy full path.
  - Edit locally (files): download to a temp folder, open it with the default app, watch it
    (1 s debounce), re-upload on change and keep the original mode.
  - Create directory.
  - Download directory (directories): pick a folder with "Download here"; on a name clash
    the copy is `name (1)`.
  - Download (files).
  - Delete: asks "Delete <path>?", then a progress sheet with Cancel. It is recursive, and
    every unlink is awaited (Tabby's isn't).
- **Create directory** asks "Name for the new directory" (Create / Cancel), then opens the
  new folder.
- **Upload:** writes `<path>.tabby-upload`, then removes the old file and renames the upload
  over it. A failed upload removes its temp file.
- **Transfers:** reads use 256 KiB chunks, and every transfer goes to `TransferCenter`.

## Transfers popover

- **Button:** `arrow.up.arrow.down` in the tab bar toolbar with a count badge. It is hidden
  when there are no transfers and opens by itself on the first one.
- **Popover:**
  - Header: "Transfers" and "Clear finished". When transfers are still running it asks
    "There are active file transfers" with Abort all / Do not abort.
  - Rows: direction icon, name, %, "To <host>" / "From <host>", completed of total, speed /
    s, and status.
  - × cancels a transfer. A finished one shows a folder action that reveals it in Finder,
    and a click on the row does the same.

## Test connection

- The profile editor's General page (SSH) has "Test connection" with a bolt icon.
- It connects and authenticates with the editor's unsaved values, opens no shell, and
  allows prompts.
- The result shows inline: "Connected as <user> · <key type> <SHA256 fingerprint>" or the
  error.

## Settings

- **Settings › SSH** adds:
  - "SSH agent": System (`SSH_AUTH_SOCK`) or a custom socket path → `ssh.agentPath`.
  - "X11 display" → `ssh.x11Display`.
- **Profile editor:**
  - Advanced adds keep-alive count, ready timeout and Backspace.
  - A new "Ciphers" page holds the algorithm lists as token fields, with defaults.
- `ssh.backend` is documented in `defaults.yaml` only.

## Tests

- **Pure logic** (Linux and macOS) in `TabbyCoreTests`:
  - the auth plan, ported from `authMethodSelection.test.ts` cases;
  - forward descriptions, SOCKS5 / HTTP CONNECT handshakes and X11 display parsing;
  - SFTP path / sort / filter / mode string, and transfer speed and progress.
- **Integration** (macOS) in `TabbySSHLibTests` against a test sshd started by the tests:
  - `/usr/sbin/sshd -D -f <temp config>` on a free port, with a temp host key, a test
    `authorized_keys`, password authentication through a test user only when
    `TABBYMAC_SSH_TEST_*` is set, and `Subsystem sftp /usr/libexec/sftp-server`;
  - public key, agent (a temp `ssh-agent`), shell I/O, resize, local / remote / dynamic
    forwards against a local echo server, SFTP operations, and jump through a second sshd.
- **Isolation:** tests never read the real `~/.ssh`, Keychain or known_hosts. Every path is
  injected.
- **CI:** the macOS job runs `brew install libssh` and the integration tests.
- **Manual:** keyboard-interactive (PAM on macOS) and the UI are covered by a fake connection
  in unit tests and by **M8** in MANUAL-CHECKS. M4 is re-walked on the library backend, and
  once with `ssh.backend: openssh`.

## Not in phase 3

- WinSCP, Windows agent types, `ssh://` URLs.
- Writing hashed known_hosts entries (reading them works).
- SFTP multi-select, rename and chmod dialogs.
- Certificates UI: certificate files named in `privateKeys` are passed to libssh as they
  are.
