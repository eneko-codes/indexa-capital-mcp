import Foundation
import Synchronization

/// Reads the token by running `security find-generic-password`, once per call, so a token
/// regenerated in the Keychain is picked up without a restart.
///
/// A subprocess rather than `SecItemCopyMatching`: the README creates the item with
/// `security add-generic-password`, which puts `/usr/bin/security` on the item's access
/// list. Reading it through `security` therefore never shows an access prompt, whatever
/// this binary's signature, while reading it through the Keychain API from this process
/// would prompt after every ad-hoc rebuild.
public struct KeychainTokenSource: TokenSource {

    static let service = "indexa-capital-api"

    /// A locked Keychain makes `security` wait on a GUI unlock prompt. Without a limit the
    /// call stalls with no explanation instead of answering with an error the client can show.
    static let defaultTimeout = Duration.seconds(10)

    private let executable: URL
    private let arguments: [String]
    private let timeout: Duration

    /// Matches on service AND account, because a generic password is keyed by both: looking
    /// up on service alone would pick arbitrarily between two items made under different
    /// account names. The account is `$USER`, as in the README's add-generic-password command.
    public init() {
        self.init(
            executable: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: [
                "find-generic-password", "-s", Self.service,
                "-a", ProcessInfo.processInfo.environment["USER"] ?? "", "-w",
            ],
            timeout: Self.defaultTimeout)
    }

    /// For the tests, which run a stand-in program instead of `security`.
    init(executable: URL, arguments: [String], timeout: Duration) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
    }

    private enum Outcome: Sendable {
        case printed(Data)
        case failed
        case timedOut
    }

    /// Only the first caller resumes; a later one finds it empty and is told so.
    private final class ResumeOnce: Sendable {
        private let continuation: Mutex<CheckedContinuation<Outcome, Never>?>

        init(_ continuation: CheckedContinuation<Outcome, Never>) {
            self.continuation = Mutex(continuation)
        }

        @discardableResult
        func resume(_ outcome: Outcome) -> Bool {
            continuation.withLock { pending in
                guard let waiting = pending else { return false }
                pending = nil
                waiting.resume(returning: outcome)
                return true
            }
        }
    }

    public func token() async throws(ToolError) -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        // What `security` says on failure can name the item; it is dropped, not relayed.
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output

        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18

        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let once = ResumeOnce(continuation)
            do {
                try process.run()
            } catch {
                once.resume(.failed)
                return
            }
            // Dispatch, not the cooperative pool: reading the pipe blocks until the program
            // exits, which is up to the whole timeout.
            DispatchQueue.global().async {
                let printed = (try? output.fileHandleForReading.readToEnd()) ?? Data()
                process.waitUntilExit()
                let succeeded = process.terminationReason == .exit && process.terminationStatus == 0
                once.resume(succeeded ? .printed(printed) : .failed)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if once.resume(.timedOut) { process.terminate() }
            }
        }

        switch outcome {
        case .printed(let data):
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        case .failed:
            throw .keychainUnreadable
        case .timedOut:
            throw .keychainTimedOut
        }
    }
}
