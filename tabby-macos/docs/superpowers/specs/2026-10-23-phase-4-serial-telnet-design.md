# Phase 4 design: serial and telnet

## Context

Phases 1–3 are merged to `master`. Phase 4 adds the two remaining Tabby connection types,
**serial** and **telnet**, ported from `../tabby-serial/src` and `../tabby-telnet/src`. The
goal is that an Electron Tabby `config.yaml` with serial and telnet profiles opens and runs
unchanged, so the port keeps Tabby's:

- profile types `serial` and `telnet`, and every option key;
- recovery token types `app:serial-tab` and `app:telnet-tab`;
- hotkey ids `serial`, `restart-serial-session` and `restart-telnet-session`.

Owner decisions (2026-10-23):
- Both types, as the roadmap says.
- There is no serial hardware here. Serial is tested on `openpty` pairs, and the real-port
  walk is left to the owner.
- The owner designs the new screens in Claude Design first. Until those arrive, the UI uses
  the existing components. 4.5 applies the designs, and the UI section below gets updated
  then.

Places where this port deliberately differs from Tabby are marked ★.

## Architecture

| Piece | Target | Why there |
|---|---|---|
| `SerialOptions`, `TelnetOptions`, `BaudRates` | TabbyCore | Typed views over `options`, tested on Linux |
| `SerialProfileProvider`, `TelnetProfileProvider` | TabbyCore | Builtins, defaults, quick connect |
| `StreamProcessor`, `LineEditor`, `Hexdump`, `NewlineMode` | TabbyCore | Pure byte transforms |
| `TelnetProtocol` | TabbyCore | IAC state machine: `feed(Data) -> (terminal, peer)` |
| `ServiceMessage` | TabbyCore | ` SSH ` / ` Serial ` / ` Telnet ` badges and ` X ` errors |
| `ProcessedSession` | TabbyTerminal | Wraps a raw session with a `StreamProcessor` |
| `TelnetSession` + factory | TabbyTelnet (new, macOS) | `Network.framework` socket |
| `SerialPort`, `SerialPortList`, `SerialSession` + factory | TabbySerial (new, macOS) | termios, IOKit |
| `freePort`, `EchoServer`, `ScriptedTCPServer`, `PTYPair` | TabbyTestSupport (new, test helpers) | Shared by several test targets |

`TabbyApp` depends on both new targets. Neither needs bundling: they link only system
frameworks. The two factories are registered under `serial` and `telnet` in
`AppServices.factories`. Profile providers, recovery tokens, quick connect and the selector
are already keyed by the type string, so nothing else needs registering.

## Stream processing (shared by serial and telnet)

This is a port of `tabby-terminal/src/middleware/streamProcessing.ts`. `ProcessedSession`
sits between the pane and a raw serial or telnet session. SSH and local sessions don't use
it.

**Modes**
- Input: `nil` (Normal), `local-echo`, `readline`, `readline-hex`.
- Output: `nil` (Normal), `hex`.
- Newlines, for `inputNewlines` and `outputNewlines`: `nil` (Keep), `strip`, `cr`, `lf`,
  `crlf`, `implicit_cr`, `implicit_lf`.

**Newline translation** uses Tabby's `replaceNewlines` table:

| Mode | Effect |
|---|---|
| `implicit_cr` | every `\n` becomes `\r\n` |
| `implicit_lf` | every `\r` becomes `\r\n` |
| `strip`, `cr`, `lf`, `crlf` | `\r\n` and lone `\r` are first normalised to `\n`, then `\n` becomes ``, `\r`, `\n` or `\r\n` |

★ A `\r` at the end of a chunk is remembered, and an `\n` starting the next chunk is then
skipped, so a CRLF split across reads counts as one newline (output only; typed input keeps
no such state).

**Output path:** session → newline translation → hexdump (if `hex`) → login scripts →
terminal.
- In readline modes, a visible prompt is erased (`\e[2K\r`) before output is shown.

**Input path:** keys → local echo (`local-echo`, or when telnet asked for it) → line editor
(readline modes) → hex decoding (`readline-hex`) → input newline translation → session.
- Local echo applies `crlf` translation to what it echoes, like Tabby.
- ★ "Local echo" stands aside while a telnet peer echoes (`WILL ECHO`). Tabby's telnet
  default is local echo, so against a shell every key showed twice. Raw sockets keep it.

