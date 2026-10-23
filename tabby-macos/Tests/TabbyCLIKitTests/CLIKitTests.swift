import XCTest
@testable import TabbyCLIKit

/// Phase 5: Tabby's command line (`app/lib/cli.ts`) and its URLs (`app/lib/urlHandler.ts`),
/// with TabbyMac's `tabbymac://` scheme, plus `ssh://` and `telnet://` links.
final class CLIArgumentsTests: XCTestCase {
    func parse(_ args: String...) -> CLIArguments.Outcome? { try? CLIArguments.parse(args).get() }
    func error(_ args: String...) -> String? {
        if case .failure(let e) = CLIArguments.parse(args) { return e.message }
        return nil
    }

    func testNoArgumentsJustLaunches() {
        XCTAssertEqual(parse(), .launch)
    }

    func testTabbysCommands() {
        XCTAssertEqual(parse("open"), .request(.open(directory: nil)))
        XCTAssertEqual(parse("open", "~/src"), .request(.open(directory: "~/src")))
        XCTAssertEqual(parse("run", "ls", "-la"), .request(.run(command: ["ls", "-la"], cwd: nil)), "everything after run is the command")
        XCTAssertEqual(parse("/k", "top"), .request(.run(command: ["top"], cwd: nil)), "Tabby's alias")
        XCTAssertEqual(parse("run", "--", "--weird"), .request(.run(command: ["--weird"], cwd: nil)))
        XCTAssertEqual(parse("profile", "Router console"), .request(.profile(name: "Router console")))
        XCTAssertEqual(parse("paste", "hello"), .request(.paste(text: "hello", escape: false)))
        XCTAssertEqual(parse("paste", "-e", "a b"), .request(.paste(text: "a b", escape: true)))
        XCTAssertEqual(parse("paste", "--escape"), .request(.paste(text: nil, escape: true)), "★ no text: standard input")
        XCTAssertEqual(parse("recent", "0"), .request(.recent(index: 0)), "★ the positional (Tabby reads profileNumber)")
        XCTAssertEqual(parse("quickConnect", "ssh", "me@host:2222"), .request(.quickConnect(providerId: "ssh", query: "me@host:2222")))
        XCTAssertEqual(parse("quickconnect", "telnet", "switch.lan"), .request(.quickConnect(providerId: "telnet", query: "switch.lan")))
        XCTAssertEqual(parse("./deploy.sh"), .request(.path("./deploy.sh")), "a bare path (OpenPathCLIHandler)")
    }

    func testHelpAndVersion() {
        XCTAssertEqual(parse("--help"), .help)
        XCTAssertEqual(parse("-h"), .help)
        XCTAssertEqual(parse("--version"), .version)
        XCTAssertTrue(CLIArguments.usage.contains("tabby [command] [arguments]"))
        for command in ["open", "run", "profile", "paste", "recent", "quickConnect"] {
            XCTAssertTrue(CLIArguments.usage.contains(command), command)
        }
    }

    func testUsageErrors() {
        XCTAssertNotNil(error("run"))
        XCTAssertNotNil(error("profile"))
        XCTAssertNotNil(error("recent", "first"))
        XCTAssertNotNil(error("recent", "-1"))
        XCTAssertNotNil(error("quickConnect", "ssh"))
        XCTAssertNotNil(error("--bogus"))
        XCTAssertNotNil(error("open", "a", "b"))
    }

    /// A Finder or Xcode launch adds `-psn_…` and `-NS… value` pairs.
    func testAppLaunchArgumentsDropApplesFlags() {
        XCTAssertEqual(CLIArguments.appLaunchArguments(["-psn_0_12345"]), [])
        XCTAssertEqual(CLIArguments.appLaunchArguments(["-NSDocumentRevisionsDebugMode", "YES", "open", "/tmp"]), ["open", "/tmp"])
        XCTAssertEqual(CLIArguments.appLaunchArguments(["-AppleLanguages", "(de)"]), [])
    }
}

final class TabbyURLTests: XCTestCase {
    func url(_ s: String) -> URL { URL(string: s)! }

