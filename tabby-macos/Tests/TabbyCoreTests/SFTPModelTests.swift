import XCTest
@testable import TabbyCore

/// The SFTP panel's models: paths and breadcrumbs, listing order and filter, the mode column,
/// safe local names, and transfer progress.
final class SFTPModelTests: XCTestCase {
    private func entry(_ name: String, dir: Bool = false, mode: UInt32 = 0o100644) -> SFTPEntry {
        SFTPEntry(name: name, path: SFTPPath.join("/srv", name), isDirectory: dir, isSymlink: false,
                  mode: dir ? 0o040755 : mode, size: 10, modified: Date(timeIntervalSince1970: 0))
    }

    func testPaths() {
        XCTAssertEqual(SFTPPath.join("/", "etc"), "/etc")
        XCTAssertEqual(SFTPPath.join("/srv/app/", "log"), "/srv/app/log")
        XCTAssertEqual(SFTPPath.parent("/srv/app"), "/srv")
        XCTAssertEqual(SFTPPath.parent("/srv"), "/")
        XCTAssertEqual(SFTPPath.parent("/"), "/")
        XCTAssertEqual(SFTPPath.normalize("//srv/./app/../www/"), "/srv/www")
        XCTAssertEqual(SFTPPath.normalize("/.."), "/")
        XCTAssertEqual(SFTPPath.normalize("relative/dir"), "/relative/dir")
        XCTAssertEqual(SFTPPath.breadcrumb("/srv/app").map(\.name), ["srv", "app"])
        XCTAssertEqual(SFTPPath.breadcrumb("/srv/app").map(\.path), ["/srv", "/srv/app"])
        XCTAssertTrue(SFTPPath.breadcrumb("/").isEmpty)
    }

    func testDirectoriesFirstThenByName() {
        let sorted = SFTPEntry.sorted([entry("b.txt"), entry("zeta", dir: true), entry("A.txt"), entry("alpha", dir: true), entry("file10"), entry("file9")])
        XCTAssertEqual(sorted.map(\.name), ["alpha", "zeta", "A.txt", "b.txt", "file9", "file10"])
    }

    func testFilterIsCaseInsensitiveAndBlankShowsAll() {
        let list = [entry("Nginx.conf"), entry("nginx-access.log"), entry("app.log")]
        XCTAssertEqual(SFTPEntry.filtered(list, by: "NGINX").map(\.name), ["Nginx.conf", "nginx-access.log"])
        XCTAssertEqual(SFTPEntry.filtered(list, by: "  ").count, 3)
    }

    func testModeColumnUsesTabbysTemplate() {
        XCTAssertEqual(SFTPEntry.modeString(0o040755), "  drwxr-xr-x")
        XCTAssertEqual(SFTPEntry.modeString(0o100644), "   rw-r--r--")
        XCTAssertEqual(SFTPEntry.modeString(0o104755), "S  rwxr-xr-x")
        XCTAssertEqual(SFTPEntry.modeString(0o102755), " G rwxr-xr-x")
        XCTAssertEqual(SFTPEntry.modeString(0o140777), "   rwxrwxrwx", "a socket is not a directory")
    }

    func testRemoteNamesCannotEscapeTheDownloadFolder() {
        XCTAssertEqual(SFTPPath.safeLocalName("report.pdf"), "report.pdf")
        XCTAssertNil(SFTPPath.safeLocalName(".."))
        XCTAssertNil(SFTPPath.safeLocalName("."))
        XCTAssertNil(SFTPPath.safeLocalName(""))
        XCTAssertNil(SFTPPath.safeLocalName("../../.ssh/authorized_keys"))
        XCTAssertNil(SFTPPath.safeLocalName("a/b"))
    }

    func testDownloadFolderNamesAvoidClashes() {
        XCTAssertEqual(SFTPPath.uniqueName("logs", exists: { _ in false }), "logs")
        XCTAssertEqual(SFTPPath.uniqueName("logs", exists: { ["logs", "logs (1)"].contains($0) }), "logs (2)")
    }

    func testTransferProgressAndSpeed() {
        var progress = TransferProgress(total: 1000, start: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(progress.fraction, 0)
        progress.record(bytes: 250, at: Date(timeIntervalSince1970: 100.5))
        XCTAssertEqual(progress.completed, 250)
        XCTAssertEqual(progress.fraction, 0.25)
        XCTAssertEqual(progress.bytesPerSecond, 500, accuracy: 0.001, "250 bytes in half a second")
        progress.record(bytes: 750, at: Date(timeIntervalSince1970: 101.0))
        XCTAssertEqual(progress.bytesPerSecond, 1500, accuracy: 0.001, "the last chunk's speed, like Tabby")
        XCTAssertTrue(progress.isComplete)
        XCTAssertEqual(TransferProgress(total: 0, start: Date()).fraction, 0, "unknown size")
    }
}
