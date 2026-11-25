import Foundation

/// Routes a `tools/call` to the API.
///
/// Never touches the Keychain or the network directly: everything goes through
/// `IndexaCapitalAPI`, whose token source and transport are doubles in the tests.
public struct IndexaCapitalTools: ToolHandler {
    private let api: IndexaCapitalAPI

    public init(api: IndexaCapitalAPI) {
        self.api = api
    }

    public func handle(_ call: ToolCall) async -> ToolOutput {
        let started = ContinuousClock.now
        do throws(ToolError) {
            return ToolOutput(text: try await run(call), isError: false)
        } catch {
            Diagnostics.toolFailed(call.name, error: error, since: started)
            return error.output
        }
    }

    private func run(_ call: ToolCall) async throws(ToolError) -> String {
        guard let endpoint = ToolCatalog.endpoint(named: call.name) else {
            throw .unknownTool(call.name)
        }
        var account = ""
        if endpoint.needsAccount {
            // A value that is not a string fails the check rather than the whole call:
            // models routinely add fields outside the schema, and a stray number must not
            // be read as a code. Other arguments are ignored.
            guard let code = AccountCode.normalise(call.arguments?["account"]?.stringValue ?? "") else {
                throw .invalidAccount
            }
            account = code
        }
        return try await api.get(endpoint.path(account: account))
    }
}
