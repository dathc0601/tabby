import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import SyncServer
import TabbyAccount
import TabbyCore
import TabbySSH
import TabbySyncProtocol
import XCTest

/// The app's `HTTPTransport` over HummingbirdTesting, so TabbyMac's real client and sync
/// engine talk to the real server without sockets.
struct TestClientTransport: HTTPTransport {
    let client: any TestClientProtocol

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        var uri = url.path
        if let query = url.query { uri += "?" + query }
        var headers = HTTPFields()
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            if let field = HTTPField.Name(name) { headers[field] = value }
        }
        let method = HTTPRequest.Method(request.httpMethod ?? "GET")!
        let body = request.httpBody.map { ByteBuffer(bytes: $0) }
        let response = try await client.execute(uri: uri, method: method, headers: headers, body: body)
        let data = Data(buffer: response.body)
        var fields: [String: String] = [:]
        for field in response.headers { fields[field.name.rawName] = field.value }
        let http = HTTPURLResponse(url: url, statusCode: Int(response.status.code), httpVersion: "HTTP/1.1", headerFields: fields)!
        return (data, http)
    }
}

/// One simulated Mac: config, Keychain, synced keys, known_hosts and home in a temp folder.
@MainActor
final class SimulatedMac {
    let root: URL
    let config: ConfigStore
    let passwords = InMemoryPasswordStore()
    let keys: KeyFileStore
    let local: LocalSyncData
    var engine: SyncEngine?

    init(_ name: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-\(name)-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home/.ssh"), withIntermediateDirectories: true)
        config = ConfigStore(defaults: try ConfigStore.bundledDefaults())
        keys = KeyFileStore(directory: root.appendingPathComponent("keys"))
        local = LocalSyncData(config: config, passwords: passwords, keyStore: keys,
                              knownHostsFile: root.appendingPathComponent("known_hosts"), homeDirectory: root.appendingPathComponent("home").path)
    }

    func connect(_ session: AccountSession, transport: HTTPTransport) throws {
        let client = try SyncClient(baseURL: URL(string: "http://localhost")!, transport: transport, token: session.token)
        engine = SyncEngine(client: client, session: session, local: local, stateFile: root.appendingPathComponent("sync-state.json"))
    }

    var profileNames: [String] { (config.value("profiles")?.arrayValue ?? []).compactMap { $0["name"]?.stringValue } }
}

final class AppClientEndToEndTests: XCTestCase {
    func testTwoMacsSyncThroughTheServer() async throws {
        try await withApp { client in
            try await Self.scenario(TestClientTransport(client: client))
        }
    }

    @MainActor
    static func scenario(_ transport: TestClientTransport) async throws {
        let kdf = KDFParams(n: 1024, r: 8, p: 1, salt: Data(repeating: 3, count: 16))
        let device = DeviceInfo(name: "Mac", model: "Mac15,3", os: "macOS 15.1")
        let a = try SimulatedMac("a")
        let b = try SimulatedMac("b")
        defer {
            try? FileManager.default.removeItem(at: a.root)
            try? FileManager.default.removeItem(at: b.root)
        }

        // Mac A signs up with a profile, its password, its key and a setting.
        let keyPath = a.root.appendingPathComponent("home/.ssh/acme").path
        try Data("-----KEY-----".utf8).write(to: URL(fileURLWithPath: keyPath))
        a.config.set("profiles", .array([["id": "ssh:prod", "type": "ssh", "name": "prod-web-01",
                                          "options": ["host": "prod.example.com", "user": "deploy", "privateKeys": .array([.string(keyPath)])]]]))
        a.passwords.savePassword("s3cret", host: "prod.example.com", port: 22, user: "deploy")
        a.config.set("account.approvedKeyFiles", .array([.string(LocalSyncData.keyID(Data("-----KEY-----".utf8)))]))
        a.config.set("terminal.fontSize", 17)
        let anonymous = try SyncClient(baseURL: URL(string: "http://localhost")!, transport: transport)
        let (sessionA, recovery) = try await AccountFlows.register(client: anonymous, email: "alex@example.com", password: "pw", device: device, kdf: kdf)
        try a.connect(sessionA, transport: transport)
        let first = try await a.engine!.sync()
        XCTAssertTrue(first.uploaded)

        // Mac B signs in with only the email and password and gets everything.
        let sessionB = try await AccountFlows.signIn(client: try SyncClient(baseURL: URL(string: "http://localhost")!, transport: transport),
                                                     email: "alex@example.com", password: "pw", device: device)
        XCTAssertEqual(sessionB.encryptionKey, sessionA.encryptionKey)
        try b.connect(sessionB, transport: transport)
        let restored = try await b.engine!.sync()
        XCTAssertTrue(restored.applied)
        XCTAssertEqual(b.profileNames, ["prod-web-01"])
        XCTAssertEqual(b.passwords.password(host: "prod.example.com", port: 22, user: "deploy"), "s3cret")
        XCTAssertEqual(b.config.value("terminal.fontSize")?.intValue, 17)
        let synced = b.keys.syncedKeys().resolve(keyPath, fileExists: { _ in false })
        XCTAssertEqual(FileManager.default.contents(atPath: synced), Data("-----KEY-----".utf8))
        XCTAssertEqual(b.engine!.recoveryKey, recovery.displayString)

        // An edit on B reaches A; a conflicting upload is merged.
        var profiles = b.config.value("profiles")!.arrayValue!
        profiles[0]["name"] = "prod-web-01 (renamed)"
        b.config.set("profiles", .array(profiles))
        a.config.set("profiles", .array(a.config.value("profiles")!.arrayValue! + [["id": "ssh:new", "type": "ssh", "name": "added on A",
                                                                                         "options": ["host": "new.example.com"]]]))
        _ = try await b.engine!.sync()
        _ = try await a.engine!.sync()
        _ = try await b.engine!.sync()
        XCTAssertEqual(a.profileNames, ["prod-web-01 (renamed)", "added on A"])
        XCTAssertEqual(b.profileNames, ["prod-web-01 (renamed)", "added on A"])

        // Removing B from A signs B out.
        let devices = try await a.engine!.client.devices()
        XCTAssertEqual(devices.count, 2)
        let other = try XCTUnwrap(devices.first { !$0.isCurrent })
        try await a.engine!.client.removeDevice(other.id)
        do {
            _ = try await b.engine!.sync()
            XCTFail("a removed device kept syncing")
        } catch let error as SyncClientError {
            XCTAssertEqual(error.code, ErrorDTO.Code.unauthorized)
        }
    }
}
