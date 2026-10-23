import Foundation

/// A serial port found on this Mac (Tabby's `SerialPortInfo`).
public struct SerialPortInfo: Hashable, Sendable {
    /// The callout device, e.g. `/dev/cu.usbserial-1420`.
    public var path: String
    /// Tabby's description: the USB vendor name and serial number, when there are any.
    public var description: String?

    public init(path: String, description: String? = nil) {
        self.path = path
        self.description = description?.isEmpty == true ? nil : description
    }

    /// `cu.usbserial-1420`.
    public var deviceName: String { (path as NSString).lastPathComponent }

    /// Ports every Mac has that no one connects a terminal to: the debug console and the
    /// Bluetooth incoming port. They get no profile and are listed last.
    public var isInternal: Bool {
        deviceName.hasSuffix(".debug-console") || deviceName.hasSuffix(".Bluetooth-Incoming-Port")
    }
}

public enum BaudRates {
    /// Tabby's `BAUD_RATES`.
    public static let standard = [110, 150, 300, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200,
                                  230400, 460800, 921600, 1500000]
    /// What quick connect uses when the query has no rate.
    public static let quickConnectDefault = 115200
}

public enum SerialParity: String, CaseIterable, Sendable {
    case none, even, odd
}

/// Options of a `serial` profile (`SerialProfileOptions` in `tabby-serial/src/api.ts`);
/// stream processing is read with `StreamOptions`.
public struct SerialOptions: Hashable, Sendable {
    public var port: String?
    /// nil: ask every time the profile opens.
    public var baudrate: Int?
    public var databits: Int
    public var stopbits: Double
    public var parity: SerialParity
    public var rtscts: Bool
    public var xon: Bool
    public var xoff: Bool
    public var xany: Bool
    public var slowSend: Bool

    public init(_ v: ConfigValue) {
        let p = v["port"]?.stringValue
        port = (p?.isEmpty ?? true) ? nil : p
        // Tabby reads the rate with parseInt, so "57600" works too.
        baudrate = v["baudrate"]?.intValue
        databits = v["databits"]?.intValue ?? 8
        stopbits = v["stopbits"]?.doubleValue ?? 1
        parity = v["parity"]?.stringValue.flatMap(SerialParity.init(rawValue:)) ?? .none
        rtscts = v["rtscts"]?.boolValue ?? false
        xon = v["xon"]?.boolValue ?? false
        xoff = v["xoff"]?.boolValue ?? false
        xany = v["xany"]?.boolValue ?? false
        slowSend = v["slowSend"]?.boolValue ?? false
    }
}

/// `serial` profiles: the template, one per detected port, and quick connect. Port of
/// `tabby-serial/src/profiles.ts`.
public final class SerialProfileProvider: ProfileProvider {
    public enum Parameter: Equatable, Sendable {
        case port, baudRate
    }

    public let id = "serial"
    public let name = "Serial"
    public let supportsQuickConnect = true

    public let configDefaults: ConfigValue = [
        "options": [
            "port": nil, "baudrate": nil, "databits": 8, "stopbits": 1, "parity": "none",
            "rtscts": false, "xon": false, "xoff": false, "xany": false,
            "inputMode": nil, "outputMode": nil, "inputNewlines": nil, "outputNewlines": nil,
            "scripts": [], "slowSend": false, "input": ["backspace": "backspace"],
        ],
        "clearServiceMessagesOnConnect": false,
    ]

    private let ports: () -> [SerialPortInfo]

    /// - Parameter ports: the ports on this Mac right now.
    public init(ports: @escaping () -> [SerialPortInfo]) {
        self.ports = ports
    }

    public func builtinProfiles() -> [Profile] {
        var list = [Profile(id: "serial:template", type: "serial", name: "Serial connection",
                            icon: "fas fa-microchip", isBuiltin: true, isTemplate: true)]
        for port in ports() where !port.isInternal {
            // Tabby: `serial:port-${slugify(name).replace('.', '-')}` (the first dot only).
            var slug = Slug.make(port.path)
            if let dot = slug.firstIndex(of: ".") { slug.replaceSubrange(dot...dot, with: "-") }
            list.append(Profile(id: "serial:port-\(slug)", type: "serial",
                                name: "Serial: \(port.description ?? port.deviceName)",
                                options: ["port": .string(port.path)],
                                icon: "fas fa-microchip", isBuiltin: true))
        }
        return list
    }

    /// `port`, `port@baud` or `port:baud`; a missing or unreadable rate is 115200 (Tabby).
    public func quickConnect(_ query: String) -> Profile? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        var port = q
        var baud = BaudRates.quickConnectDefault
        if let separator = q.contains("@") ? "@" : q.contains(":") ? ":" : nil {
            let parts = q.components(separatedBy: separator)
            port = parts[0]
            baud = Int(parts[1].prefix { $0.isNumber }) ?? baud
        }
        guard !port.isEmpty else { return nil }
        return Profile(type: "serial", name: q, options: ["port": .string(port), "baudrate": .int(baud)])
    }

    public func description(for profile: Profile) -> String {
        SerialOptions(profile.options).port ?? ""
    }

    public func suggestedName(for profile: Profile) -> String? {
        SerialOptions(profile.options).port
    }

    /// The inverse of `quickConnect` (`intoQuickConnectString`).
    public static func quickConnectString(_ options: SerialOptions) -> String? {
        guard let port = options.port else { return nil }
        if let baud = options.baudrate, baud != BaudRates.quickConnectDefault { return "\(port)@\(baud)" }
        return port
    }

    /// What must be asked before a profile can open (Tabby asks the rate in
    /// `getNewTabParameters`; TabbyMac asks for the port too instead of taking the first).
    public static func missingParameters(_ profile: Profile) -> [Parameter] {
        guard profile.type == "serial" else { return [] }
        let options = SerialOptions(profile.options)
        var missing: [Parameter] = []
        if options.port == nil { missing.append(.port) }
        if options.baudrate == nil { missing.append(.baudRate) }
        return missing
    }

    /// The profile with the answers filled in (for this tab only; config is not changed).
    public static func completing(_ profile: Profile, port: String? = nil, baudRate: Int? = nil) -> Profile {
        var p = profile
        if let port { p.options["port"] = .string(port) }
        if let baudRate { p.options["baudrate"] = .int(baudRate) }
        return p
    }
}
