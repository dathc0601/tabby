import XCTest
@testable import TabbyCLIKit

/// Phase 5: the `tabby` helper, run as a process. `TABBYMAC_CLI_DRY_RUN=1` makes it print the
/// link it would hand to the app, so no app starts in tests.
final class HelperProcessTests: XCTestCase {
    var productsDirectory: URL {
        #if os(macOS)
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("no .xctest bundle")
        #else
        return Bundle.main.bundleURL
        #endif
    }

    struct Run { let status: Int32; let out: String; let err: String }

    func tabby(_ args: [String], stdin: String? = nil, cwd: URL? = nil) throws -> Run {
        let process = Process()
        process.executableURL = productsDirectory.appendingPathComponent("tabby")
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["TABBYMAC_CLI_DRY_RUN"] = "1"
        process.environment = env
        if let cwd { process.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input
        try process.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try input.fileHandleForWriting.close()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, out: String(decoding: o, as: UTF8.self), err: String(decoding: e, as: UTF8.self))
    }

    func testHelpVersionAndUsageErrors() throws {
        let help = try tabby(["--help"])
        XCTAssertEqual(help.status, 0)
        XCTAssertTrue(help.out.contains("tabby [command] [arguments]"), help.out)
        let version = try tabby(["--version"])
        XCTAssertEqual(version.status, 0)
        XCTAssertFalse(version.out.isEmpty)
        let bad = try tabby(["recent", "first"])
        XCTAssertEqual(bad.status, 2)
        XCTAssertTrue(bad.err.contains("recent needs an index"), bad.err)
    }

    func testPathsAreResolvedWhereTheHelperRuns() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tabby-cli-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let open = try tabby(["open", "sub"], cwd: dir)
        XCTAssertEqual(open.status, 0, open.err)
        let url = try XCTUnwrap(URL(string: open.out.trimmingCharacters(in: .whitespacesAndNewlines)))
        guard case let .open(directory)? = TabbyURL.parse(url) else { return XCTFail(open.out) }
        XCTAssertEqual(directory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       dir.appendingPathComponent("sub").resolvingSymlinksInPath().path)
        let here = try tabby(["open"], cwd: dir)
        guard case .open(let d)? = TabbyURL.parse(URL(string: here.out.trimmingCharacters(in: .whitespacesAndNewlines))!) else { return XCTFail(here.out) }
        XCTAssertNotNil(d, "no directory means the helper's own")
        let run = try tabby(["run", "ls", "-la"], cwd: dir)
        guard case let .run(command, runCwd)? = TabbyURL.parse(URL(string: run.out.trimmingCharacters(in: .whitespacesAndNewlines))!) else { return XCTFail(run.out) }
        XCTAssertEqual(command, ["ls", "-la"])
        XCTAssertNotNil(runCwd)
    }

    func testPasteReadsStandardInput() throws {
        let run = try tabby(["paste"], stdin: "git status\n")
        XCTAssertEqual(run.status, 0, run.err)
        let url = try XCTUnwrap(URL(string: run.out.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(TabbyURL.parse(url), .paste(text: "git status", escape: false), "★ one trailing newline (from echo) is dropped")
    }

    func testNoArgumentsOnlyStartsTheApp() throws {
        let run = try tabby([])
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.out.trimmingCharacters(in: .whitespacesAndNewlines), "launch")
    }
}
