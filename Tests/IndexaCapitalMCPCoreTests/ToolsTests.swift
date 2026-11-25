import Foundation
import Testing

@testable import IndexaCapitalMCPCore

/// Every tool against an invented token and an invented API.
@Suite("Tools")
struct ToolsTests {

    private func call(
        _ name: String, _ arguments: [String: Value]? = nil, token: FakeTokenSource = FakeTokenSource(),
        transport: FakeTransport = FakeTransport(body: #"{"invented":true}"#)
    ) async -> ToolOutput {
        let tools = IndexaCapitalTools(api: IndexaCapitalAPI(token: token, transport: transport))
        return await tools.handle(ToolCall(name: name, arguments: arguments))
    }

    @Test("indexa_capital_user is a GET of /users/me carrying the token, and passes the body through")
    func user() async throws {
        let transport = FakeTransport(body: #"{"accounts":[{"account_number":"ABCD1234"}]}"#)
        let output = await call(ToolCatalog.userName, [:], transport: transport)
        #expect(output == ToolOutput(text: #"{"accounts":[{"account_number":"ABCD1234"}]}"#, isError: false))

        let sent = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(sent.request.httpMethod == "GET")
        #expect(sent.request.url?.absoluteString == "https://api.indexacapital.com/users/me")
        #expect(sent.request.value(forHTTPHeaderField: "X-AUTH-TOKEN") == FakeTokenSource.invented)
        #expect(sent.request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(sent.request.httpBody == nil)
        #expect(sent.byteLimit == 1 << 20)
    }

    @Test(
        "Each account tool fetches its own path",
        arguments: [
            (ToolCatalog.accountName, "/accounts/ABCD1234"),
            (ToolCatalog.portfolioName, "/accounts/ABCD1234/portfolio"),
            (ToolCatalog.performanceName, "/accounts/ABCD1234/performance"),
        ])
    func accountPaths(tool: String, path: String) async {
        let transport = FakeTransport(body: "{}")
        let output = await call(tool, ["account": "ABCD1234"], transport: transport)
        #expect(!output.isError)
        #expect(transport.requests.map { $0.request.url?.absoluteString } == ["https://api.indexacapital.com" + path])
    }

    @Test("A lowercase or padded code is normalised before it reaches the path")
    func normalisesCode() async {
        let transport = FakeTransport(body: "{}")
        _ = await call(ToolCatalog.accountName, ["account": "  abcd1234\n"], transport: transport)
        #expect(transport.requests.first?.request.url?.path == "/accounts/ABCD1234")
    }

    /// Models add fields outside the schema unprompted.
    @Test("Arguments outside the schema are ignored")
    func extraArguments() async {
        let transport = FakeTransport(body: "{}")
        let output = await call(ToolCatalog.accountName, ["account": "ABCD1234", "limit": 5], transport: transport)
        #expect(!output.isError)
        #expect(transport.requests.first?.request.url?.path == "/accounts/ABCD1234")
        #expect(transport.requests.first?.request.url?.query == nil)
    }

    /// Each of these is refused before the token is read or a request is made.
    @Test(
        "A bad account code is refused without touching the Keychain or the network",
        arguments: [
            ["account": "not-valid!"], ["account": "../../users/me"], ["account": "AB12"],
            ["account": "ABCDEFGHIJK"], ["account": "ABCD 1234"], ["account": "ABCD1234/x"],
            ["account": "ÀBCD1234"], ["account": 42], ["account": nil], [:],
        ] as [[String: Value]])
    func refusesBadCodes(arguments: [String: Value]) async {
        let token = FakeTokenSource()
        let transport = FakeTransport(body: "{}")
        let output = await call(ToolCatalog.accountName, arguments, token: token, transport: transport)
        #expect(output == ToolOutput(text: "invalid account code", isError: true))
        #expect(token.reads == 0)
        #expect(transport.requests.isEmpty)
    }

    @Test("No arguments at all is a missing code")
    func noArguments() async {
        #expect(await call(ToolCatalog.portfolioName, nil) == ToolOutput(text: "invalid account code", isError: true))
    }

    @Test("An unknown tool is refused without touching the Keychain or the network")
    func unknownTool() async {
        let token = FakeTokenSource()
        let transport = FakeTransport(body: "{}")
        let output = await call("nope", [:], token: token, transport: transport)
        #expect(output == ToolOutput(text: "unknown tool: nope", isError: true))
        #expect(token.reads == 0)
        #expect(transport.requests.isEmpty)
    }

    @Test(
        "A Keychain failure is reported and no request is made",
        arguments: [
            (
                ToolError.keychainUnreadable,
                #"Error: could not read the token from the Keychain (service "indexa-capital-api")"#
            ),
            (
                ToolError.keychainTimedOut,
                #"Error: timed out reading the token from the Keychain (service "indexa-capital-api"); is the Keychain locked?"#
            ),
        ])
    func keychainFailure(error: ToolError, text: String) async {
        let transport = FakeTransport(body: "{}")
        let output = await call(ToolCatalog.userName, [:], token: FakeTokenSource(failing: error), transport: transport)
        #expect(output == ToolOutput(text: text, isError: true))
        #expect(transport.requests.isEmpty)
    }

    @Test("No response at all is a network error")
    func network() async {
        let output = await call(ToolCatalog.userName, [:], transport: FakeTransport(nil))
        #expect(output == ToolOutput(text: "Error: network error reaching the Indexa Capital API", isError: true))
    }

    /// A refused redirect lands here too, which is what makes it diagnosable.
    @Test("A status other than 200 is reported with the path and never the body", arguments: [302, 401, 404, 500])
    func status(code: Int) async {
        let transport = FakeTransport(status: code, body: "invented error page")
        let output = await call(ToolCatalog.accountName, ["account": "abcd1234"], transport: transport)
        #expect(
            output == ToolOutput(
                text: "Error: the Indexa Capital API returned HTTP \(code) on /accounts/ABCD1234", isError: true))
        #expect(!output.text.contains("invented error page"))
        #expect(!output.text.contains(FakeTokenSource.invented))
    }

    @Test("The status wins over a body that could not be read")
    func statusBeforeBody() async {
        let transport = FakeTransport(HTTPResponse(status: 503, body: .failure(.init())))
        let output = await call(ToolCatalog.userName, [:], transport: transport)
        #expect(output.text == "Error: the Indexa Capital API returned HTTP 503 on /users/me")
    }

    @Test("A body that could not be read is reported")
    func unreadableBody() async {
        let transport = FakeTransport(HTTPResponse(status: 200, body: .failure(.init())))
        let output = await call(ToolCatalog.userName, [:], transport: transport)
        #expect(output == ToolOutput(text: "Error: could not read the response body from /users/me", isError: true))
    }

    @Test("A body at the limit passes and one byte more is refused")
    func sizeLimit() async {
        let limit = 1 << 20
        let atLimit = FakeTransport(HTTPResponse(status: 200, body: .success(Data(repeating: 0x20, count: limit))))
        #expect(await call(ToolCatalog.userName, [:], transport: atLimit).isError == false)

        let over = FakeTransport(HTTPResponse(status: 200, body: .success(Data(repeating: 0x20, count: limit + 1))))
        #expect(
            await call(ToolCatalog.userName, [:], transport: over)
                == ToolOutput(text: "Error: the response from /users/me exceeds the 1048576 byte limit", isError: true))
    }

    @Test("The token is read again on every call")
    func tokenPerCall() async {
        let token = FakeTokenSource()
        let tools = IndexaCapitalTools(api: IndexaCapitalAPI(token: token, transport: FakeTransport(body: "{}")))
        _ = await tools.handle(ToolCall(name: ToolCatalog.userName))
        _ = await tools.handle(ToolCall(name: ToolCatalog.userName))
        #expect(token.reads == 2)
    }
}
