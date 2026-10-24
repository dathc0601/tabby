import Foundation

/// Options of a `local` profile (`tabby-local` `SessionOptions`).
public struct LocalOptions: Hashable, Sendable {
    public var command: String
    public var args: [String]
    public var cwd: String?
    public var env: [String: String]
    public var pauseAfterExit: Bool

    public init(command: String, args: [String] = [], cwd: String? = nil, env: [String: String] = [:], pauseAfterExit: Bool = false) {
        self.command = command
        self.args = args
        self.cwd = cwd
        self.env = env
        self.pauseAfterExit = pauseAfterExit
    }

    public init(_ v: ConfigValue) {
        command = v["command"]?.stringValue ?? ""
        args = v["args"]?.stringArrayValue ?? []
        let c = v["cwd"]?.stringValue
        cwd = (c?.isEmpty ?? true) ? nil : c
        env = (v["env"]?.objectValue ?? [:]).compactMapValues { $0.stringValue }
        env[ConfigValue.nonStructuralKey] = nil
        pauseAfterExit = v["pauseAfterExit"]?.boolValue ?? false
    }

    public var configValue: ConfigValue {
        var o: [String: ConfigValue] = [
            "command": .string(command),
            "args": .array(args.map { .string($0) }),
        ]
        if let cwd { o["cwd"] = .string(cwd) }
        if !env.isEmpty { o["env"] = .object(env.mapValues { .string($0) }) }
        if pauseAfterExit { o["pauseAfterExit"] = true }
        return .object(o)
    }
}

/// SSH authentication method. `nil` in Tabby means "try everything".
public enum SSHAuthMethod: String, CaseIterable, Sendable {
    case password, publicKey, agent, keyboardInteractive
}

public enum PortForwardType: String, CaseIterable, Sendable {
    case local = "Local", remote = "Remote", dynamic = "Dynamic" // l10n-ignore: Tabby's config values

    public var title: String {
        switch self {
        case .local: return L("Local")
        case .remote: return L("Remote")
        case .dynamic: return L("Dynamic")
        }
    }
}

public struct ForwardedPort: Hashable, Sendable {
    public var type: PortForwardType
    public var host: String
    public var port: Int
    public var targetAddress: String
    public var targetPort: Int
    public var description: String

    public init(type: PortForwardType, host: String = "127.0.0.1", port: Int, targetAddress: String = "", targetPort: Int = 0, description: String = "") {
        self.type = type
        self.host = host
        self.port = port
        self.targetAddress = targetAddress
        self.targetPort = targetPort
        self.description = description
    }

    public init?(_ v: ConfigValue) {
        guard let port = v["port"]?.intValue else { return nil }
        self.init(
            type: v["type"]?.stringValue.flatMap(PortForwardType.init(rawValue:)) ?? .local,
            host: v["host"]?.stringValue ?? "127.0.0.1",
            port: port,
            targetAddress: v["targetAddress"]?.stringValue ?? "",
            targetPort: v["targetPort"]?.intValue ?? 0,
            description: v["description"]?.stringValue ?? ""
        )
    }

    public var configValue: ConfigValue {
        ["type": .string(type.rawValue), "host": .string(host), "port": .int(port),
         "targetAddress": .string(targetAddress), "targetPort": .int(targetPort), "description": .string(description)]
    }
}

/// Login script entry: when `expect` appears in the output, send `send`.
public struct LoginScript: Hashable, Sendable {
    public var expect: String
    public var send: String
    public var isRegex: Bool
    public var optional: Bool

    public init?(_ v: ConfigValue) {
        guard let send = v["send"]?.stringValue else { return nil }
        self.expect = v["expect"]?.stringValue ?? ""
        self.send = send
        self.isRegex = v["isRegex"]?.boolValue ?? false
        self.optional = v["optional"]?.boolValue ?? false
    }
}

/// Options of an `ssh` profile (`tabby-ssh/src/api/interfaces.ts`).
public struct SSHOptions: Hashable, Sendable {
    public var host: String
    public var port: Int
    public var user: String
    public var auth: SSHAuthMethod?
    public var password: String?
    public var privateKeys: [String]
    public var keepaliveInterval: Int
    public var keepaliveCountMax: Int
    public var readyTimeout: Int?
    public var x11: Bool
    public var skipBanner: Bool
    public var jumpHost: String?
    public var agentForward: Bool
    public var warnOnClose: Bool?
    public var algorithms: [String: [String]]
    public var proxyCommand: String?
    public var forwardedPorts: [ForwardedPort]
    public var socksProxyHost: String?
    public var socksProxyPort: Int?
    public var httpProxyHost: String?
    public var httpProxyPort: Int?
    public var reuseSession: Bool
    public var cwd: String?
    public var rememberCwd: Bool
    public var term: String
    public var scripts: [LoginScript]

    public init(_ v: ConfigValue) {
        func optString(_ k: String) -> String? {
            guard let s = v[k]?.stringValue, !s.isEmpty else { return nil }
            return s
        }
        host = v["host"]?.stringValue ?? ""
        port = v["port"]?.intValue ?? 22
        user = v["user"]?.stringValue ?? "root"
        auth = v["auth"]?.stringValue.flatMap(SSHAuthMethod.init(rawValue:))
        password = optString("password")
        privateKeys = v["privateKeys"]?.stringArrayValue ?? []
        keepaliveInterval = v["keepaliveInterval"]?.intValue ?? 5000
        keepaliveCountMax = v["keepaliveCountMax"]?.intValue ?? 10
        readyTimeout = v["readyTimeout"]?.intValue
        x11 = v["x11"]?.boolValue ?? false
        skipBanner = v["skipBanner"]?.boolValue ?? false
        jumpHost = optString("jumpHost")
        agentForward = v["agentForward"]?.boolValue ?? false
        warnOnClose = v["warnOnClose"]?.boolValue
        algorithms = (v["algorithms"]?.objectValue ?? [:]).compactMapValues { $0.stringArrayValue }
        proxyCommand = optString("proxyCommand")
        forwardedPorts = (v["forwardedPorts"]?.arrayValue ?? []).compactMap(ForwardedPort.init)
        socksProxyHost = optString("socksProxyHost")
        socksProxyPort = v["socksProxyPort"]?.intValue
        httpProxyHost = optString("httpProxyHost")
        httpProxyPort = v["httpProxyPort"]?.intValue
        reuseSession = v["reuseSession"]?.boolValue ?? true
        cwd = optString("cwd")
        rememberCwd = v["rememberCwd"]?.boolValue ?? false
        term = optString("term") ?? "xterm-256color"
        scripts = (v["scripts"]?.arrayValue ?? []).compactMap(LoginScript.init)
    }

    /// `user@host:port`, Tabby's suggested name for SSH profiles.
    public var suggestedName: String { "\(user)@\(host):\(port)" }
}
