import Foundation

/// Routes a `tools/call` to the API.
///
/// Never touches the Keychain or the network directly: everything goes through
/// `IndexaCapitalAPI`, whose token source and transport are doubles in the tests.
public struct IndexaCapitalTools: ToolHandler {
    private let api: IndexaCapitalAPI
    private let timeout: Duration

    public init(api: IndexaCapitalAPI, timeout: Duration = IndexaCapitalTools.defaultTimeout) {
        self.api = api
        self.timeout = timeout
    }

    /// Keychain 10 s plus the request's 20 s, with room to spare, and well inside
    /// `ToolStandard.timeLimit`, so the answer is ours and not the client's generic "no result".
    public static let defaultTimeout = Duration.seconds(45)

    public func handle(_ call: ToolCall) async -> ToolOutput {
        let started = ContinuousClock.now
        let outcome = await Deadline.run(within: timeout) {
            do throws(ToolError) {
                return try await run(call)
            } catch {
                Diagnostics.toolFailed(call.name, error: error, since: started)
                return error.output
            }
        }
        if let outcome { return outcome }
        let error = ToolError.timedOut(seconds: Int(timeout.components.seconds))
        Diagnostics.toolFailed(call.name, error: error, since: started)
        return error.output
    }

    private func run(_ call: ToolCall) async throws(ToolError) -> ToolOutput {
        guard let endpoint = ToolCatalog.endpoint(named: call.name) else {
            throw .unknownTool(call.name)
        }
        let arguments = Arguments(call.arguments)
        try arguments.refuseUnknown(allowed: endpoint.argumentNames)
        var account = ""
        if endpoint.needsAccount {
            guard let code = AccountCode.normalise(arguments.account) else { throw .invalidAccount }
            account = code
        }
        var selection: PerformanceSelection?
        if endpoint == .performance { selection = try PerformanceSelection(arguments: arguments) }

        let path = endpoint.path(account: account)
        let body = try await api.get(path)
        guard let selection else {
            // Nothing selects less of these responses, so one too long is refused with its
            // size rather than cut.
            let characters = body.utf16.count
            guard characters <= ToolStandard.longestResult else {
                throw .responseTooLong(path: path, characters: characters)
            }
            return ToolOutput(text: body, isError: false)
        }
        return try PerformanceResponse.select(body, selection, path: path)
    }
}
