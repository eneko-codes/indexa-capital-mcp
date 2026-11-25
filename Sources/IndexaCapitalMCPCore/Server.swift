import Foundation

public enum IndexaCapitalMCPServer {

    public static let name = "indexa-capital-mcp"
    public static let version = "1.2.0"

    /// Returned from `initialize`. It states the two things the per-tool metadata cannot:
    /// that the account code has to be fetched before the account-scoped tools are usable,
    /// and that the read-only guarantee is a property of this server rather than of the
    /// credential.
    public static let instructions = """
        Read-only access to Indexa Capital investment accounts.

        Every tool is a fixed GET request. Nothing exposed here can move money, make a
        contribution, or change an account in any way.

        The account-scoped tools need an account code. Call indexa_capital_user first:
        it returns the authenticated user together with the code of every account they
        hold. Pass one of those codes to the other tools. Codes are 6-10 uppercase
        alphanumeric characters; lowercase input is accepted and normalised.

        Responses are the API's own JSON, passed through unmodified. The exception is
        indexa_capital_performance. The API answers it with a row for every day since the
        account was opened, so this server returns the summary and leaves out the daily
        data and the projection unless the call asks for them. Its first text block says
        what the response holds, what was left out and which arguments return it. Nothing
        in it is computed or summarised.
        """

    /// The token and the network are parameters so the whole server can be driven by
    /// doubles. Nothing in this function reads the Keychain or opens a connection by itself.
    public static func run(
        token: any TokenSource = KeychainTokenSource(),
        transport: any HTTPTransport = URLSessionTransport()
    ) async {
        Diagnostics.started(version: version)
        await serveStandardStreams(
            handler: handler(tools: IndexaCapitalTools(api: IndexaCapitalAPI(token: token, transport: transport))))
    }

    public static func handler(tools: IndexaCapitalTools) -> MCPHandler {
        MCPHandler(
            name: name, version: version, instructions: instructions,
            catalog: ToolCatalog.all(), tools: tools)
    }
}
