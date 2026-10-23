// tabby-sync-server: reads its configuration from the environment (see README.md) and
// serves the /v1 API over plain HTTP; TLS is terminated by the reverse proxy in front.

import Foundation
import Logging
import SyncServer

let config: ServerConfig
let warnings: [String]
do {
    (config, warnings) = try ServerConfig.fromEnvironment()
} catch {
    FileHandle.standardError.write(Data("tabby-sync-server: \(error)\n".utf8))
    exit(1)
}

let app = try await buildApplication(config)
for warning in warnings {
    app.logger.warning("\(warning)")
}
try await app.runService()
