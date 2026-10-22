import FluentPostgresDriver
import FluentSQLiteDriver
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging

/// Builds the sync server: database (migrated), routes, middleware. Run it with
/// `try await app.runService()`; test it with HummingbirdTesting.
public func buildApplication(_ config: ServerConfig) async throws -> some ApplicationProtocol {
    var logger = Logger(label: "tabby-sync-server")
    logger.logLevel = config.logLevel

    let fluent = Fluent(logger: logger)
    switch config.database {
    case .sqlite(let path):
        fluent.databases.use(.sqlite(SQLiteConfiguration(storage: .file(path: path))), as: .sqlite)
    case .sqliteMemory:
        fluent.databases.use(.sqlite(SQLiteConfiguration(storage: .memory)), as: .sqlite)
    case .postgres(let url):
        fluent.databases.use(try .postgres(url: url), as: .psql)
    }
    await fluent.migrations.add(CreateAccounts(), CreateDevices(), CreateVaults())
    try await fluent.migrate()

    let router = Router(context: SyncRequestContext.self)
    router.add(middleware: ErrorMiddleware())
    router.get("health") { _, _ in "ok" }
    router.head("health") { _, _ in HTTPResponse.Status.ok }
    SyncAPI(fluent: fluent, serverSecret: config.serverSecret, minimumScryptN: config.minimumScryptN,
            recoveryTokenLifetime: config.recoveryTokenLifetime)
        .addRoutes(to: router, rateLimiter: RateLimiter(limit: config.rateLimitPerMinute),
                   registrationLimiter: RateLimiter(limit: config.registrationsPerDay, window: 86_400))

    var app = Application(
        router: router,
        configuration: .init(address: .hostname(config.hostname, port: config.port), serverName: "tabby-sync-server"),
        logger: logger
    )
    app.addServices(fluent)
    return app
}