**Line editor** (★ replaces Node's `readline`):
- The prompt is `> `, or `hex> ` in `readline-hex`.
- Printable keys are inserted and echoed; Backspace and DEL erase; ^U clears the line.
- ★ ^C clears the line and never closes input.
- Return sends `line + "\n"`.
- The prompt reappears 500 ms after the last output, and right after a line is sent.
- `readline-hex` splits the line on whitespace, accepts an optional `0x` prefix, and sends
  the bytes. A bad token prints ` X Invalid hex: <token>` ★ (Tabby throws silently).

**Hexdump:** a fixed layout frozen by a test, one dump per chunk like Tabby.
- Each line holds a 4-digit hex offset, 16 one-byte columns, a dim `｜` gutter, and the
  printable ASCII.
- Cells after the end of the chunk are dim `╳`.

**Login scripts:** they run on the processed output, as in Tabby, where they sit at the
terminal end of the middleware stack. ★ `LoginScriptRunner` is now built for every profile
type from `options.scripts`, not just SSH. Local shells get login scripts as a result.

## Service messages and session end

**Shared helper.** `ServiceMessage.line(badge:text:)` writes
`\e[0;30;<bg>m <badge> \e[0m <text>\r\n`:
- SSH keeps its cyan background (46).
- Serial and Telnet use white (47), as Tabby does.
- `ServiceMessage.error(text)` writes ` X ` in black on red, then the text in the
  terminal's colour (design C9; Tabby's sessions write `colors.bgRed.black(' X ')`). A
  session that cannot start prints the same line.
- Both SSH backends switch to the helper; their error lines change with it (C9).

**Messages**

| Type | Messages |
|---|---|
| Serial | "Port opened"; "Port closed" (the device went away or hung up); on end "<device>: session closed" |
| Telnet | "Connecting to <host>"; "Connected"; "Connection closed" (the peer closed); on end "<host>: session closed"; errors `` ` X ` Socket error: <message> `` |

★ The end line uses the same badge as the other lines (Tabby prints it with an uppercase
` SERIAL ` / ` TELNET ` badge), the way TabbyMac's SSH says "<host>: session closed".

**`clearServiceMessagesOnConnect`** is now implemented. When it is set, the pane clears the
terminal on `.connected`, as Tabby's `ConnectableTerminalTabComponent` does.
- Defaults per type: `ssh` true (Tabby's), `serial` false, `telnet` false.
- `Profile` gains a per-type default, so a missing key reads as that type's default, and
  the key is written only when it differs from that default.
- The editor's common block shows the toggle "Clear terminal after connection" for every
  connection type.

**Session end with `.auto`** uses Tabby's rule:
- Serial and telnet sessions are "explicitly terminated" when the last input ends with
  `close\r` or `quit\r`.
- Otherwise the pane prints "Session closed. Press any key to reconnect." (C9; a local
  shell still says "restart") and any key reconnects.
- `.reconnect` uses the existing backoff (Tabby retries immediately).

**Close warning.**
- Telnet asks "Disconnect from <host>?" while connected, as Tabby's `canClose` does.
- Serial doesn't ask (Tabby doesn't).
- SSH keeps `ssh.warnOnClose`.

## Telnet

**Connecting.**
- `TelnetSession` opens an `NWConnection` to `host:port`. The port defaults to 23; there are
  no proxies and no TLS, as in Tabby.
- ★ The connect has a 30 s timeout (Tabby has none).
- ★ IPv6 literals work in quick connect, and `[::1]:2323` round-trips.

**Templates.**
- "Telnet session" (`telnet:template`): port 23, `readline`, output newlines `crlf`.
- "Raw socket connection" (`socket:template`): port 1234, `local-echo`, `crlf`.
- Both have type `telnet`; the provider's `configDefaults` are Tabby's (input `local-echo`,
  output newlines `crlf`).

**Telnet mode.**
- It switches on the first time a received chunk starts with IAC (0xFF) while the mode is
  still off. That is Tabby's rule, so a server that sends a banner before negotiating still
  works, and a raw TCP peer never sees negotiation.
- On switching on, the session sends DO SGA, WILL TTYPE and WILL NAWS, and it remembers what
  it asked for.

