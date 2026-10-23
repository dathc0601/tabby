import Foundation
import TabbyCore

/// A byte-stream session behind a terminal tab: local PTY, SSH, serial or telnet.
/// Port of `BaseSession` (`tabby-terminal/src/session.ts`). All callbacks run on the main queue.
public protocol TerminalSession: AnyObject {
    var onOutput: ((Data) -> Void)? { get set }
    /// Called once when the session ends, with the exit status when known.
    var onClosed: ((Int32?) -> Void)? { get set }
    /// A short status line for the UI ("Connecting to host…"), optional.
    var onStatus: ((SessionStatus) -> Void)? { get set }

    var isRunning: Bool { get }
    func start(cols: Int, rows: Int) throws
    func write(_ data: Data)
    func resize(cols: Int, rows: Int)
    /// Ends the session (SIGHUP for PTY sessions).
    func kill()
    /// Best-effort current directory of the foreground process.
    func workingDirectory() -> String?
    /// Name of the foreground process, when it isn't the shell itself.
    func activeProcessName() -> String?
}

public enum SessionStatus: Equatable, Sendable {
    case connecting(String)
    case connected
    case disconnected
    case message(String)
}

public extension TerminalSession {
    func activeProcessName() -> String? { nil }
}

/// A session that writes its own lines (badges, errors) which must reach the terminal as they
/// are, past any stream processing (Tabby's `serviceMessage$`).
public protocol ServiceOutputSource: AnyObject {
    var onServiceOutput: ((Data) -> Void)? { get set }
}

/// A session whose peer can ask for local echo (telnet `DO ECHO`).
public protocol LocalEchoSource: AnyObject {
    var onLocalEchoChanged: ((Bool) -> Void)? { get set }
}

/// Creates sessions for a profile type. The app registers one factory per provider.
public protocol SessionFactory: AnyObject {
    var profileType: String { get }
    func makeSession(profile: Profile, context: SessionContext) throws -> TerminalSession
}

public struct SessionContext: Sendable {
    /// Directory to start in (inherited from the active pane, or restored).
    public var workingDirectory: String?
    /// Extra environment from `terminal.environment`.
    public var environment: [String: String]
    public var termName: String

    public init(workingDirectory: String? = nil, environment: [String: String] = [:], termName: String = "xterm-256color") {
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.termName = termName
    }
}

/// Builds the child environment the way `tabby-local/src/session.ts` does.
public enum SessionEnvironment {
    public static let termProgram = "TabbyMac"

    public static func make(base: [String: String] = ProcessInfo.processInfo.environment,
                            overrides: [String: String] = [:], termName: String = "xterm-256color") -> [String: String] {
        var env = base
        // Variables that describe the parent app, not the new terminal.
        for key in ["TERM_SESSION_ID", "ITERM_SESSION_ID", "ITERM_PROFILE", "XPC_SERVICE_NAME",
                    "__CFBundleIdentifier", "APP_SANDBOX_CONTAINER_ID", "OS_ACTIVITY_DT_MODE", "NSUnbufferedIO"] {
            env[key] = nil
        }
        env["TERM"] = termName
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = termProgram
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            env["TERM_PROGRAM_VERSION"] = v
        }
        if env["LANG"] == nil || env["LANG"]?.isEmpty == true {
            env["LANG"] = "en_US.UTF-8"
        }
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        if env["PATH"] == nil || env["PATH"]?.isEmpty == true {
            env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        for (k, v) in overrides { env[k] = v }
        return env
    }
}
