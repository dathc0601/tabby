#if canImport(AppKit)
import XCTest
import TabbyCore
@testable import TabbySSHLib
@testable import TabbyApp

/// An in-memory server for the SFTP panel's model.
final class FakeSFTP: SFTPBrowsing {
    var directories: [String: [SFTPEntry]] = [:]
    var links: [String: String] = [:]
    var created: [String] = []
    var listed: [String] = []

    func add(_ path: String, dir: Bool = false, link: String? = nil, size: UInt64 = 1) {
        let parent = SFTPPath.parent(path)
        let entry = SFTPEntry(name: (path as NSString).lastPathComponent, path: path, isDirectory: dir, isSymlink: link != nil,
                              mode: dir ? 0o040755 : (link != nil ? 0o120777 : 0o100644), size: size, modified: Date(timeIntervalSince1970: 0))
        directories[parent, default: []].append(entry)
        if dir, directories[path] == nil { directories[path] = [] }
        if let link { links[path] = link }
    }

    func list(_ path: String) async throws -> [SFTPEntry] {
        listed.append(path)
        // Like a real server, opening a link to a folder lists the folder.
        guard let entries = directories[links[path] ?? path] else { throw SSHConnectionError.channelFailed("Cannot open \(path): No such file or directory") }
        return entries
    }

    func stat(_ path: String) async throws -> SFTPEntry {
        let resolved = links[path] ?? path
        if directories[resolved] != nil {
            return SFTPEntry(name: "", path: resolved, isDirectory: true, isSymlink: false, mode: 0o040755, size: 0, modified: Date())
        }
        return SFTPEntry(name: "", path: resolved, isDirectory: false, isSymlink: false, mode: 0o100644, size: 3, modified: Date())
    }

    func readLink(_ path: String) async throws -> String { links[path] ?? path }

    func makeDirectory(_ path: String, mode: UInt32) async throws {
        created.append(path)
        add(path, dir: true)
    }
}

@MainActor
final class SFTPPanelTests: XCTestCase {
    func makeServer() -> FakeSFTP {
        let server = FakeSFTP()
        server.directories["/"] = []
        server.add("/srv", dir: true)
        server.add("/srv/app", dir: true)
        server.add("/srv/app/b.log")
        server.add("/srv/app/A.txt")
        server.add("/srv/app/zeta", dir: true)
        server.add("/srv/app/current", link: "/srv/app/zeta")
        server.add("/srv/app/report", link: "/srv/app/A.txt")
        return server
    }

    func testTheStartPathIsTheShellsDirectoryThenTheLastOne() {
        XCTAssertEqual(SFTPPanelModel.startPath(shellDirectory: "/srv/app", last: "/tmp"), "/srv/app")
        XCTAssertEqual(SFTPPanelModel.startPath(shellDirectory: nil, last: "/tmp"), "/tmp")
        XCTAssertEqual(SFTPPanelModel.startPath(shellDirectory: nil, last: nil), "/")
    }

    func testListingIsSortedAndTheBreadcrumbFollows() async {
        let model = SFTPPanelModel(host: "prod", client: makeServer())
        await model.navigate(to: "/srv/app")
        XCTAssertEqual(model.path, "/srv/app")
        XCTAssertEqual(model.entries.map(\.name), ["zeta", "A.txt", "b.log", "current", "report"])
        XCTAssertEqual(model.breadcrumb.map(\.name), ["srv", "app"])
        XCTAssertTrue(model.canGoUp)
        await model.goUp()
        XCTAssertEqual(model.path, "/srv")
    }

    func testTheFilterNarrowsAndResetsOnNavigation() async {
        let model = SFTPPanelModel(host: "prod", client: makeServer())
        await model.navigate(to: "/srv/app")
        model.filterText = "LOG"
        XCTAssertEqual(model.entries.map(\.name), ["b.log"])
        XCTAssertFalse(model.canGoUp, "no Go up while filtering")
        model.filterText = "nothing"
        XCTAssertEqual(model.emptyMessage, "No files match the filter “nothing”")
        await model.navigate(to: "/srv")
        XCTAssertEqual(model.filterText, "")
    }

    func testAFolderThatCannotBeOpenedKeepsThePreviousOne() async {
        let model = SFTPPanelModel(host: "prod", client: makeServer())
        await model.navigate(to: "/srv")
        await model.navigate(to: "/root")
        XCTAssertEqual(model.path, "/srv")
        XCTAssertEqual(model.error, "Cannot open /root: No such file or directory")
    }

    func testTheFirstFolderFallsBackToTheRoot() async {
        let server = makeServer()
        let model = SFTPPanelModel(host: "prod", client: server)
        await model.navigate(to: "/gone")
        XCTAssertEqual(server.listed, ["/gone", "/"])
        XCTAssertEqual(model.path, "/")
        XCTAssertEqual(model.entries.map(\.name), ["srv"], "the root is listed")
        XCTAssertNotNil(model.error)
    }

    func testOpeningEntries() async {
        let model = SFTPPanelModel(host: "prod", client: makeServer())
        await model.navigate(to: "/srv/app")
        let current = model.entries.first { $0.name == "current" }!
        let action = await model.open(current)
        XCTAssertNil(action)
        XCTAssertEqual(model.path, "/srv/app/current", "a link to a folder opens at the link's path (Tabby)")
        await model.navigate(to: "/srv/app")
        let report = model.entries.first { $0.name == "report" }!
        let download = await model.open(report)
        XCTAssertEqual(download, .download(report))
    }

    func testCreatingAFolderOpensIt() async throws {
        let server = makeServer()
        let model = SFTPPanelModel(host: "prod", client: server)
        await model.navigate(to: "/srv")
        try await model.createDirectory(named: "releases")
        XCTAssertEqual(server.created, ["/srv/releases"])
        XCTAssertEqual(model.path, "/srv/releases")
        do {
            try await model.createDirectory(named: "a/b")
            XCTFail("created a nested name")
        } catch {}
    }
}
#endif