**Replies** (Tabby's table):

| Received | Reply |
|---|---|
| WILL SGA | DO SGA |
| WILL ECHO | DO ECHO; the server echoes, so local echo turns off |
| WILL other | DONT |
| DO NAWS | WILL NAWS, then the size |
| DO TTYPE | WILL TTYPE |
| DO ECHO | WILL ECHO and local echo on (or WONT when the server echoes) |
| DO other | WONT |
| DONT, WONT | the matching negative reply, ECHO state updated as Tabby does |
| Answer to an option we asked for | no reply |
| SB TTYPE SEND | `IAC SB TTYPE IS "XTERM-256COLOR" IAC SE` |

**Window size.** NAWS is `IAC SB NAWS w h IAC SE`. It is sent on every resize once known, and
`WONT NAWS` is sent when the size is unknown.

★ **Protocol fixes against Tabby:**
- IAC sequences are parsed anywhere in the stream, and the state carries across chunks.
- Two-byte commands (NOP, GA, …) consume two bytes.
- `IAC IAC` delivers one 0xFF to the terminal (Tabby's `UnescapeFF` doubles it).
- Outgoing 0xFF is doubled while in telnet mode.
- 0xFF bytes inside NAWS values are escaped.

## Serial

**Port list.** `SerialPortList` enumerates IOKit `IOSerialBSDClient` services.
- Each port has its callout path (`/dev/cu.*`) and Tabby's description from the USB ancestor:
  the vendor name and the serial number, when there are any.
- Hot-plug works through `IOServiceAddMatchingNotification`, for both first-match and
  terminated notifications.
- Internal ports (`cu.debug-console`, `cu.Bluetooth-Incoming-Port`) are listed last and get
  no builtin profile.
- Tests inject a fake registry. The app never opens a port it only lists.

**Builtins.**
- `serial:template` "Serial connection".
- One profile per external port: `serial:port-<slug>`, named "Serial: <description>".
  ★ When a port has no description, the name is "Serial: <device basename>" (Tabby uses
  "Serial", which makes ports indistinguishable).
- The list refreshes when a port appears or goes away.

**Options and defaults** (Tabby's):

| Key | Default |
|---|---|
| `port` | `null` |
| `baudrate` | `null`: ask every time |
| `databits` | 8 |
| `stopbits` | 1 |
| `parity` | `none` |
| `rtscts`, `xon`, `xoff`, `xany`, `slowSend` | false |
| `inputMode`, `outputMode`, `inputNewlines`, `outputNewlines` | null |
| `scripts` | [] |
| `input.backspace` | `backspace` |

- Standard rates: 110, 150, 300, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200,
  230400, 460800, 921600, 1500000.
- Parity is None, Even or Odd (Mark and Space are Windows-only in Tabby).

**Opening a tab** (in `WindowModel` before the pane is made; Tabby does this in
`getNewTabParameters`):
1. ★ With no `port`, a **serial port selector** opens: one row per port, with the
   description as subtitle; a typed path (`/dev/…`, `~/…`) is offered too, so the selector
   also works when no port is listed. Tabby silently takes the first port and crashes when
   there is none.
2. With `baudrate` null, the **baud rate selector** opens: standard rates with 115200
   preselected. ★ A typed number offers `Use custom rate "<n>"`.
3. Cancelling either selector opens no tab.
4. The chosen values go on the pane's copy of the profile and into its recovery token,
   never into config. Restoring never prompts.

**`SerialPort`.**
- Opens with `open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)`, then takes the port exclusively
  with `ioctl(TIOCEXCL)`, so another program's open fails. Ports open in this process are
  also tracked, so a second tab on the same port fails with "<path> is busy: another program
  has it open" (ptys ignore `TIOCEXCL`, which is how the tests see this).
- A port that can't open shows the error and ends the session right after `start`, so the
  pane offers to try again.
- Puts the port in raw mode (`cfmakeraw`) and sets `CLOCAL | CREAD`.
- Applies data bits, stop bits (1.5 maps to 2, as on POSIX), parity, `CRTSCTS` for RTS/CTS,
  `IXON`/`IXOFF`/`IXANY`.
- Standard rates use `cfsetspeed`. Rates termios lacks (460800 and up, or custom rates) use
  the `IOSSIOSPEED` ioctl.
- A `DispatchSource` reads the port. A read of 0 or `ENXIO` means hang-up or unplug, which
  prints "Port closed" and ends the session.
- "Change baud rate" applies live, and the pane's profile copy is updated.
- `slowSend` writes one byte per `write` call (Tabby adds no delay).

**Errors** are printed with the ` X ` helper: "Cannot open <path>: <reason>", "<path> is
busy: another program has it open", "Unsupported baud rate <n>", "No serial port selected".

**Hotkeys** (defaults in `defaults.yaml`, catalog entries for the Hotkeys page):
- `serial` (Alt-K) opens the serial selector: saved serial profiles plus the detected ports.
- `restart-serial-session` and `restart-telnet-session` restart the pane, like
  `restart-ssh-session`.

**Quick connect** (Tabby's parsing):
- Serial: `path[@baud]` or `path:baud`, with 115200 when no rate is given.
- Telnet: `host[:port]` or `[v6]:port`, with 23 when no port is given; it uses the template's
  `readline` and `crlf`.
- Both appear in the selector's quick-connect rows, and in Settings › Profiles › "Quick
  connect uses".

## UI (from the owner's Claude Design canvas "Tabby Connections", C1–C10)

Built only from the existing tokens and components. ★ marks a choice the canvas leaves open
or a deviation from it.

- **Type icons.** Serial `cable.connector` (Tabby's `fa-microchip`; `memorychip` read as
  RAM), Telnet `network`, SSH `server.rack` (also for the SSH template). Profiles keep
  Tabby's Font Awesome names; the mapping is in `ProfileIcons`. A tab whose profile has no
  icon shows its type's icon.
- **Connection chip (C1).** Unchanged size, dot colours and buttons. Serial
  `<device> · <baud>` with "Baud rate" where SSH has Ports (`textFaint` and disabled unless
  connected; shown pressed while its popover is open); Telnet `host:port` with Reconnect only.
- **Pane labels (C1b).** In a split, each pane shows `n · title` at its top-right (`fill`,
  radius 5, 11 pt `textMuted`); the chip takes its place while the chip is visible, and a
  local pane's label hides while the pointer is over it (★ review: it covered the end of the
  first row). Single panes show none. ★ no setting.
- **Baud-rate popover (C2).** 320 pt, from the chip: "Baud rate" + device, the standard
  rates with the one in use checked and marked "In use", a Custom numeric field, keycaps
  ↩ apply / esc close. A rate applies on click; ↩ applies the custom field. A failure shows
  the toast "Could not change the baud rate" with the error.
- **Baud-rate selector (C3).** Placeholder "Baud rate", 115200 selected and in view, a
  non-standard number offers `Use custom rate “250000”` (pencil).
- **Serial-port selector (C4).** Placeholder "Serial port or a device path"; "Ports" rows
  (device name, description or path) then "Built in" rows dimmed; a typed path offers
  `Use <path>` first; empty state "No ports found" / "Connect a device, or type its path".
- **Show Serial connections (C5, ⌥K).** "Saved profiles", then the template "Serial
  connection" ("Asks for the port and baud rate", `plus`, no header), then "Ports"
  (`Serial: <description>`, path). A typed `path@rate` puts "Quick connect" first
  ("<path> at <rate> baud"). Footer hint `⌥K serial`.
- **Profile editor (C6, C7).** Header tile 40 × 40, the profile colour at 20 % behind the
  icon (all types ★). "Clear terminal after connection" — "Removes the connection messages
  once connected". Serial General: Device (Menlo field, "Ask every time" ★ where the canvas
  says "Automatic", menu of ports then built-in ports), Baud rate ("Ask every time", menu),
  footer "Without a device or a baud rate, Tabby asks each time the profile opens.", then
  Stream processing. Serial Advanced: Data bits / Stop bits / Parity as segments, RTS / CTS,
  XON, XOFF, Xany, Slow feed, Backspace sends, Ignore titles. Telnet General: Host filling
  the row with an inline Port (placeholder 23), Stream processing; Advanced: Backspace sends,
  Ignore titles. Stream-processing pickers keep Tabby's names and subtitles (the subtitle
  sits beside the picker ★).
- **Profile lists (C7, C8).** New menu: Local terminal, SSH connection, Serial connection,
  Telnet connection. Badges "Serial" / "Telnet". A serial profile's description is
  `<path> · <baud>`, `<path>`, or "Ask every time" (tree, start page, selectors ★ one rule).
  ⌘E quick-connect rows read "Quick connect · <type title>" with the type icon and the query
  as subtitle.
- **Terminal messages (C9).** Badges black on white (SSH keeps cyan); errors start with
  ` X ` black on red, then the text in the default colour. The hexdump offset, `｜` and `╳`
  are bright black. Connection tabs end with "Session closed. Press any key to reconnect."
- **Close warnings (C10).** "Close this tab?" with Cancel / Close (destructive, no ↩ ★ for
  every destructive confirm); "Quit TabbyMac?" with Quit as the default button.

## Tests

- **TabbyCore** (Linux and macOS): every stream mode against the newline table, split CRLF,
  line editor keys and prompt timing (injected clock), hex decoding, frozen hexdump, telnet
  replies, NAWS escaping, IAC across chunks, quick connect both ways, providers and
  builtins, and the per-type `clearServiceMessagesOnConnect` default.
- **TabbyTelnet** against an in-process scripted TCP server:
  - the negotiation transcript and NAWS on resize;
  - a raw echo round-trip;
  - refused connection and peer close.
- **TabbySerial** against `openpty` pairs: open, read and write both ways, termios read
  back, exclusive open, hang-up when the other end closes, `slowSend`, live baud change.
  - The baud rate on a pty is asserted only where the pty accepts it.
  - No test opens a real `/dev/cu.*`.
- **TabbyApp:** factory wiring, recovery round trip, the `.auto` end rule, close warning,
  selector flows, editor pages, chip label per type, snapshots.
- **Manual checklist M9:**
  - serial against a fake device on a pty;
  - telnet against a throwaway Docker `busybox telnetd` and `nc -l`.
  - Real USB-serial hardware and real telnet devices are left to the owner.

## Not in phase 4

- `tabby://` and `ssh://` URLs, the CLI, localization, "notify when done".
- Tabby's web serial profile.
- Telnet over TLS or through proxies.
- Bluetooth pairing.
- Windows-only parity modes.
