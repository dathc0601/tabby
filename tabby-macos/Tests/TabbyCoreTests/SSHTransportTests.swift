import XCTest
@testable import TabbyCore

/// Pure pieces of the library backend's transport: forward labels, the SOCKS5 server behind
/// dynamic forwards, the SOCKS5 / HTTP CONNECT client for proxied profiles, X11 displays.
final class SSHTransportTests: XCTestCase {
    // MARK: Forward labels (Tabby's ForwardedPort.toString)

    func testForwardSummariesReadLikeTabby() {
        XCTAssertEqual(ForwardedPort(type: .local, port: 8000, targetAddress: "127.0.0.1", targetPort: 80).summary,
                       "(local) 127.0.0.1:8000 → (remote) 127.0.0.1:80")
        XCTAssertEqual(ForwardedPort(type: .remote, host: "0.0.0.0", port: 9000, targetAddress: "localhost", targetPort: 3000).summary,
                       "(remote) 0.0.0.0:9000 → (local) localhost:3000")
        XCTAssertEqual(ForwardedPort(type: .dynamic, port: 1080).summary, "(dynamic) 127.0.0.1:1080")
    }

    // MARK: SOCKS5 server (dynamic forwards)

    func testSOCKS5GreetingAcceptsNoAuthOnly() {
        XCTAssertEqual(SOCKS5.parseGreeting([5, 2]), .needMore)
        XCTAssertEqual(SOCKS5.parseGreeting([5, 2, 2, 0]), .done(SOCKS5.noAuthAccepted, consumed: 4))
        XCTAssertEqual(SOCKS5.parseGreeting([5, 1, 2]), .done(SOCKS5.noAcceptableMethod, consumed: 3))
        XCTAssertEqual(SOCKS5.parseGreeting([4, 1, 0, 80]), .failure("not SOCKS5"))
    }

    func testSOCKS5ConnectRequestsGiveTheTarget() {
        // IPv4
        XCTAssertEqual(SOCKS5.parseConnect([5, 1, 0, 1, 10, 0, 0, 7, 0x1F, 0x90]),
                       .done(SOCKS5.Target(host: "10.0.0.7", port: 8080), consumed: 10))
        // Domain name
        let name = Array("db.internal".utf8)
        XCTAssertEqual(SOCKS5.parseConnect([5, 1, 0, 3, UInt8(name.count)] + name + [0, 22]),
                       .done(SOCKS5.Target(host: "db.internal", port: 22), consumed: 5 + name.count + 2))
        // IPv6 ::1
        XCTAssertEqual(SOCKS5.parseConnect([5, 1, 0, 4] + [UInt8](repeating: 0, count: 15) + [1, 0, 80]),
                       .done(SOCKS5.Target(host: "::1", port: 80), consumed: 22))
        XCTAssertEqual(SOCKS5.parseConnect([5, 1, 0, 3, 10, 0x61]), .needMore)
        XCTAssertEqual(SOCKS5.parseConnect([5, 2, 0, 1, 0, 0, 0, 0, 0, 0]), .failure("only CONNECT is supported"))
    }

    func testSOCKS5Replies() {
        XCTAssertEqual(SOCKS5.reply(.succeeded), [5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(SOCKS5.reply(.commandNotSupported)[1], 7)
        XCTAssertEqual(SOCKS5.reply(.connectionRefused)[1], 5)
    }

    // MARK: SOCKS5 client (socksProxyHost)

    func testSOCKS5ClientConnectsByName() {
        XCTAssertEqual(SOCKS5.clientGreeting, [5, 1, 0])
        XCTAssertEqual(SOCKS5.connectRequest(host: "prod", port: 2222), [5, 1, 0, 3, 4] + Array("prod".utf8) + [0x08, 0xAE])
        XCTAssertEqual(SOCKS5.parseServerChoice([5, 0]), .done(0, consumed: 2))
        XCTAssertEqual(SOCKS5.parseServerChoice([5, 0xFF]), .failure("the SOCKS proxy wants authentication"))
        XCTAssertEqual(SOCKS5.parseConnectReply([5, 0, 0, 1, 1, 2, 3, 4, 0, 80]), .done(0, consumed: 10))
        XCTAssertEqual(SOCKS5.parseConnectReply([5, 5, 0, 1, 0, 0, 0, 0, 0, 0]),
                       .failure("the SOCKS proxy could not connect (connection refused)"))
        XCTAssertEqual(SOCKS5.parseConnectReply([5, 0, 0, 3, 3, 0x61]), .needMore)
    }

    // MARK: HTTP CONNECT client (httpProxyHost)

    func testHTTPConnect() {
        XCTAssertEqual(HTTPConnect.request(host: "prod", port: 22), "CONNECT prod:22 HTTP/1.1\r\nHost: prod:22\r\n\r\n")
        XCTAssertEqual(HTTPConnect.request(host: "::1", port: 22), "CONNECT [::1]:22 HTTP/1.1\r\nHost: [::1]:22\r\n\r\n")
        XCTAssertEqual(HTTPConnect.parseResponse(Array("HTTP/1.1 200 Connection established\r\n".utf8)), .needMore)
        let ok = Array("HTTP/1.1 200 Connection established\r\nProxy-Agent: x\r\n\r\n".utf8)
        XCTAssertEqual(HTTPConnect.parseResponse(ok + [0x53, 0x53]), .done(200, consumed: ok.count),
                       "bytes after the header (the SSH banner) are left for libssh")
        XCTAssertEqual(HTTPConnect.parseResponse(Array("HTTP/1.0 407 Proxy Authentication Required\r\n\r\n".utf8)),
                       .failure("the HTTP proxy answered 407 Proxy Authentication Required"))
    }

    // MARK: X11 display (Tabby's X11Socket.resolveDisplaySpec)

    func testX11Displays() {
        XCTAssertEqual(X11Display.resolve(nil, environment: nil), .tcp(host: "localhost", port: 6000), "the fallback is localhost:0")
        XCTAssertEqual(X11Display.resolve(nil, environment: ":0"), .socket(path: "/tmp/.X11-unix/X0"))
        XCTAssertEqual(X11Display.resolve("localhost:1", environment: ":0"), .tcp(host: "localhost", port: 6001), "the setting wins")
        XCTAssertEqual(X11Display.resolve(":1", environment: nil), .socket(path: "/tmp/.X11-unix/X1"))
        XCTAssertEqual(X11Display.resolve("localhost:10.0", environment: nil), .tcp(host: "localhost", port: 6010))
        XCTAssertEqual(X11Display.resolve("10.0.0.5:2", environment: nil), .tcp(host: "10.0.0.5", port: 6002))
        XCTAssertEqual(X11Display.resolve("unix:3", environment: nil), .socket(path: "/tmp/.X11-unix/X3"))
        XCTAssertEqual(X11Display.resolve(nil, environment: "/private/tmp/com.apple.launchd.abc/org.xquartz:0"),
                       .socket(path: "/private/tmp/com.apple.launchd.abc/org.xquartz:0"),
                       "XQuartz's DISPLAY is the socket path (Tabby drops the :0 here)")
        XCTAssertEqual(X11Display.resolve("host:6001", environment: nil), .tcp(host: "host", port: 6001), "displays from 100 are ports")
    }
}
