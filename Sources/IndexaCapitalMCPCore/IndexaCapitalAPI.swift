import Foundation

/// Where the API token comes from, behind a protocol so the tests never touch the Keychain.
public protocol TokenSource: Sendable {
    func token() async throws(ToolError) -> String
}

/// What came back from one GET. `body` holds at most the byte limit the request was made
/// with plus one, so a body that would be cut short is detected rather than passed on as
/// though it were whole.
public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Result<Data, ReadFailure>

    public struct ReadFailure: Error, Sendable {
        public init() {}
    }

    public init(status: Int, body: Result<Data, ReadFailure>) {
        self.status = status
        self.body = body
    }
}

/// The network, behind a protocol so the tests drive every branch with invented answers.
public protocol HTTPTransport: Sendable {
    /// Throws only when no response arrived at all. A redirect is never followed: the 3xx
    /// itself is the response.
    func get(_ request: URLRequest, byteLimit: Int) async throws -> HTTPResponse
}

/// The one function that talks to Indexa Capital.
public struct IndexaCapitalAPI: Sendable {

    static let baseURL = "https://api.indexacapital.com"

    /// The longest response body accepted. Bounds what a single call can cost in memory.
    static let maximumBodyBytes = 1 << 20

    private let token: any TokenSource
    private let transport: any HTTPTransport

    public init(token: any TokenSource, transport: any HTTPTransport) {
        self.token = token
        self.transport = transport
    }

    /// The caller MUST build `path` from `ToolCatalog.Endpoint`: this validates nothing, so
    /// a second call site passing a path of its own would be a hole in the whitelist.
    func get(_ path: String) async throws(ToolError) -> String {
        let secret = try await token.token()
        guard let url = URL(string: Self.baseURL + path) else { throw .internalRequest }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(secret, forHTTPHeaderField: "X-AUTH-TOKEN")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response: HTTPResponse
        do {
            response = try await transport.get(request, byteLimit: Self.maximumBodyBytes)
        } catch {
            throw .network
        }
        // The status is checked before the body, so a redirect or an error page that could
        // not be read is still reported by its status. Only the status and the path are
        // ever reported, never a header or the token.
        guard response.status == 200 else { throw .httpStatus(response.status, path: path) }
        guard case .success(let body) = response.body else { throw .unreadableBody(path: path) }
        guard body.count <= Self.maximumBodyBytes else {
            throw .tooLarge(path: path, limit: Self.maximumBodyBytes)
        }
        // The API's own JSON, passed through. Invalid UTF-8, which JSON forbids anyway,
        // becomes U+FFFD rather than failing the call.
        return String(decoding: body, as: UTF8.self)
    }
}
