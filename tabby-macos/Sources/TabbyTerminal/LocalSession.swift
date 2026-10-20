import Foundation
import TabbyCore

/// A local shell in a PTY (`tabby-local/src/session.ts`).
public final class LocalSession: TerminalSession {
    public var onOutput: ((Data) -> Void)?
    public var onClosed: ((Int32?) -> Void)?
    public var onStatus: ((SessionStatus) -> Void)?

    public let options: LocalOptions
    public let context: SessionContext
    private var process: PTYProcess?

    public init(options: LocalOptions, context: SessionContext) {
        self.options = options
        self.context = context
    }

    public var isRunning: Bool { process?.isRunning ?? false }
    public var pid: Int32 { process?.pid ?? 0 }

    public func start(cols: Int, rows: Int) throws {
        let command = options.command.isEmpty ? ShellDetector.loginShell() : options.command
        var args = options.args
        if options.command.isEmpty && args.isEmpty { args = ["--login"] }
        let env = SessionEnvironment.make(overrides: context.environment.merging(options.env) { _, b in b }, termName: context.termName)
        let cwd = Self.expand(context.workingDirectory ?? options.cwd) ?? NSHomeDirectory()
        let p = PTYProcess(executable: command, arguments: args, environment: env, workingDirectory: cwd)
        p.onData = { [weak self] data in self?.onOutput?(data) }
        p.onExit = { [weak self] code in
            guard let self else { return }
            self.onClosed?(code)
        }
        try p.start(cols: cols, rows: rows)
        process = p
    }

    static func expand(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        if path == "~" { return NSHomeDirectory() }
        if path.hasPrefix("~/") { return NSHomeDirectory() + String(path.dropFirst()) }
        return path
    }

    public func write(_ data: Data) { process?.write(data) }
    public func resize(cols: Int, rows: Int) { process?.resize(cols: cols, rows: rows) }
    public func kill() { process?.terminate() }
    public func workingDirectory() -> String? { process?.currentWorkingDirectory() }

    public func activeProcessName() -> String? {
        guard let p = process, p.hasForegroundChild else { return nil }
        return p.foregroundProcessName()
    }
}

public final class LocalSessionFactory: SessionFactory {
    public let profileType = "local"
    public init() {}

    public func makeSession(profile: Profile, context: SessionContext) throws -> TerminalSession {
        LocalSession(options: LocalOptions(profile.options), context: context)
    }
}

/// Shell discovery for built-in local profiles (`tabby-electron/src/shells/macDefault.ts`
/// and `posix.ts`).
public enum ShellDetector {
    /// The user's login shell: `dscl . -read /Users/$USER UserShell` on macOS, the passwd
    /// entry elsewhere, then `$SHELL`, then `/bin/zsh`.
    public static func loginShell() -> String {
        #if os(macOS)
        if let out = run("/usr/bin/dscl", [".", "-read", "/Users/\(NSUserName())", "UserShell"]),
           let line = out.split(separator: "\n").first(where: { $0.hasPrefix("UserShell:") }) {
            let shell = line.dropFirst("UserShell:".count).trimmingCharacters(in: .whitespaces)
            if !shell.isEmpty { return shell }
        }
        #endif
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if !s.isEmpty { return s }
        }
        if let s = ProcessInfo.processInfo.environment["SHELL"], !s.isEmpty { return s }
        return "/bin/zsh"
    }

    /// The login shell path (used to prefill new profiles).
    public static func loginShellName() -> String { loginShell() }

    /// `local:default` ("OS default") plus one entry per `/etc/shells` line.
    public static func detectShells() -> [Shell] {
        let login = loginShell()
        var shells = [Shell(id: "default", name: "OS default (\((login as NSString).lastPathComponent))",
                            command: login, args: ["--login"])]
        if let text = try? String(contentsOfFile: "/etc/shells", encoding: .utf8) {
            shells += Shell.parseEtcShells(text).filter { FileManager.default.isExecutableFile(atPath: $0.command) }
        }
        return shells
    }

    static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
