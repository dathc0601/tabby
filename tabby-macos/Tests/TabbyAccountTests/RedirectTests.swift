import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TabbyAccount

/// The sync client only talks to the address it was given: a redirect (to plain HTTP or
/// elsewhere) is not followed.
final class RedirectTests: XCTestCase {
    final class RedirectingStub: URLProtocol {
        nonisolated(unsafe) static var followed: [URL] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let url = request.url!
            if url.scheme == "https" {
                let target = URL(string: "http://attacker.example/v1/vault")!
                let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                               headerFields: ["Location": target.absoluteString])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            } else {
                Self.followed.append(url)
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("{}".utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        }

        override func stopLoading() {}
    }

    func testRedirectsAreNotFollowed() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingStub.self]
        let transport = URLSessionTransport(configuration: configuration)
        var request = URLRequest(url: URL(string: "https://sync.example.com/v1/vault")!)
        request.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        let (_, response) = try await transport.send(request)
        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(RedirectingStub.followed, [], "the token never went to the redirect target")
    }
}
