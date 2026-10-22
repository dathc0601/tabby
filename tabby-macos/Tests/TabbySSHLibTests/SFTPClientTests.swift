#if os(macOS)
import XCTest
import TabbyCore
import TabbySSH
@testable import TabbySSHLib

/// SFTP against the test sshd's sftp-server. The server is this Mac, so remote paths are
/// paths in a temp folder that the test can also look at directly.
final class SFTPClientTests: XCTestCase {
    var sshd: TestSSHD!
    var connection: SSHConnection!
    var sftp: SFTPClient!
    var root: String!

    override func setUp() async throws {
        sshd = try TestSSHD()
        root = sshd.directory.appendingPathComponent("remote").resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        var options = SSHConnectionOptions(host: "127.0.0.1", port: sshd.port, user: sshd.user,
                                           knownHostsFile: sshd.directory.appendingPathComponent("known_hosts").path)
        options.privateKeys = [sshd.keyPath]
        options.globalKnownHostsFile = nil
        options.homeDirectory = sshd.directory.path
        connection = SSHConnection(options: options, prompter: ScriptedPrompter(), passwords: InMemoryPasswordStore())
        try await connection.connect()
        sftp = try await connection.sftp()
    }

    override func tearDown() async throws {
        connection.disconnect()
        sshd.stop()
    }

    func local(_ name: String) -> URL { URL(fileURLWithPath: root).appendingPathComponent(name) }

    func testListingStatAndDirectories() async throws {
        try Data("hello".utf8).write(to: local("b.txt"))
        try FileManager.default.createDirectory(at: local("logs"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: local("link").path, withDestinationPath: local("logs").path)
        try await sftp.makeDirectory(root + "/new dir")
        let names = try await sftp.list(root).map(\.name)
        XCTAssertEqual(Set(names), ["b.txt", "logs", "link", "new dir"], "no . or ..")
        let listed = try await sftp.list(root)
        let entries = SFTPEntry.sorted(listed)
        XCTAssertEqual(entries.first { $0.name == "b.txt" }?.size, 5)
        XCTAssertEqual(entries.first { $0.name == "logs" }?.isDirectory, true)
        XCTAssertEqual(entries.first { $0.name == "link" }?.isSymlink, true)
        let linkTarget = try await sftp.readLink(root + "/link")
        XCTAssertEqual(linkTarget, local("logs").path)
        let followed = try await sftp.stat(root + "/link")
        XCTAssertEqual(followed.isDirectory, true, "stat follows the link")
        let newDir = try await sftp.stat(root + "/new dir")
        XCTAssertEqual(SFTPEntry.modeString(newDir.mode).prefix(3), "  d")
        try await sftp.removeDirectory(root + "/new dir")
        XCTAssertFalse(FileManager.default.fileExists(atPath: local("new dir").path))
        let home = try await sftp.canonicalPath(".")
        XCTAssertTrue(home.hasPrefix("/"), home)
    }

    func testUploadAndDownloadInChunks() async throws {
        let payload = Data((0..<700_000).map { UInt8($0 % 251) })
        let source = sshd.directory.appendingPathComponent("upload.bin")
        try payload.write(to: source)
        var uploaded: [UInt64] = []
        try await sftp.upload(source, to: root + "/copy.bin", progress: { uploaded.append($0) }, isCancelled: { false })
        XCTAssertEqual(try Data(contentsOf: local("copy.bin")), payload)
        XCTAssertEqual(uploaded.reduce(0, +), UInt64(payload.count))
        XCTAssertGreaterThan(uploaded.count, 2, "several chunks")
        XCTAssertFalse(FileManager.default.fileExists(atPath: local("copy.bin.tabby-upload").path))

        let target = sshd.directory.appendingPathComponent("download.bin")
        var downloaded: UInt64 = 0
        try await sftp.download(root + "/copy.bin", to: target, progress: { downloaded += $0 }, isCancelled: { false })
        XCTAssertEqual(try Data(contentsOf: target), payload)
        XCTAssertEqual(downloaded, UInt64(payload.count))
    }

    func testAnUploadReplacesTheFileAndKeepsNoTempOnCancel() async throws {
        try Data("old".utf8).write(to: local("note.txt"))
        let source = sshd.directory.appendingPathComponent("note.txt")
        try Data("new".utf8).write(to: source)
        try await sftp.upload(source, to: root + "/note.txt", progress: { _ in }, isCancelled: { false })
        XCTAssertEqual(try String(contentsOf: local("note.txt"), encoding: .utf8), "new")

        let big = sshd.directory.appendingPathComponent("big.bin")
        try Data(count: 2_000_000).write(to: big)
        var chunks = 0
        do {
            try await sftp.upload(big, to: root + "/big.bin", progress: { _ in chunks += 1 }, isCancelled: { chunks >= 2 })
            XCTFail("a cancelled upload finished")
        } catch let error as SSHConnectionError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: local("big.bin.tabby-upload").path), "the partial upload is removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: local("big.bin").path))
    }

    func testRenameChmodAndRecursiveDelete() async throws {
        try FileManager.default.createDirectory(at: local("tree/a/b"), withIntermediateDirectories: true)
        for name in ["tree/1.txt", "tree/a/2.txt", "tree/a/b/3.txt"] { try Data(name.utf8).write(to: local(name)) }
        try await sftp.rename(root + "/tree/1.txt", to: root + "/tree/one.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: local("tree/one.txt").path))
        try await sftp.setMode(root + "/tree/one.txt", 0o600)
        let changed = try await sftp.stat(root + "/tree/one.txt")
        XCTAssertEqual(changed.mode & 0o777, 0o600)
        var removed: [String] = []
        try await sftp.removeRecursively(root + "/tree", progress: { removed.append($0) }, isCancelled: { false })
        XCTAssertFalse(FileManager.default.fileExists(atPath: local("tree").path), "every unlink finished before the rmdir")
        XCTAssertEqual(removed.count, 6, "\(removed)")
    }

    func testErrorsSayWhatFailed() async throws {
        do {
            _ = try await sftp.list(root + "/missing")
            XCTFail("listed a missing folder")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No such file"), error.localizedDescription)
        }
    }

    func testOneSFTPSessionPerConnection() async throws {
        let again = try await connection.sftp()
        XCTAssertTrue(again === sftp)
    }
}
#endif
