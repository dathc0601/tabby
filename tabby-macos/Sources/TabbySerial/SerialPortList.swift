#if os(macOS)
import Foundation
import IOKit
import IOKit.serial
import TabbyCore

/// Where the serial ports come from: IOKit in the app, a fake in tests.
public protocol SerialRegistry: AnyObject {
    func currentPorts() -> [SerialPortInfo]
    /// Calls `changed` on the main queue when a port appears or goes away, for as long as
    /// the returned token lives.
    func watch(_ changed: @escaping () -> Void) -> AnyObject?
}

/// The serial ports on this Mac, kept current as devices come and go (Tabby lists them
/// again each time; hot-plug is TabbyMac's). External ports first, then by path.
public final class SerialPortList {
    public private(set) var ports: [SerialPortInfo]
    private let registry: SerialRegistry
    private var watchToken: AnyObject?
    private var observers: [UUID: () -> Void] = [:]

    public init(registry: SerialRegistry = IOKitSerialRegistry()) {
        self.registry = registry
        ports = Self.sorted(registry.currentPorts())
        watchToken = registry.watch { [weak self] in self?.refresh() }
    }

    public func refresh() {
        let current = Self.sorted(registry.currentPorts())
        guard current != ports else { return }
        ports = current
        for observer in observers.values { observer() }
    }

    /// Calls `handler` after the list changed, until the returned token is released.
    public func observe(_ handler: @escaping () -> Void) -> AnyObject {
        let id = UUID()
        observers[id] = handler
        return Observation { [weak self] in self?.observers[id] = nil }
    }

    static func sorted(_ ports: [SerialPortInfo]) -> [SerialPortInfo] {
        ports.sorted { a, b in
            if a.isInternal != b.isInternal { return !a.isInternal }
            return a.path < b.path
        }
    }

    private final class Observation {
        let cancel: () -> Void
        init(_ cancel: @escaping () -> Void) { self.cancel = cancel }
        deinit { cancel() }
    }
}

/// Serial ports from IOKit (`IOSerialBSDClient` services), described the way Tabby's
/// `serialport` binding does: the USB vendor name and serial number.
public final class IOKitSerialRegistry: SerialRegistry {
    public init() {}

    public func currentPorts() -> [SerialPortInfo] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var ports: [SerialPortInfo] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String else { continue }
            let parts = ["USB Vendor Name", "USB Serial Number"].compactMap { Self.ancestorProperty(service, $0) }
            let description = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            ports.append(SerialPortInfo(path: path, description: description))
        }
        return ports
    }

    public func watch(_ changed: @escaping () -> Void) -> AnyObject? {
        Watcher(changed)
    }

    /// A property of the service or of its nearest ancestor that has it (the USB device).
    private static func ancestorProperty(_ service: io_object_t, _ key: String) -> String? {
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        let value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault, options)
        return (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// First-match and terminated notifications for serial services, on the main queue.
    private final class Watcher {
        private let port: IONotificationPortRef
        private var iterators: [io_iterator_t] = []
        private let changed: () -> Void

        init?(_ changed: @escaping () -> Void) {
            guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return nil }
            self.port = port
            self.changed = changed
            IONotificationPortSetDispatchQueue(port, .main)
            let context = Unmanaged.passUnretained(self).toOpaque()
            let callback: IOServiceMatchingCallback = { refcon, iterator in
                Watcher.drain(iterator)
                guard let refcon else { return }
                Unmanaged<Watcher>.fromOpaque(refcon).takeUnretainedValue().changed()
            }
            for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var iterator: io_iterator_t = 0
                guard IOServiceAddMatchingNotification(port, type, IOServiceMatching(kIOSerialBSDServiceValue),
                                                       callback, context, &iterator) == KERN_SUCCESS else { continue }
                // Draining the iterator arms the notification.
                Watcher.drain(iterator)
                iterators.append(iterator)
            }
        }

        deinit {
            for iterator in iterators { IOObjectRelease(iterator) }
            IONotificationPortDestroy(port)
        }

        static func drain(_ iterator: io_iterator_t) {
            while true {
                let service = IOIteratorNext(iterator)
                guard service != 0 else { return }
                IOObjectRelease(service)
            }
        }
    }
}
#endif
