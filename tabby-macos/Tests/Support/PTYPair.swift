#if os(macOS)
import Foundation

/// A pseudo-terminal pair standing in for a serial device: the code under test opens the
/// replica by its path (`/dev/ttysNNN`) as if it were `/dev/cu.*`, and the test plays the
/// device on the primary side. Closing the primary is unplugging the device.
public final class PTYPair {
    public let replicaPath: String
    private var primary: Int32
    private var replica: Int32

    public init() throws {
        var primary: Int32 = -1, replica: Int32 = -1
        var name = [CChar](repeating: 0, count: 128)
        guard openpty(&primary, &replica, &name, nil, nil) == 0 else {
            throw NSError(domain: "PTYPair", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
        self.primary = primary
        self.replica = replica
        replicaPath = String(cString: name)
        let flags = fcntl(primary, F_GETFL)
        _ = fcntl(primary, F_SETFL, flags | O_NONBLOCK)
    }

    /// Sends bytes from the "device" to whoever opened the replica.
    public func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Foundation.write(primary, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    public func write(_ text: String) { write(Data(text.utf8)) }

    /// Reads what the replica side wrote, until `count` bytes arrived or `timeout` passed.
    public func read(count: Int, timeout: TimeInterval = 5) -> Data {
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while received.count < count, Date() < deadline {
            var pfd = pollfd(fd: primary, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 50) > 0 else { continue }
            let n = Foundation.read(primary, &buffer, buffer.count)
            if n <= 0 { break }
            received.append(contentsOf: buffer[0..<n])
        }
        return received
    }

    /// The device goes away.
    public func unplug() {
        if primary >= 0 { close(primary); primary = -1 }
    }

    deinit {
        unplug()
        if replica >= 0 { close(replica) }
    }
}
#endif
