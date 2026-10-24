# Phase 5 design: localization, notify when done, links and the CLI

## Context

Phases 1–4 are merged to `master`. Phase 5 is the roadmap's "More of Tabby" step. It
ports three things from the Electron app in `../`:

- **localization**, using Tabby's own catalogs in `../locale/*.po`;
- the per-tab **"Notify when done"** and **"Notify on activity"** items, plus the bell's
  Dock flash;
- the **command line** (`tabby open`, `run`, `profile`, `paste`, `recent`,
  `quickConnect`) and **links** that open connections.

Owner decisions (2026-10-24):
- Links: `ssh://` and `telnet://` open a quick-connect tab. TabbyMac does not claim
  `tabby://`, which stays with the Electron app. `tabbymac://`, already in `Info.plist`,
  is how the command-line helper hands a request to the app.
- Languages: Tabby's 24, plus Vietnamese written for this port.
- The bundle id stays `com.example.tabbymac`.

Places where this port deliberately differs from Tabby are marked ★.

## Localization

### Catalogs

Tabby's catalogs are gettext `.po` files whose `msgid` is the English text, with
`{name}` placeholders (ICU style, no plural forms are used). TabbyMac reads them as they
are:

| Folder (under `Sources/TabbyCore/Resources/locale/`) | Content |
|---|---|
| `tabby/<code>.po` | Copies of `../locale/<code>.po`, refreshed by `scripts/sync-locale.sh` |
| `tabbymac/tabbymac.pot` | TabbyMac's own strings (not in Tabby's catalogs), written by `scripts/l10n-extract.swift` |
| `tabbymac/<code>.po` | Translations of TabbyMac's strings; this phase ships `vi-VN.po` |

A string is looked up in `tabbymac/<code>.po` first, then `tabby/<code>.po`, then the
English key itself. An empty `msgstr` or a `#, fuzzy` entry counts as untranslated.

