#if os(macOS)
import XCTest
@testable import TabbySSHLib

/// Review I4: a proxy that accepts but never answers fails within the timeout.
final class ProxyTunnelTests: XCTestCase {
    func testASilentProxyTimesOut() throws {
        let silent = try PortListenerHog()   // the kernel accepts; nothing ever answers
        defer { silent.stop() }
        let done = expectation(description: "handshake ended")
        var failure: Error?
        let started = Date()
        Thread {
            do {
                let fd = try ProxyTunnel.open(.http(host: "127.0.0.1", port: silent.port), to: "target", port: 22, timeout: 1)
                close(fd)
            } catch {
                failure = error
            }
            done.fulfill()
        }.start()
        wait(for: [done], timeout: 8)
        XCTAssertEqual(failure as? SSHConnectionError, .connectFailed("Proxy: no answer from the proxy"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }
}
#endif
