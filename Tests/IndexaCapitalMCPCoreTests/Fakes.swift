import Foundation
import Synchronization

@testable import IndexaCapitalMCPCore

/// A Keychain that holds an invented token, or fails the way the real one can.
final class FakeTokenSource: TokenSource {
    static let invented = "NOT-A-REAL-TOKEN"

    private let failure: ToolError?
    private let readCount = Mutex(0)

    init(failing failure: ToolError? = nil) {
        self.failure = failure
    }

    var reads: Int { readCount.withLock { $0 } }

    func token() async throws(ToolError) -> String {
        readCount.withLock { $0 += 1 }
        if let failure { throw failure }
        return Self.invented
    }
}

/// An API that answers every request with the same invented response and records what
/// it was asked.
final class FakeTransport: HTTPTransport {
    struct Unreachable: Error {}

    private let response: HTTPResponse?
    private let recorded = Mutex<[(request: URLRequest, byteLimit: Int)]>([])

    /// `nil` stands for a network that never answers.
    init(_ response: HTTPResponse?) {
        self.response = response
    }

    convenience init(status: Int = 200, body: String) {
        self.init(HTTPResponse(status: status, body: .success(Data(body.utf8))))
    }

    var requests: [(request: URLRequest, byteLimit: Int)] { recorded.withLock { $0 } }

    func get(_ request: URLRequest, byteLimit: Int) async throws -> HTTPResponse {
        recorded.withLock { $0.append((request, byteLimit)) }
        guard let response else { throw Unreachable() }
        return response
    }
}
