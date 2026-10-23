// l10n-ignore-file: command-line output stays English, like Tabby's yargs help.
//
// tabby: TabbyMac's command line (phase 5), Tabby's `tabby open/run/profile/paste/recent/
// quickConnect/<path>`. It resolves paths where it runs, then hands the request to the app as
// a tabbymac:// link: the app it lives in (`TabbyMac.app/Contents/MacOS/tabby`, also through a
// symlink in /usr/local/bin), else the installed TabbyMac. Exit status: 0 handed over, 1 the
// app could not be opened, 2 a usage error. `TABBYMAC_CLI_DRY_RUN=1` prints the link instead.

import Foundation
#if !TABBY_CLI_STANDALONE
// In the Xcode tool target the TabbyCLIKit sources are compiled into this module directly.
import TabbyCLIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

let bundleIdentifier = "com.example.tabbymac"
let environment = ProcessInfo.processInfo.environment
let cwd = FileManager.default.currentDirectoryPath

func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data("tabby: \(message)\n".utf8))
    exit(status)
}

func absolute(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let full = expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)
    return (full as NSString).standardizingPath
}

/// The app this helper belongs to, or the installed one.
func appURL() -> URL? {
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let bundle = me.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if bundle.pathExtension == "app" { return bundle }
    #if canImport(AppKit)
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    #else
    return nil
    #endif
}

func version() -> String {
    guard let app = appURL(), let info = Bundle(url: app)?.infoDictionary,
          let short = info["CFBundleShortVersionString"] as? String else { return "development build" }
    return short
}

var request: CLIRequest?
switch CLIArguments.parse(Array(CommandLine.arguments.dropFirst())) {
case .failure(let error):
    FileHandle.standardError.write(Data("tabby: \(error.message)\n\n\(CLIArguments.usage)\n".utf8))
    exit(2)
case .success(.help):
    print(CLIArguments.usage)
    exit(0)
case .success(.version):
    print(version())
    exit(0)
case .success(.launch):
    request = nil
case .success(.request(let parsed)):
    switch parsed {
    case let .open(directory):
        request = .open(directory: absolute(directory ?? cwd))
    case let .run(command, _):
        request = .run(command: command, cwd: cwd)
    case let .path(path):
        request = .path(absolute(path))
    case let .paste(text, escape) where text == nil:
        // ★ Tabby's help says "paste stdin"; one trailing newline (from echo) is dropped.
        if isatty(FileHandle.standardInput.fileDescriptor) != 0 { fail("paste needs text or standard input", status: 2) }
        var input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        if input.hasSuffix("\n") { input.removeLast() }
        request = .paste(text: input, escape: escape)
    default:
        request = parsed
    }
}

let link = request.map(TabbyURL.encode)
if environment["TABBYMAC_CLI_DRY_RUN"] == "1" {
    print(link?.absoluteString ?? "launch")
    exit(0)
}

#if canImport(AppKit)
guard let app = appURL() else { fail("TabbyMac.app was not found", status: 1) }
let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = true
let done: (NSRunningApplication?, Error?) -> Void = { _, error in
    if let error { fail("could not open TabbyMac: \(error.localizedDescription)", status: 1) }
    exit(0)
}
if let link {
    NSWorkspace.shared.open([link], withApplicationAt: app, configuration: configuration, completionHandler: done)
} else {
    NSWorkspace.shared.openApplication(at: app, configuration: configuration, completionHandler: done)
}
RunLoop.main.run(until: Date().addingTimeInterval(30))
fail("TabbyMac did not answer", status: 1)
#else
fail("TabbyMac runs on macOS", status: 1)
#endif
