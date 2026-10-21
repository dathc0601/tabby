import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A child process attached to a pseudo-terminal.
///
/// Plays the role of node-pty plus Tabby's `PTYManager` (`app/lib/pty.ts`): spawn, read with
/// flow control, write, resize, signal, and look up the foreground process. Callbacks are
/// delivered on the main queue. Works on macOS and Linux (so it is unit-tested on Linux).
public final class PTYProcess {
    public struct LaunchError: Error, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String?

    /// Output chunks, on the main queue.
    public var onData: ((Data) -> Void)?
    /// Exit status (0...255), or nil when killed by a signal. Delivered once, on the main
    /// queue, after the remaining output has been delivered.
    public var onExit: ((Int32?) -> Void)?

    public private(set) var pid: pid_t = 0
    public private(set) var masterFD: Int32 = -1
    public private(set) var isRunning = false

    private let writeQueue = DispatchQueue(label: "TabbyMac.pty.write")
    /// Limits how many chunks can wait on the main queue (back-pressure for `cat bigfile`).
    private let inFlight = DispatchSemaphore(value: 4)
    private let readerDone = DispatchSemaphore(value: 0)
    private var exitDelivered = false

    /// Set once the child has called `execve` (or failed to), see `start`. Guarded by
    /// `execLock` because the waiter thread sets it and callers read it from the main queue.
    private let execLock = NSLock()
    private var execDone = false
    private var execErrno: Int32?

    /// True once the child process has replaced itself with the requested executable.
    /// Until then its cwd and name still describe the parent, so callers must not trust them.
    public var hasExeced: Bool {
        execLock.lock(); defer { execLock.unlock() }
        return execDone
    }

    /// `errno` from a failed `execve`, if the child could not start the executable.
    public var launchFailureErrno: Int32? {
        execLock.lock(); defer { execLock.unlock() }
        return execErrno
    }

    /// - Parameters:
    ///   - executable: absolute path, or a name resolved through `PATH`.
    ///   - arguments: argv[1...].
    ///   - argv0: argv[0]; prefix it with `-` to start a login shell the way `login(1)` does.
    public init(executable: String, arguments: [String], environment: [String: String], workingDirectory: String? = nil, argv0: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.argv0 = argv0
    }

    private let argv0: String?

    deinit {
        if masterFD >= 0 { close(masterFD) }
    }

    // MARK: Launch

    public func start(cols: Int, rows: Int) throws {
        guard !isRunning else { return }
        guard let path = Self.resolveExecutable(executable, path: environment["PATH"]) else {
            throw LaunchError(message: "Command not found: \(executable)")
        }
        var size = winsize(ws_row: UInt16(clamping: max(rows, 1)), ws_col: UInt16(clamping: max(cols, 1)), ws_xpixel: 0, ws_ypixel: 0)

        // Everything the child needs is prepared before fork: after fork only
        // async-signal-safe calls are allowed.
        let argv = [argv0 ?? path] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }
        let cArgv = makeCStringArray(argv)
        let cEnvp = makeCStringArray(envp)
        guard let cPath = strdup(path) else { throw LaunchError(message: "Out of memory") }
        let cCwd = workingDirectory.flatMap { FileManager.default.fileExists(atPath: $0) ? strdup($0) : nil }
        defer {
            freeCStringArray(cArgv, count: argv.count)
            freeCStringArray(cEnvp, count: envp.count)
            cFree(cPath)
            if let cCwd { cFree(cCwd) }
        }

        // Exec-detection pipe (the classic close-on-exec trick): the write end disappears
        // when the child execs, so the parent reads EOF; if execve fails the child writes
        // errno first. Until then proc_pidinfo on the child still reports the parent's cwd.
        var execPipe: [Int32] = [-1, -1]
        guard pipe(&execPipe) == 0 else {
            throw LaunchError(message: "pipe failed: \(String(cString: strerror(errno)))")
        }
        _ = fcntl(execPipe[1], F_SETFD, FD_CLOEXEC)

        var master: Int32 = -1
        let child = forkpty(&master, nil, nil, &size)
        if child < 0 {
            close(execPipe[0]); close(execPipe[1])
            throw LaunchError(message: "forkpty failed: \(String(cString: strerror(errno)))")
        }
        if child == 0 {
            // Child. Restore default signal handling: dispositions set to SIG_IGN in the app
            // (e.g. SIGPIPE) would otherwise survive execve and break pipelines in the shell.
            signal(SIGPIPE, SIG_DFL)
            signal(SIGINT, SIG_DFL)
            signal(SIGQUIT, SIG_DFL)
            signal(SIGTERM, SIG_DFL)
            signal(SIGCHLD, SIG_DFL)
            close(execPipe[0])
            if let cCwd { _ = chdir(cCwd) }
            execve(cPath, cArgv, cEnvp)
            var err = errno
            _ = cWrite(execPipe[1], &err, MemoryLayout<Int32>.size)
            _exit(127)
        }

