import Foundation
import Logging
import TabbySyncProtocol

/// Server settings, normally read from the environment (`ServerConfig.fromEnvironment`).
public struct ServerConfig: Sendable {
    public enum Database: Sendable, Equatable {
        /// A SQLite file (development, small installs).
        case sqlite(path: String)
        /// A private in-memory SQLite database (tests).
        case sqliteMemory
        /// `postgres://user:password@host:5432/database` (production).
        case postgres(url: String)
    }

    public struct ConfigError: Error, CustomStringConvertible {
        public let description: String
    }

    public var hostname: String
    public var port: Int
    public var database: Database
    /// Keys the fake KDF salts of unknown emails; must stay the same across restarts.
    public var serverSecret: Data
    /// Fixed-window limit per client address for sign-up and sign-in requests.
    public var rateLimitPerMinute: Int
    /// Accounts one client address may create per day (registration is open; this keeps a
    /// script from filling the disk).
    public var registrationsPerDay: Int
    /// The least scrypt N accepted at sign-up and password change (clients refuse less).
    public var minimumScryptN: Int
    /// How long a recovery-key sign-in may be used before it has set a new password.
    public var recoveryTokenLifetime: TimeInterval
    public var logLevel: Logger.Level

    public init(
        hostname: String = "0.0.0.0",
        port: Int = 8080,
        database: Database,
        serverSecret: Data,
        rateLimitPerMinute: Int = 10,
        registrationsPerDay: Int = 20,
        minimumScryptN: Int = KDFParams.minimumN,
        recoveryTokenLifetime: TimeInterval = 3600,
        logLevel: Logger.Level = .info
    ) {
        self.hostname = hostname
        self.port = port
        self.database = database
        self.serverSecret = serverSecret
        self.rateLimitPerMinute = rateLimitPerMinute
        self.registrationsPerDay = registrationsPerDay
        self.minimumScryptN = minimumScryptN
        self.recoveryTokenLifetime = recoveryTokenLifetime
        self.logLevel = logLevel
    }

    /// Reads `PORT` (8080), `HOSTNAME` (0.0.0.0), `DATABASE_URL` (Postgres; when absent,
    /// SQLite at `SQLITE_PATH`, default `./sync.sqlite`), `SERVER_SECRET`, `LOG_LEVEL` (info)
    /// and `ENVIRONMENT`. Without `SERVER_SECRET` a random one is used for this process and
    /// a warning is returned; with `ENVIRONMENT=production` it is an error.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> (config: ServerConfig, warnings: [String]) {
        func value(_ key: String) -> String? {
            guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            return value
        }

        var warnings: [String] = []
        let port: Int
        if let raw = value("PORT") {
            guard let parsed = Int(raw), (1...65_535).contains(parsed) else {
                throw ConfigError(description: "PORT must be a port number, got \(raw)")
            }
            port = parsed
        } else {
            port = 8080
        }

        let database: Database
        if let url = value("DATABASE_URL") {
            database = .postgres(url: url)
        } else {
            database = .sqlite(path: value("SQLITE_PATH") ?? "./sync.sqlite")
        }

        let secret: Data
        if let raw = value("SERVER_SECRET") {
            secret = Data(raw.utf8)
        } else if value("ENVIRONMENT")?.lowercased() == "production" {
            throw ConfigError(description: "SERVER_SECRET is required when ENVIRONMENT=production")
        } else {
            secret = VaultCrypto.randomBytes(32)
            warnings.append("SERVER_SECRET is not set; using a random secret for this process. "
                + "Unknown emails will get different KDF salts after a restart.")
        }

        let logLevel: Logger.Level
        if let raw = value("LOG_LEVEL") {
            guard let parsed = Logger.Level(rawValue: raw.lowercased()) else {
                throw ConfigError(description: "LOG_LEVEL must be one of trace, debug, info, notice, warning, error, critical")
            }
            logLevel = parsed
        } else {
            logLevel = .info
        }

        var registrationsPerDay = 20
        if let raw = value("REGISTRATIONS_PER_DAY") {
            guard let parsed = Int(raw), parsed > 0 else {
                throw ConfigError(description: "REGISTRATIONS_PER_DAY must be a positive number, got \(raw).")
            }
            registrationsPerDay = parsed
        }
        let config = ServerConfig(hostname: value("HOSTNAME") ?? "0.0.0.0", port: port, database: database,
                                  serverSecret: secret, registrationsPerDay: registrationsPerDay, logLevel: logLevel)
        return (config, warnings)
    }
}