    func testTabbyMacURLsCarryTheCommands() {
        XCTAssertEqual(TabbyURL.parse(url("tabbymac://open?directory=/tmp/x")), .open(directory: "/tmp/x"))
        XCTAssertEqual(TabbyURL.parse(url("tabbymac://run?command=ls%20-la%20'my%20dir'")), .run(command: ["ls", "-la", "my dir"], cwd: nil),
                       "one shell-quoted string, as Tabby's links")
        XCTAssertEqual(TabbyURL.parse(url("tabbymac://profile?profileName=Router%20console")), .profile(name: "Router console"))
        XCTAssertEqual(TabbyURL.parse(url("tabbymac://paste?text=hi&escape=true")), .paste(text: "hi", escape: true))
        XCTAssertEqual(TabbyURL.parse(url("tabbymac://paste?text=hi&escape")), .paste(text: "hi", escape: true), "an empty value is true")
        XCTAssertEqual(TabbyURL.parse(url("tabbymac://recent?profileNumber=2")), .recent(index: 2))
        XCTAssertEqual(TabbyURL.parse(url("tabbymac://QUICKCONNECT?providerId=ssh&query=me@host")), .quickConnect(providerId: "ssh", query: "me@host"),
                       "commands match whatever the case (xdg-open lowercases hosts)")
        XCTAssertEqual(TabbyURL.parse(url("tabbymac:quickConnect?providerId=serial&query=/dev/cu.x@9600")), .quickConnect(providerId: "serial", query: "/dev/cu.x@9600"))
        XCTAssertNil(TabbyURL.parse(url("tabbymac://nope")))
        XCTAssertNil(TabbyURL.parse(url("tabbymac://profile")), "a missing argument")
        XCTAssertNil(TabbyURL.parse(url("https://example.com")))
    }

    func testSSHLinks() {
        XCTAssertEqual(TabbyURL.parse(url("ssh://example.org")), .quickConnect(providerId: "ssh", query: "example.org"))
        XCTAssertEqual(TabbyURL.parse(url("ssh://deploy@example.org:2222")), .quickConnect(providerId: "ssh", query: "deploy@example.org:2222"))
        XCTAssertEqual(TabbyURL.parse(url("ssh://j%40doe@example.org")), .quickConnect(providerId: "ssh", query: "j@doe@example.org"), "Tabby takes the user up to the last @")
        XCTAssertEqual(TabbyURL.parse(url("ssh://me;fingerprint=ssh-dss-c1-b1@example.org")), .quickConnect(providerId: "ssh", query: "me@example.org"), "RFC 4248 parameters are dropped")
        XCTAssertEqual(TabbyURL.parse(url("ssh://[::1]:22/ignored?x=1")), .quickConnect(providerId: "ssh", query: "[::1]:22"))
        XCTAssertNil(TabbyURL.parse(url("ssh://")))
    }

    func testTelnetLinks() {
        XCTAssertEqual(TabbyURL.parse(url("telnet://switch.lan")), .quickConnect(providerId: "telnet", query: "switch.lan"))
        XCTAssertEqual(TabbyURL.parse(url("telnet://192.168.1.2:2323/")), .quickConnect(providerId: "telnet", query: "192.168.1.2:2323"))
        XCTAssertEqual(TabbyURL.parse(url("TELNET://[fe80::1]:23")), .quickConnect(providerId: "telnet", query: "[fe80::1]:23"))
    }

    func testEveryRequestSurvivesTheRoundTrip() {
        let requests: [CLIRequest] = [
            .open(directory: nil), .open(directory: "/Users/me/my project"),
            .run(command: ["sh", "-c", "echo 'a b' && ls"], cwd: "/tmp"), .run(command: ["top"], cwd: nil),
            .run(command: ["/Applications/My App/foo"], cwd: "/tmp"),
            .profile(name: "Router · console & co"), .paste(text: "line 1\nline 2 %20", escape: false), .paste(text: "x", escape: true),
            .recent(index: 3), .quickConnect(providerId: "ssh", query: "me@[::1]:22"), .path("/Users/me/deploy.sh"),
        ]
        for request in requests {
            let encoded = TabbyURL.encode(request)
            XCTAssertEqual(encoded.scheme, "tabbymac")
            XCTAssertEqual(TabbyURL.parse(encoded), request, encoded.absoluteString)
        }
    }

    func testShellWords() {
        XCTAssertEqual(ShellWords.split(#"ls -la "my dir" 'it''s' a\ b"#), ["ls", "-la", "my dir", "its", "a b"])
        XCTAssertEqual(ShellWords.quote("it's here"), #"'it'\''s here'"#)
        XCTAssertEqual(ShellWords.quote("plain"), "plain")
        XCTAssertEqual(ShellWords.split(ShellWords.quote("a 'b' \"c\"")), ["a 'b' \"c\""])
    }
}
