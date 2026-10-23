#if canImport(AppKit)
import XCTest
import AppKit
import SwiftUI
import TabbyCore
@testable import TabbySSHLib
@testable import TabbyApp

/// An in-memory server for the SFTP panel's model.
final class FakeSFTP: SFTPOperations {
    func download(_ path: String, to local: URL, progress: (UInt64) -> Void, isCancelled: () -> Bool) async throws {}
    func upload(_ local: URL, to path: String, mode: UInt32, progress: (UInt64) -> Void, isCancelled: () -> Bool) async throws {}
    func removeFile(_ path: String) async throws {}
    func removeRecursively(_ path: String, progress: (String) -> Void, isCancelled: () -> Bool) async throws {}

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

    private func views(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(views) }

    /// The panel covers the bottom 80% of the pane; a click on the terminal above closes it.
    func testThePaneShowsThePanelOverItsLowerPart() throws {
        TestApp.boot()
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        c.model.openTab()
        let window = try XCTUnwrap(c.window)
        TestApp.pump(until: { self.views(window.contentView!).contains { $0 is PaneContainerView } })
        let container = try XCTUnwrap(views(window.contentView!).compactMap { $0 as? PaneContainerView }.first)
        let controller = SFTPPanelController(model: SFTPPanelModel(host: "prod", client: makeServer()), client: makeServer(),
                                             paneID: container.pane.id, owner: ObjectIdentifier(self))
        SFTPPanels.shared.present(controller)
        TestApp.pump(until: { container.subviews.contains { $0 is NSHostingView<SFTPPanelView> } })
        container.layoutSubtreeIfNeeded()
        TestApp.pump(0.3)
        let panel = try XCTUnwrap(container.subviews.first { $0 is NSHostingView<SFTPPanelView> })
        XCTAssertEqual(panel.frame.height, (container.bounds.height * 0.8).rounded(), accuracy: 1)
        XCTAssertEqual(panel.frame.maxY, container.bounds.maxY, accuracy: 1, "flush with the bottom (flipped view)")
        let catcher = try XCTUnwrap(container.subviews.first { $0 is SFTPDismissCatcher } as? SFTPDismissCatcher)
        XCTAssertEqual(catcher.frame.maxY, panel.frame.minY, accuracy: 1)
        catcher.dismiss()
        TestApp.pump(until: { SFTPPanels.shared.controllers[container.pane.id] == nil })
        TestApp.pump(until: { !container.subviews.contains { $0 is NSHostingView<SFTPPanelView> } })
        XCTAssertFalse(container.subviews.contains { $0 is SFTPDismissCatcher })
    }

    /// Found in the M8 walk: double-clicking the breadcrumb showed the path field without the
    /// keys; ⌘A then selected the terminal's text.
    func testTypingAPathStartsInItsField() throws {
        TestApp.boot()
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        c.model.openTab()
        let window = try XCTUnwrap(c.window)
        TestApp.pump(until: { self.views(window.contentView!).contains { $0 is PaneContainerView } })
        let container = try XCTUnwrap(views(window.contentView!).compactMap { $0 as? PaneContainerView }.first)
        let model = SFTPPanelModel(host: "prod", client: makeServer())
        let controller = SFTPPanelController(model: model, client: makeServer(), paneID: container.pane.id, owner: ObjectIdentifier(self))
        SFTPPanels.shared.present(controller)
        defer { SFTPPanels.shared.close(container.pane.id) }
        TestApp.pump(until: { container.subviews.contains { $0 is NSHostingView<SFTPPanelView> } })
        let panel = try XCTUnwrap(container.subviews.first { $0 is NSHostingView<SFTPPanelView> })

        model.editPath()
        func pathField() -> NSTextField? {
            guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                  let field = editor.delegate as? NSTextField, field.isDescendant(of: panel),
                  field.placeholderString == "Path" else { return nil }
            return field
        }
        TestApp.pump(until: { pathField() != nil }, timeout: 2)
        TestApp.pump(0.2)
        XCTAssertNotNil(pathField(), "keys go to \(String(describing: window.firstResponder))")
        XCTAssertEqual(pathField()?.stringValue, model.path, "it starts with the current path")
    }

    /// Review C2/C3: a session's panel closes when the session ends.
    func testASessionsPanelClosesWhenItEnds() {
        let owner = NSObject()
        let pane = UUID()
        let controller = SFTPPanelController(model: SFTPPanelModel(host: "prod", client: makeServer()), client: makeServer(),
                                             paneID: pane, owner: ObjectIdentifier(owner))
        SFTPPanels.shared.present(controller)
        SFTPPanels.shared.close(owner: ObjectIdentifier(NSObject()))
        XCTAssertNotNil(SFTPPanels.shared.controllers[pane])
        SFTPPanels.shared.close(owner: ObjectIdentifier(owner))
        XCTAssertNil(SFTPPanels.shared.controllers[pane])
    }

    /// Review I7: Edit-locally watchers outlive the panel and end with their session.
    func testEditWatchersEndWithTheirSessionNotThePanel() throws {
        let watchers = LocalEditWatchers()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Both alive for the whole test: a freed object's address (and identifier) is reused.
        let sessionA = NSObject()
        let sessionB = NSObject()
        let a = ObjectIdentifier(sessionA)
        let b = ObjectIdentifier(sessionB)
        defer { withExtendedLifetime((sessionA, sessionB)) {} }
        XCTAssertTrue(watchers.watch(folder: folder, owner: a) {})
        XCTAssertTrue(watchers.watch(folder: folder, owner: a) {})
        XCTAssertTrue(watchers.watch(folder: folder, owner: b) {})
        XCTAssertEqual(watchers.count(owner: a), 2)
        watchers.cancel(owner: a)
        XCTAssertEqual(watchers.count(owner: a), 0)
        XCTAssertEqual(watchers.count(owner: b), 1)
    }

    func testTheHotkeyNeedsAConnectedLibrarySession() throws {
        TestApp.boot()
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        c.model.openTab()
        XCTAssertFalse(c.runCommand("open-sftp"), "a local shell has no SFTP")
        XCTAssertTrue(SFTPPanels.shared.controllers.isEmpty)
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
