import Foundation

/// File locations. The clone never writes into Electron Tabby's directory; it only reads
/// `~/Library/Application Support/tabby/config.yaml` when the user asks to import it.
public struct ConfigPaths: Sendable {
    /// Placeholder product name; rename before release (see docs/ARCHITECTURE.md).
    public static let appDirectoryName = "TabbyMac"

    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Library/Application Support/TabbyMac`, or `$TABBYMAC_CONFIG_DIRECTORY` when set.
    public static func standard() -> ConfigPaths {
        if let override = ProcessInfo.processInfo.environment["TABBYMAC_CONFIG_DIRECTORY"], !override.isEmpty {
            return ConfigPaths(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return ConfigPaths(root: base.appendingPathComponent(appDirectoryName, isDirectory: true))
    }

    public var configFile: URL { root.appendingPathComponent("config.yaml") }
    public var configBackupFile: URL { root.appendingPathComponent("config.yaml.backup") }
    public var recoveryFile: URL { root.appendingPathComponent("recovery.json") }
    public var recentProfilesFile: URL { root.appendingPathComponent("recent-profiles.json") }
    public var windowStateFile: URL { root.appendingPathComponent("window.json") }
    public var knownHostsFile: URL { root.appendingPathComponent("known_hosts") }
    public var runtimeDirectory: URL { root.appendingPathComponent("run", isDirectory: true) }

    /// Electron Tabby's config on macOS (`app.getPath('userData')` for app name "tabby").
    public static var electronTabbyConfig: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("tabby/config.yaml")
    }

    public func ensureExists() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}

/// Loads and saves `config.yaml` atomically, keeping a `.backup` copy like Tabby does.
public struct ConfigFile {
    public let paths: ConfigPaths

    public init(paths: ConfigPaths) {
        self.paths = paths
    }

    public func load() throws -> ConfigValue {
        let url = paths.configFile
        guard FileManager.default.fileExists(atPath: url.path) else { return .emptyObject }
        let text = try String(contentsOf: url, encoding: .utf8)
        do {
            return try YAMLCoding.parse(text)
        } catch {
            throw ConfigError.invalidYAML(String(describing: error))
        }
    }

    public func save(_ store: ConfigStore) throws {
        try paths.ensureExists()
        let text = try store.serializedUserConfig()
        let data = Data(text.utf8)
        try data.write(to: paths.configFile, options: .atomic)
        try data.write(to: paths.configBackupFile, options: .atomic)
    }

    /// Reads Electron Tabby's config.yaml, if it exists. Encrypted configs can't be imported.
    public static func loadElectronTabbyConfig() throws -> ConfigValue? {
        let url = ConfigPaths.electronTabbyConfig
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try YAMLCoding.parse(String(contentsOf: url, encoding: .utf8))
        if value["encrypted"]?.boolValue == true {
            throw ImportError.encrypted
        }
        return value
    }

    public enum ImportError: Error, LocalizedError {
        case encrypted
        public var errorDescription: String? {
            "Tabby's config is encrypted with a vault passphrase. Disable \"Encrypt config\" in Tabby first."
        }
    }
}
