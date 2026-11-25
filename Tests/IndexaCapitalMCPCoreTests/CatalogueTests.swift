import Foundation
import Testing

@testable import IndexaCapitalMCPCore

/// Checks on the advertised surface itself. None of these read the Keychain or the network.
@Suite("Catalogue")
struct CatalogueTests {

    private let handler = IndexaCapitalMCPServer.handler(
        tools: IndexaCapitalTools(
            api: IndexaCapitalAPI(token: FakeTokenSource(), transport: FakeTransport(body: "{}"))))

    private func result(_ request: String) async throws -> [String: Value] {
        let line = try #require(await handler.respond(to: request))
        let message = try JSONDecoder().decode(Value.self, from: Data(line.utf8))
        return try #require(message.objectValue?["result"]?.objectValue)
    }

    private static let accountSchema: Value = [
        "type": "object",
        "properties": [
            "account": [
                "type": "string",
                "description":
                    "Indexa Capital account code (e.g. ABCD1234), obtainable via indexa_capital_user. 6 to 10 characters from A-Z and 0-9",
            ]
        ],
        "required": ["account"],
    ]

    private static let performanceSchema: Value = [
        "type": "object",
        "properties": [
            "account": [
                "type": "string",
                "description":
                    "Indexa Capital account code (e.g. ABCD1234), obtainable via indexa_capital_user. 6 to 10 characters from A-Z and 0-9",
            ],
            "from_date": [
                "type": "string",
                "description":
                    "First day of daily data to include, as YYYY-MM-DD. Without from_date and to_date, no daily data is returned. With to_date alone, the range starts at the first day there is",
            ],
            "to_date": [
                "type": "string",
                "description":
                    "Last day of daily data to include, as YYYY-MM-DD. With from_date alone, the range ends at the last day there is. A range may hold at most 31 days",
            ],
            "projection": [
                "type": "boolean",
                "description":
                    "Include the monthly projection of expected, best and worst outcomes. Left out by default",
            ],
        ],
        "required": ["account"],
    ]

    private static let annotations: Value = [
        "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true,
    ]

    /// The names, titles, descriptions and schemas are what the model reads and what the
    /// permission switches are keyed on. They are pinned whole, in order, so any change to
    /// them is a deliberate edit of this test.
    @Test("tools/list advertises the four tools exactly, sorted by name")
    func listIsPinned() async throws {
        let tools = try await result(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)["tools"]
        #expect(
            tools == [
                [
                    "name": "indexa_capital_account", "title": "Indexa Capital account details",
                    "description": .string(ToolCatalog.accountDescription),
                    "inputSchema": Self.accountSchema, "annotations": Self.annotations,
                ],
                [
                    "name": "indexa_capital_performance", "title": "Indexa Capital performance",
                    "description": .string(ToolCatalog.performanceDescription),
                    "inputSchema": Self.performanceSchema, "annotations": Self.annotations,
                ],
                [
                    "name": "indexa_capital_portfolio", "title": "Indexa Capital portfolio",
                    "description": .string(ToolCatalog.portfolioDescription),
                    "inputSchema": Self.accountSchema, "annotations": Self.annotations,
                ],
                [
                    "name": "indexa_capital_user", "title": "Indexa Capital user and accounts",
                    "description": .string(ToolCatalog.userDescription),
                    "inputSchema": ["type": "object", "properties": [:], "required": []],
                    "annotations": Self.annotations,
                ],
            ])
    }

    /// The instructions are the only place the account-code workflow is stated once for the
    /// whole server rather than repeated per parameter.
    @Test("initialize names the server and states the workflow and the read-only rule")
    func initialize() async throws {
        let answer = try await result(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#)
        #expect(answer["serverInfo"] == ["name": "indexa-capital-mcp", "version": .string(IndexaCapitalMCPServer.version)])
        let instructions = try #require(answer["instructions"]?.stringValue).lowercased()
        #expect(instructions.contains("indexa_capital_user"))
        #expect(instructions.contains("read-only"))
        #expect(instructions.contains("indexa_capital_performance"))
    }

    /// A tool listed in the catalogue with no route answers every call as unknown.
    @Test("Every advertised tool is reachable through dispatch")
    func everyToolDispatches() {
        for tool in ToolCatalog.all() {
            #expect(ToolCatalog.endpoint(named: tool.name) != nil, "\(tool.name) has no endpoint")
        }
    }

    /// Claude Desktop builds the per-tool switches from manifest.json alone, before the
    /// server has ever run, and shows its descriptions next to them.
    @Test("manifest.json lists exactly the catalogue's tools, with the same descriptions")
    func manifestMatchesCatalogue() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("extension/manifest.json"))
        let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(manifest["tools"] as? [[String: Any]])
        var listed: [String: String] = [:]
        for entry in entries {
            let name = try #require(entry["name"] as? String)
            #expect(listed[name] == nil, "\(name) is listed twice")
            listed[name] = entry["description"] as? String
        }
        let advertised = Dictionary(
            uniqueKeysWithValues: ToolCatalog.all().map { ($0.name, $0.description ?? "") })
        #expect(listed == advertised)
    }

    @Test("Every path is a fixed template with the code as its only variable")
    func paths() {
        #expect(ToolCatalog.Endpoint.user.path(account: "IGNORED1") == "/users/me")
        #expect(ToolCatalog.Endpoint.account.path(account: "ABCD1234") == "/accounts/ABCD1234")
        #expect(ToolCatalog.Endpoint.portfolio.path(account: "ABCD1234") == "/accounts/ABCD1234/portfolio")
        #expect(ToolCatalog.Endpoint.performance.path(account: "ABCD1234") == "/accounts/ABCD1234/performance")
        #expect(!ToolCatalog.Endpoint.user.needsAccount)
    }
}
