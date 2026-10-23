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
    private let queue = DispatchQueue(label: "TabbyMac.serial")
    private var source: DispatchSourceRead?
    private var closed = false

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
        startReading(fd)
    }

    private func release() {
        _ = Self.openPathsLock.withLock { Self.openPaths.remove(path) }
    }

    /// Changes the settings of an open port (the "Change baud rate" button).
    public func apply(_ settings: Settings) throws {
        guard fileDescriptor >= 0 else { return }
        try configure(fileDescriptor, settings)
    }

    public func write(_ data: Data) {
        let fd = fileDescriptor
        guard fd >= 0, !data.isEmpty else { return }
        queue.async { [weak self] in
            data.withUnsafeBytes { raw in
                var offset = 0
                let deadline = Date().addingTimeInterval(5)
                while offset < raw.count, self?.closed == false {
                    let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n > 0 {
                        offset += n
                    } else if n < 0, errno == EAGAIN || errno == EINTR, Date() < deadline {
                        // Flow control holds the line: wait until it takes more.
                        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&pfd, 1, 100)
                    } else {
                        break
                    }
                }
            }
        }
    }

    public func close() {
        guard fileDescriptor >= 0 else { return }
        queue.sync { closed = true }
        source?.cancel()
        source = nil
        fileDescriptor = -1
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

    private func startReading(_ fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        source.setEventHandler { [weak self, unowned source] in
            guard let self, !self.closed else { return }
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
            if hungUp {
                // No more reads or writes on this descriptor; the cancel handler closes it.
                self.closed = true
                source.cancel()
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.fileDescriptor == fd else { return }
                if !chunk.isEmpty { self.onData?(chunk) }
                if hungUp { self.hangUp() }
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source
        source.resume()
    }

    private func hangUp() {
        let handler = onHangup
        onHangup = nil
        source = nil
        fileDescriptor = -1
        release()
        handler?()
    }
}
#endif
