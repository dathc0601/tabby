import XCTest
@testable import TabbyCore

/// Phase 6: Tabby's linkifier (`tabby-linkifier/src/handlers.ts`): what a clicked link opens,
/// and the bare IPv4 / `www.` forms SwiftTerm doesn't detect.
final class LinkTests: XCTestCase {
    let files: Set<String> = ["/Users/me/src/main.swift", "/Users/me/notes.txt", "/etc/hosts"]

    func resolve(_ link: String, cwd: String? = "/Users/me/src", local: Bool = true) -> LinkTarget? {
        LinkTarget.resolve(link, cwd: cwd, home: "/Users/me", local: local) { self.files.contains($0) }
    }

    func testURLs() {
        XCTAssertEqual(resolve("https://example.com/a?b=1"), .web("https://example.com/a?b=1"))
        XCTAssertEqual(resolve("mailto:me@example.com"), .web("mailto:me@example.com"))
        XCTAssertEqual(resolve("192.168.1.10"), .web("http://192.168.1.10"), "Tabby's IPHandler")
        XCTAssertEqual(resolve("10.0.0.1:8080/status"), .web("http://10.0.0.1:8080/status"))
        XCTAssertEqual(resolve("www.example.com"), .web("http://www.example.com"))
        XCTAssertNil(resolve("javascript:alert(1)"), "only schemes that are safe to hand over")
        XCTAssertNil(resolve("smb://server/share"))
    }

    func testSSHAndTelnetOpenATab() {
        XCTAssertEqual(resolve("ssh://me@host:2222"), .quickConnect("ssh://me@host:2222"))
        XCTAssertEqual(resolve("telnet://10.0.0.1"), .quickConnect("telnet://10.0.0.1"))
    }

    func testPathsAreResolvedAgainstThePaneFolder() {
        XCTAssertEqual(resolve("/etc/hosts"), .file("/etc/hosts"))
        XCTAssertEqual(resolve("main.swift:12:4"), .file("/Users/me/src/main.swift"), "the line and column go")
        XCTAssertEqual(resolve("./main.swift"), .file("/Users/me/src/main.swift"))
        XCTAssertEqual(resolve("../notes.txt"), .file("/Users/me/notes.txt"))
        XCTAssertEqual(resolve("~/notes.txt"), .file("/Users/me/notes.txt"))
        XCTAssertEqual(resolve("file:///etc/hosts"), .file("/etc/hosts"))
        XCTAssertNil(resolve("file://server/etc/hosts"), "Tabby: file links with a host are not followed")
        XCTAssertNil(resolve("/nope/missing.txt"), "only files that exist")
        XCTAssertNil(resolve("main.swift", cwd: nil), "a relative path needs the folder")
        XCTAssertNil(resolve("/etc/hosts", local: false), "a remote pane's paths are not this Mac's")
    }

    func testTheExtraFormsAreFoundAroundTheClick() {
        let line = "ping 192.168.1.10 then open www.example.com/x ok"
        XCTAssertEqual(LinkDetector.match(in: line, at: 8), "192.168.1.10")
        XCTAssertEqual(LinkDetector.match(in: line, at: 32), "www.example.com/x")
        XCTAssertNil(LinkDetector.match(in: line, at: 1))
        XCTAssertNil(LinkDetector.match(in: "version 1.2.3.4.5", at: 10), "not an address")
    }

    func testTheModifierSetting() {
        XCTAssertEqual(LinkModifier(config: nil), .none)
        XCTAssertEqual(LinkModifier(config: "altKey"), .option)
        XCTAssertEqual(LinkModifier(config: "shiftKey"), .shift)
        XCTAssertEqual(LinkModifier(config: "metaKey"), .command)
        XCTAssertEqual(LinkModifier(config: "ctrlKey"), .control, "read from a Tabby config, not offered")
        XCTAssertEqual(LinkModifier(config: "bogus"), .none)
    }
}
