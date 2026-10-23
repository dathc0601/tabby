// TabbySerial: serial-port sessions (phase 4). A port is opened with POSIX termios, listed
// and watched through IOKit; the session is `SerialSession`. Port of `tabby-serial/src`.
#if os(macOS)
import Foundation
import TabbyCore

/// One open serial device (`/dev/cu.*`): raw mode, the profile's line settings, reads on a
/// background queue delivered to the main queue. What `serialport` does for Tabby.
public final class SerialPort {
    /// The line settings of a profile, with the baud rate chosen for this tab.
    public struct Settings: Equatable, Sendable {
        public var baudRate: Int
        public var dataBits: Int
        public var stopBits: Double
        public var parity: SerialParity
        public var rtscts: Bool
        public var xon: Bool
        public var xoff: Bool
        public var xany: Bool

        public init(_ options: SerialOptions, baudRate: Int) {
            self.baudRate = baudRate
            dataBits = options.databits
            stopBits = options.stopbits
            parity = options.parity
            rtscts = options.rtscts
            xon = options.xon
            xoff = options.xoff
            xany = options.xany
        }
    }

    public enum Failure: LocalizedError, Equatable {
        case cannotOpen(String, Int32)
        case busy(String)
        case cannotConfigure(Int32)
        case unsupportedBaudRate(Int)

        public var errorDescription: String? {
            switch self {
            case .cannotOpen(let path, let code): return "Cannot open \(path): \(String(cString: strerror(code)))"
            case .busy(let path): return "\(path) is busy: another program has it open"
            case .cannotConfigure(let code): return "Cannot configure the port: \(String(cString: strerror(code)))"
            case .unsupportedBaudRate(let rate): return "Unsupported baud rate \(rate)"
            }
        }
    }

    /// `_IOW('T', 2, speed_t)` from `IOKit/serial/ioss.h`, a macro Swift doesn't import.
    static let IOSSIOSPEED: UInt = 0x8008_5402

    /// Ports open in this process. The driver's exclusive mode (`TIOCEXCL`) keeps other
    /// programs out but not this one, and pseudo-terminals ignore it.
    private static let openPathsLock = NSLock()
    private static var openPaths = Set<String>()
    /// The rates macOS termios knows (`B…` constants equal the rate).
    static let termiosRates: Set<Int> = [50, 75, 110, 134, 150, 200, 300, 600, 1200, 1800, 2400, 4800, 7200, 9600,
                                         14400, 19200, 28800, 38400, 57600, 76800, 115200, 230400]

    public static func needsSpeedIoctl(_ rate: Int) -> Bool { !termiosRates.contains(rate) }

    public let path: String
    /// Bytes from the device (main queue).
    public var onData: ((Data) -> Void)?
    /// The device went away or hung up (main queue, once; not after `close()`).
    public var onHangup: (() -> Void)?

    public private(set) var fileDescriptor: Int32 = -1
    private var io: PortIO?

    public init(path: String) {
        self.path = path
    }

    public func open(_ settings: Settings) throws {
        let claimed = Self.openPathsLock.withLock { Self.openPaths.insert(path).inserted }
        guard claimed else { throw Failure.busy(path) }
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            let code = errno
            release()
            throw code == EBUSY ? Failure.busy(path) : Failure.cannotOpen(path, code)
        }
        // Exclusive: another program opening the port now gets EBUSY.
        if ioctl(fd, TIOCEXCL) != 0 && errno == EBUSY {
            Darwin.close(fd)
            release()
            throw Failure.busy(path)
        }
        do {
            try configure(fd, settings)
        } catch {
            Darwin.close(fd)
            release()
            throw error
        }
        fileDescriptor = fd
        let io = PortIO(fd: fd)
        // PortIO calls these on its queue; the port lives on the main queue.
        io.onData = { [weak self, weak io] data in
            DispatchQueue.main.async {
                guard let self, let io, self.io === io else { return }
                self.onData?(data)
            }
        }
        io.onHangup = { [weak self, weak io] in
            DispatchQueue.main.async {
                guard let self, let io, self.io === io else { return }
                self.hangUp()
            }
        }
        self.io = io
        io.start()
    }

    private func release() {
        _ = Self.openPathsLock.withLock { Self.openPaths.remove(path) }
    }

    /// Changes the settings of an open port (the "Change baud rate" button).
    public func apply(_ settings: Settings) throws {
        guard fileDescriptor >= 0 else { return }
        try configure(fileDescriptor, settings)
    }

    /// Queued and written as the line takes it; nothing is dropped while the port is open.
    public func write(_ data: Data) {
        io?.write(data)
    }

    /// Stops reading and writing, gives up exclusive mode and closes the device before it
    /// returns, so the same port can be opened again at once (Reconnect).
    public func close() {
        guard let io else { return }
        self.io = nil
        fileDescriptor = -1
        io.shutdown()
        release()
    }

    deinit { close() }

    // MARK: Private

    private func configure(_ fd: Int32, _ settings: Settings) throws {
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { throw Failure.cannotConfigure(errno) }
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(CSIZE)
        switch settings.dataBits {
        case 5: t.c_cflag |= tcflag_t(CS5)
        case 6: t.c_cflag |= tcflag_t(CS6)
        case 7: t.c_cflag |= tcflag_t(CS7)
        default: t.c_cflag |= tcflag_t(CS8)
        }
        // POSIX has no 1.5 stop bits; UARTs use 1.5 when CSTOPB is set with 5 data bits.
        if settings.stopBits > 1 { t.c_cflag |= tcflag_t(CSTOPB) } else { t.c_cflag &= ~tcflag_t(CSTOPB) }
        switch settings.parity {
        case .none: t.c_cflag &= ~tcflag_t(PARENB | PARODD)
        case .even: t.c_cflag = (t.c_cflag | tcflag_t(PARENB)) & ~tcflag_t(PARODD)
        case .odd: t.c_cflag |= tcflag_t(PARENB | PARODD)
        }
        let rtscts = tcflag_t(CCTS_OFLOW | CRTS_IFLOW)
        if settings.rtscts { t.c_cflag |= rtscts } else { t.c_cflag &= ~rtscts }
        t.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        if settings.xon { t.c_iflag |= tcflag_t(IXON) }
        if settings.xoff { t.c_iflag |= tcflag_t(IXOFF) }
        if settings.xany { t.c_iflag |= tcflag_t(IXANY) }

        let rate = settings.baudRate
        guard rate > 0 else { throw Failure.unsupportedBaudRate(rate) }
        let custom = Self.needsSpeedIoctl(rate)
        if !custom { cfsetspeed(&t, speed_t(rate)) }
        guard tcsetattr(fd, TCSANOW, &t) == 0 else {
            throw errno == EINVAL ? Failure.unsupportedBaudRate(rate) : Failure.cannotConfigure(errno)
        }
        if custom {
            // Rates termios lacks (460800 and up, or odd ones) go through IOSSIOSPEED.
            var speed = speed_t(rate)
            guard withUnsafeMutablePointer(to: &speed, { ioctl(fd, Self.IOSSIOSPEED, $0) }) == 0 else {
                throw Failure.unsupportedBaudRate(rate)
            }
        }
    }

    private func hangUp() {
        let handler = onHangup
        onHangup = nil
        close()
        handler?()
    }
}