★ `vi-VN.po` covers every string TabbyMac uses (both Tabby's and its own), not
Tabby's whole catalog. Tabby's other ~500 strings belong to features the Mac app
doesn't have. Cost: if a later string reuses a Tabby msgid, Vietnamese needs it added.
The catalog test catches that.

### Languages

`language` in `config.yaml` (default `null`, as in Tabby). `Languages.all` is Tabby's list
in Tabby's order with each language's own name, and `vi-VN` "Tiếng Việt" after Türkçe
(Latin scripts first, as Tabby orders them):

af-ZA, id-ID, cs-CZ, da-DK, de-DE, en-GB, en-US, es-ES, fr-FR, hr-HR, it-IT, pl-PL, pt-PT,
pt-BR, sv-SE, tr-TR, vi-VN, bg-BG, ru-RU, sr-SP, uk-UA, ja-JP, ko-KR, zh-CN, zh-TW.

With `language: null`, the app follows the system's preferred languages. The first one
that matches a code exactly wins. ★ Failing that, a language-only match is used:
- `de` → `de-DE`, `pt` → `pt-PT`, `en` → `en-US`, `vi` → `vi-VN`;
- `zh-Hans…` → `zh-CN`, and `zh-Hant…` or `zh-HK` → `zh-TW`;
- otherwise the first code that starts with the language.

Tabby needs an exact match. Cost: a Mac set to Austrian German gets German here and
English in Tabby. No match means English.

### Strings in code

- Every user-visible string goes through `L("English text", ["name": value])`
  (TabbyCore). It works from any thread, which matters for session messages.
  `Text(verbatim:)` is used for values. A SwiftUI `Text("literal")` would look in the
  main bundle, which `swift run` doesn't have, so literals are wrapped instead.
- Placeholders use Tabby's `{name}` form. Counts go through
  `Plural.count(n, one: "1 profile", other: "{n} profiles")`. ★ Only one/other forms
  exist, so languages with more plural forms get "other".
- Where TabbyMac's wording differs only trivially from a Tabby msgid (case, a word), ★
  TabbyMac adopts Tabby's wording so the 24 catalogs apply. Cost: some labels change
  slightly.
- Hotkey names stay English in `HotkeyCatalog` (they are keys). The Hotkeys page and the
  command palette show `L(name)`. The numbered ones use Tabby's msgids
  `Tab {number}` and `Focus pane {number}`.
- ★ Dates, byte counts and numbers keep the system formatters, so they follow the Mac's
  region, not the app language. Cost: a German UI on a US-region Mac shows US dates.

### Choosing the language

- Settings › Application starts with a **Language** group: a menu with "Automatic"
  (writes `null`) and the 25 names. The Welcome tab's picker is the same control.
- ★ The change applies live. The menu bar is rebuilt and SwiftUI views re-render.
  Lines already printed in a terminal stay as printed. Tabby asks for a restart
  instead. Cost: there is no "restart to apply".
- ★ There is no "Help translate Tabby" link. Tabby's link points at Tabby's Crowdin
  project, which doesn't hold TabbyMac's strings.
- The setting syncs with the account like every other setting.

### Guards

- Catalog tests (Linux):
  - every `.po` parses;
  - every translation's placeholders are a subset of its msgid's;
  - `vi-VN.po` has no empty entry for any key the app uses;
  - `tabbymac.pot` matches the extractor's output;
  - every `L("…")` key exists in Tabby's catalog or in `tabbymac.pot`.
- A coverage test fails on a raw UI literal (for example `Text("…")`,
  `NSMenuItem(title: "…")` or `SettingsRow("…")`) in the app's sources.
- `SettingsLayoutTests` also runs in German and Vietnamese: every page still fits.

## Notify when done, notify on activity, bell

Ported from `tabby-core/src/tabContextMenu.ts` (`TaskCompletionContextMenu`) and
`app.service.ts` (`CompletionObserver`).

- While the tab's focused pane runs a foreground process (`activeProcessName`), the tab
  menu and the pane menu show:
  - a disabled "Current process: {name}" line;
  - a "Notify when done" checkbox, which is one-shot.
- "Notify on activity" is always shown. It is one-shot and fires on the next output
  (after the pane's first second).
- Neither flag is saved.
- "Done" is polled once a second, as in Tabby. It fires when the foreground process is
  gone: "Process completed" with the process name as the body. Activity fires
  "Tab activity" with the tab title as the body.
- Delivery goes through a `Notifier` (`UNUserNotificationCenterDelegate`):
  - The banner carries the pane id, so clicking it focuses that pane and brings its
    window to the front.
  - Banners also show while TabbyMac is in front.
  - A banner is only posted from the bundled app with permission.
  - ★ The in-app toast is shown as well whenever the app is inactive or the pane isn't
    visible. This is the fallback the phase 2 spec asked for, since ad-hoc builds are
    refused banner permission on the test Mac.
  - The existing "process exited" notice uses the same path.
- Bell:
  - SwiftTerm only reports the bell in audible mode, so `SwiftTermEngine` reports it in
    every mode.
  - A bell on an unfocused pane marks the tab active, as in Tabby.
  - With `terminal.bellFlashFrame` on and the app inactive, the Dock icon bounces once
    (`requestUserAttention(.informationalRequest)`, Electron's `flashFrame`).
  - Settings › Terminal › Output gets a "Flash the Dock icon" switch with Tabby's
    description.

## Links and the command line

### Requests

`TabbyCLIKit` (new target, Foundation only, tested on Linux) defines one request type for
both entry points, Tabby's command set:

| Command | URL form | Effect |
|---|---|---|
| `open [directory]` | `tabbymac://open?directory=…` | Local tab in that directory (relative to the caller's cwd); must exist |
| `run <command…>` | `tabbymac://run?command=…` | Asks "Run …?", then a local tab running it, paused after exit |
| `profile <name>` | `tabbymac://profile?profileName=…` | Opens the saved profile with that name |
| `paste [text]` (`-e/--escape`) | `tabbymac://paste?text=…&escape=true` | Asks "Paste …?", then types it into the focused pane |
| `recent <index>` | `tabbymac://recent?profileNumber=…` | Opens a recent profile |
| `quickConnect <provider> <query>` | `tabbymac://quickConnect?providerId=…&query=…` | Quick-connect tab (`ssh`, `telnet`, `serial`) |
| `<path>` | `tabbymac://path?path=…` | A directory opens there; a `.sh` or `.command` file runs in the default profile after asking ★ (a link can name it) |
| — | `ssh://[user@]host[:port]` | Quick-connect SSH tab |
| — | `telnet://host[:port]` | Quick-connect telnet tab |

- URL commands match case-insensitively, and an empty `escape=` means true, as in
  Tabby.
- `ssh://` follows RFC 4248: the user is percent-decoded, and ★ the path and query are
  ignored.
- ★ `recent` reads its positional argument. Tabby declares `profileNumber` but reads
  `index`, so `tabby recent 0` never worked there.
- ★ An unknown profile shows a toast. Tabby only logs it.
- ★ There is no `--debug` and no `--hidden`.

### In the app

- `CLIRouter` handles a request. Requests that arrive before the first window are
  queued and run after launch, because AppKit can deliver a URL first.
- After handling, the window comes to the front.
- The app's own launch arguments are handled the same way, so
  `swift run TabbyMacDev open ~/x` works.
- `Info.plist` declares `ssh` and `telnet` next to `tabbymac`.
- Settings › Application › **Links**:
  - a button makes TabbyMac the handler for `ssh://` and `telnet://` (macOS asks the
    user to confirm);
  - a line names the current handler;
  - the group is hidden outside the app bundle.
- Settings › Application › **Command-line tool** shows the helper's path and copies an
  install command: `ln -s <app>/Contents/MacOS/tabby /usr/local/bin/tabby`. ★ Tabby
  ships Automator services for Finder instead.

### The helper

- `Contents/MacOS/tabby` (SwiftPM product `tabby`, built in Xcode like `tabby-askpass`)
  parses its arguments with `TabbyCLIKit`.
- Paths are resolved against its own working directory.
- ★ `paste` without text reads standard input. Tabby's help promises this but never
  reads it.
- It encodes the request as a `tabbymac://` URL and opens it with the app the helper
  lives in. That launches the app, or hands the request to the running one.
- Exit codes: 0 on hand-off, 1 when the app can't be opened, 2 for a usage error.
- ★ No result comes back, as in Tabby. A missing profile is reported in the app, not
  in the shell.
- `TABBYMAC_CLI_DRY_RUN=1` prints the URL instead of opening it (tests).

## Out of scope

- `tabby://` itself, the Dock menu of recent profiles, and Finder services.
- A "restart to apply" button.
- Plural rules beyond one/other.
- Translating TabbyMac's own strings into the other 23 languages.
- SwiftTerm 2.x.
- The bundle id and signing, so banner permission for ad-hoc builds stays as it is.