        close(execPipe[1])
        pid = child
        masterFD = master
        isRunning = true
        startReader()
        startWaiter(execReadFD: execPipe[0])
    }

    /// Resolves a bare command name through `PATH`, like `execvp` would.
    public static func resolveExecutable(_ name: String, path: String?) -> String? {
        if name.contains("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        let dirs = (path ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":")
        for dir in dirs {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: I/O

    private func startReader() {
        let fd = masterFD
        // The semaphores are captured on their own, not through `self`: every `wait` must be
        // matched by a `signal` even when the process object is released while chunks are
        // still queued on the main queue. Disposing a DispatchSemaphore whose value is below
        // its initial value traps (this was the crash when closing a tab with output pending).
        let inFlight = self.inFlight
        let readerDone = self.readerDone
        let thread = Thread { [weak self] in
            let bufferSize = 64 * 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while true {
                let n = read(fd, buffer, bufferSize)
                if n > 0 {
                    let chunk = Data(bytes: buffer, count: n)
                    guard self != nil else { break }
                    inFlight.wait()
                    DispatchQueue.main.async { [weak self] in
                        self?.onData?(chunk)
                        inFlight.signal()
                    }
                } else if n < 0 && (errno == EINTR || errno == EAGAIN) {
                    continue
                } else {
                    break // EOF or EIO: the slave side is closed.
                }
            }
            readerDone.signal()
        }
        thread.name = "TabbyMac.pty.read"
        thread.start()
    }

    private func startWaiter(execReadFD: Int32) {
        let child = pid
        let thread = Thread { [weak self] in
            // Block until the child execs (EOF) or reports an execve failure (errno).
            // exec happens within microseconds, so this doesn't delay the waitpid below.
            var err: Int32 = 0
            var n: Int
            repeat { n = read(execReadFD, &err, MemoryLayout<Int32>.size) } while n < 0 && errno == EINTR
            close(execReadFD)
            if let self {
                self.execLock.lock()
                self.execDone = true
                if n == MemoryLayout<Int32>.size { self.execErrno = err }
                self.execLock.unlock()
            }

            var status: Int32 = 0
            var r: pid_t
            repeat { r = waitpid(child, &status, 0) } while r < 0 && errno == EINTR
            let code: Int32? = r < 0 ? nil : Self.exitCode(fromWaitStatus: status)
            // Let the reader drain what the process wrote before exiting; background
            // children may keep the pty open, so don't wait forever.
            _ = self?.readerDone.wait(timeout: .now() + .milliseconds(300))
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.exitDelivered else { return }
                self.exitDelivered = true
                self.isRunning = false
                self.onExit?(code)
            }
        }
        thread.name = "TabbyMac.pty.wait"
        thread.start()
    }

    static func exitCode(fromWaitStatus status: Int32) -> Int32? {
        // WIFEXITED / WEXITSTATUS, spelled out because the C macros aren't imported.
        let termSignal = status & 0x7f
        if termSignal == 0 { return (status >> 8) & 0xff }
        return nil
    }

    public func write(_ data: Data) {
        guard isRunning, masterFD >= 0, !data.isEmpty else { return }
        let fd = masterFD
        writeQueue.async {
            data.withUnsafeBytes { raw in
                guard var p = raw.baseAddress else { return }
                var remaining = raw.count
                while remaining > 0 {
                    let n = cWrite(fd, p, remaining)
                    if n < 0 {
                        if errno == EINTR || errno == EAGAIN { usleep(1000); continue }
                        return
                    }
                    remaining -= n
                    p = p.advanced(by: n)
                }
            }
        }
    }

    public func resize(cols: Int, rows: Int) {
        guard masterFD >= 0 else { return }
        var size = winsize(ws_row: UInt16(clamping: max(rows, 1)), ws_col: UInt16(clamping: max(cols, 1)), ws_xpixel: 0, ws_ypixel: 0)
        #if canImport(Darwin)
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
        #else
        _ = ioctl(masterFD, UInt(TIOCSWINSZ), &size)
        #endif
    }

    /// Sends a signal to the child's process group (SIGHUP by default, like closing a terminal).
    public func terminate(signal sig: Int32 = SIGHUP) {
        guard isRunning, pid > 0 else { return }
        kill(-pid, sig)
        kill(pid, sig)
    }

    // MARK: Process inspection

    /// The pid of the foreground process group leader on this terminal.
    public var foregroundProcessID: pid_t? {
        guard masterFD >= 0 else { return nil }
        let pgid = tcgetpgrp(masterFD)
        return pgid > 0 ? pgid : nil
    }

    /// Whether something other than the shell itself is running in the foreground.
    public var hasForegroundChild: Bool {
        guard let fg = foregroundProcessID else { return false }
        return fg != pid
    }

    /// Working directory of the foreground process (falls back to the shell). Before the
    /// child has exec'd, the kernel still reports the parent's cwd for it, so answer with
    /// the directory the child was asked to start in instead.
    public func currentWorkingDirectory() -> String? {
        guard hasExeced else { return workingDirectory }
        let target = foregroundProcessID ?? pid
        return Self.workingDirectory(of: target) ?? Self.workingDirectory(of: pid)
    }

    public func foregroundProcessName() -> String? {
        guard let fg = foregroundProcessID else { return nil }
        return Self.processName(of: fg)
    }

    public static func workingDirectory(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        #if os(macOS)
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let r = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard r == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
        #else
        return try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/cwd")
        #endif
    }

    public static func processName(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        #if os(macOS)
        var buffer = [CChar](repeating: 0, count: 1024)
        let n = proc_name(pid, &buffer, UInt32(buffer.count))
        return n > 0 ? String(cString: buffer) : nil
        #else
        return (try? String(contentsOfFile: "/proc/\(pid)/comm", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #endif
    }
}

// MARK: - C helpers (file scope, so PTYProcess members don't shadow the libc functions)

private func cFree(_ p: UnsafeMutableRawPointer?) {
    free(p)
}

private func cWrite(_ fd: Int32, _ p: UnsafeRawPointer, _ n: Int) -> Int {
    write(fd, p, n)
}

private func makeCStringArray(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
    let base = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
    for (i, s) in strings.enumerated() { base[i] = strdup(s) }
    base[strings.count] = nil
    return base
}

private func freeCStringArray(_ array: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, count: Int) {
    for i in 0..<count { free(array[i]) }
    array.deallocate()
}
