// l10n-ignore-file: command-line text stays English, like Tabby's yargs help.
import Foundation

/// One thing to do in the app, from the command line or a link (Tabby's `CLIEvent.argv`).
public enum CLIRequest: Equatable, Sendable {
    /// A shell tab in `directory` (relative paths are resolved by the caller); nil: the
    /// caller's working directory.
    case open(directory: String?)
    /// A local tab running `command`, paused after it exits. ★ `cwd` is where the caller
    /// stood (Tabby's `run` ignores it).
    case run(command: [String], cwd: String?)
    case profile(name: String)
    /// ★ `text` nil: the helper reads standard input (Tabby's help promises it, its code
    /// never does).
    case paste(text: String?, escape: Bool)
    case recent(index: Int)
    case quickConnect(providerId: String, query: String)
    /// Tabby's `OpenPathCLIHandler`: a directory opens there, a `.sh`/`.command` script runs.
    case path(String)
}

public struct CLIUsageError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Tabby's command line (`app/lib/cli.ts`, yargs) for the `tabby` helper and the app's own
/// launch arguments.
public enum CLIArguments {
    public enum Outcome: Equatable, Sendable {
        case launch, help, version
        case request(CLIRequest)
    }

    public static let usage = """
    tabby [command] [arguments]

    Commands:
      tabby open [directory]                   open a shell in a directory
      tabby run [command...]                   run a command in the terminal
      tabby profile [profileName]              open a tab with specified profile
      tabby paste [text]                       paste stdin into the active tab
      tabby recent [index]                     open a tab with a recent profile
      tabby quickConnect <providerId> <query>  open a tab for specified quick connect provider
      tabby <path>                             open a directory, or run a .sh or .command script

    Options:
      -e, --escape  Perform shell escaping (paste)
      -h, --help    Show help
      --version     Show version number
    """

    public static func parse(_ args: [String]) -> Result<Outcome, CLIUsageError> {
        guard let first = args.first else { return .success(.launch) }
        let rest = Array(args.dropFirst())
        func fail(_ message: String) -> Result<Outcome, CLIUsageError> { .failure(CLIUsageError(message)) }
        func request(_ r: CLIRequest) -> Result<Outcome, CLIUsageError> { .success(.request(r)) }

        switch first.lowercased() {
        case "--help", "-h", "help":
            return .success(.help)
        case "--version":
            return .success(.version)
        case "open":
            guard rest.count <= 1 else { return fail("open takes one directory") }
            return request(.open(directory: rest.first))
        case "run", "/k":
            var command = rest
            if command.first == "--" { command.removeFirst() }
            guard !command.isEmpty else { return fail("run needs a command") }
            return request(.run(command: command, cwd: nil))
        case "profile":
            guard rest.count == 1, !rest[0].isEmpty else { return fail("profile needs one profile name (quote a name with spaces)") }
            return request(.profile(name: rest[0]))
        case "paste":
            var escape = false
            var text: String?
            for arg in rest {
                if arg == "-e" || arg == "--escape" { escape = true }
                else if text == nil { text = arg }
                else { return fail("paste takes one text (quote it)") }
            }
            return request(.paste(text: text, escape: escape))
        case "recent":
            guard rest.count == 1, let index = Int(rest[0]), index >= 0 else { return fail("recent needs an index; 0 is the latest") }
            return request(.recent(index: index))
        case "quickconnect":
            guard rest.count == 2 else { return fail("quickConnect needs a provider (ssh, telnet, serial) and a query") }
            return request(.quickConnect(providerId: rest[0], query: rest[1]))
        default:
            if first.hasPrefix("-") { return fail("Unknown option: \(first)") }
            guard rest.isEmpty else { return fail("Unknown command: \(first)") }
            return request(.path(first))
        }
    }

    /// The app's own arguments without what macOS and Xcode add: `-psn_…` (an old Finder
    /// launch) and `-NS…` / `-Apple…` user-default pairs.
    public static func appLaunchArguments(_ args: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg.hasPrefix("-psn_") { i += 1; continue }
            if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") { i += 2; continue }
            out.append(arg)
            i += 1
        }
        return out
    }
}

/// POSIX shell words, for `run` links (Tabby splits `command` with shell-quote) and `paste
/// --escape`.
public enum ShellWords {
    public static func split(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for ch in text {
            if escaped {
                current.append(ch); escaped = false; inWord = true
                continue
            }
            switch quote {
            case "'":
                if ch == "'" { quote = nil } else { current.append(ch) }
            case "\"":
                if ch == "\"" { quote = nil } else if ch == "\\" { escaped = true } else { current.append(ch) }
            default:
                if ch == "\\" { escaped = true }
                else if ch == "'" || ch == "\"" { quote = ch; inWord = true }
                else if ch == " " || ch == "\t" || ch == "\n" {
                    if inWord { words.append(current); current = ""; inWord = false }
                } else { current.append(ch); inWord = true }
            }
        }
        if inWord { words.append(current) }
        return words
    }

    public static func quote(_ word: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if !word.isEmpty, word.unicodeScalars.allSatisfy({ safe.contains($0) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
