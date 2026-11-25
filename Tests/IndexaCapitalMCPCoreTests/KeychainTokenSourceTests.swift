import Foundation
import Testing

@testable import IndexaCapitalMCPCore

/// The subprocess handling, driven by stand-in programs. None of these run `security`, so
/// the Keychain is never read.
@Suite("Keychain token source")
struct KeychainTokenSourceTests {

    private func source(_ path: String, _ arguments: [String], timeout: Duration = .seconds(5))
        -> KeychainTokenSource
    {
        KeychainTokenSource(executable: URL(fileURLWithPath: path), arguments: arguments, timeout: timeout)
    }

    @Test("What the program prints is the token, without surrounding whitespace")
    func printed() async throws {
        #expect(try await source("/bin/echo", ["  NOT-A-REAL-TOKEN "]).token() == "NOT-A-REAL-TOKEN")
    }

    @Test("A program that fails, or cannot be started, means the token could not be read")
    func failed() async {
        await #expect(throws: ToolError.keychainUnreadable) {
            try await source("/usr/bin/false", []).token()
        }
        await #expect(throws: ToolError.keychainUnreadable) {
            try await source("/nonexistent/security", []).token()
        }
    }

    /// A locked Keychain makes `security` wait on an unlock prompt.
    @Test("A program that does not finish in time is abandoned with its own error")
    func timedOut() async {
        let started = ContinuousClock.now
        await #expect(throws: ToolError.keychainTimedOut) {
            try await source("/bin/sleep", ["30"], timeout: .milliseconds(200)).token()
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("The real lookup names the service and the account, and asks for the password only")
    func realArguments() {
        let real = String(describing: KeychainTokenSource())
        #expect(real.contains("/usr/bin/security"))
        #expect(real.contains(#""find-generic-password", "-s", "indexa-capital-api", "-a""#))
        #expect(real.contains(#""-w""#))
    }
}