/// The open descriptor of a `SerialPort` and its I/O, on one serial queue that never blocks:
/// reads on a read source, writes from a buffer drained by a write source as the line takes
/// them. Only `shutdown()` closes the descriptor, once neither source can touch it.
private final class PortIO: @unchecked Sendable {
    let fd: Int32
    /// Called on `queue`.
    var onData: ((Data) -> Void)?
    /// Called on `queue`, once, when the device goes away.
    var onHangup: (() -> Void)?

    private let queue = DispatchQueue(label: "TabbyMac.serial")
    private let lock = NSLock()
    private var closed = false
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private let cancelled = DispatchGroup()
    // Confined to `queue`:
    private var pending = Data()
    private var pendingOffset = 0
    private var writerSuspended = true
    private var buffer = [UInt8](repeating: 0, count: 65_536)

    init(fd: Int32) {
        self.fd = fd
    }

    func start() {
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        cancelled.enter()
        cancelled.enter()
        reader.setEventHandler { [unowned self] in readAvailable() }
        writer.setEventHandler { [unowned self] in writeAvailable() }
        reader.setCancelHandler { [cancelled] in cancelled.leave() }
        writer.setCancelHandler { [cancelled] in cancelled.leave() }
        self.reader = reader
        self.writer = writer
        reader.resume()
        // The writer starts suspended; data to write resumes it.
    }

    func write(_ data: Data) {
        queue.async { [self] in
            guard !isClosed else { return }
            pending.append(data)
            if writerSuspended, let writer {
                writerSuspended = false
                writer.resume()
            }
        }
    }

    /// From any thread but `queue`.
    func shutdown() {
        if markClosed() { queue.async { [self] in cancelSources() } }
        // After both cancel handlers no source runs again, so the descriptor is ours alone.
        _ = cancelled.wait(timeout: .now() + 2)
        _ = ioctl(fd, TIOCNXCL)
        Darwin.close(fd)
    }

    private var isClosed: Bool { lock.withLock { closed } }

    /// Sets `closed`; false when it already was.
    private func markClosed() -> Bool {
        lock.withLock {
            defer { closed = true }
            return !closed
        }
    }

    private func cancelSources() {
        reader?.cancel()
        // A suspended source has to be resumed before it is cancelled and released.
        if writerSuspended, let writer {
            writerSuspended = false
            writer.resume()
        }
        writer?.cancel()
        pending = Data()
        pendingOffset = 0
    }

    private func readAvailable() {
        guard !isClosed else { return }
        var chunk = Data()
        var hungUp = false
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n > 0 {
                chunk.append(contentsOf: buffer[0..<n])
                if n < buffer.count { break }
            } else if n < 0, errno == EAGAIN {
                break
            } else if n < 0, errno == EINTR {
                continue
            } else {
                // 0 (EOF) or ENXIO/EIO: the device is gone.
                hungUp = true
                break
            }
        }
        if !chunk.isEmpty { onData?(chunk) }
        if hungUp { hangUp() }
    }

    private func writeAvailable() {
        guard !isClosed else { return }
        while pendingOffset < pending.count {
            let n = pending.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress! + pendingOffset, raw.count - pendingOffset)
            }
            if n > 0 {
                pendingOffset += n
            } else if n < 0, errno == EINTR {
                continue
            } else if n < 0, errno == EAGAIN {
                return // the line is full (or held by flow control): wait for room
            } else {
                hangUp()
                return
            }
        }
        pending = Data()
        pendingOffset = 0
        if let writer, !writerSuspended {
            writerSuspended = true
            writer.suspend()
        }
    }

    private func hangUp() {
        guard markClosed() else { return }
        cancelSources()
        onHangup?()
    }
}
#endif
