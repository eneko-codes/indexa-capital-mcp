import Foundation

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    /// Covers the whole call, body included, not just the wait for the first byte.
    public static let defaultTimeout: TimeInterval = 20

    /// Ephemeral, and with no cookie, cache or credential store: nothing about a call is
    /// written to disk. `protocolClasses` is for the tests, which answer requests in memory.
    public init(timeout: TimeInterval = URLSessionTransport.defaultTimeout) {
        self.init(timeout: timeout, protocolClasses: nil)
    }

    init(timeout: TimeInterval, protocolClasses: [AnyClass]?) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    public func get(_ request: URLRequest, byteLimit: Int) async throws -> HTTPResponse {
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        var body = Data()
        do {
            // One byte past the limit is enough to know the body would be cut short.
            for try await byte in bytes {
                body.append(byte)
                if body.count > byteLimit {
                    bytes.task.cancel()
                    break
                }
            }
        } catch {
            return HTTPResponse(status: status, body: .failure(.init()))
        }
        return HTTPResponse(status: status, body: .success(body))
    }
}

/// URLSession follows redirects anywhere by default and keeps custom headers on the way,
/// so `X-AUTH-TOKEN` would be replayed to whatever host a 3xx names. The catalogue pins
/// the method and the path; this pins the destination. A refused redirect comes back as
/// the response itself, and so is reported by its status.
final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
