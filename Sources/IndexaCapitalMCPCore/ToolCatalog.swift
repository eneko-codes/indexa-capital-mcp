import Foundation

/// The catalogue is the authorisation surface: a tool that is not listed here cannot be
/// called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop.
///
/// Each entry is a closed path template on `IndexaCapitalAPI.baseURL`, always fetched with
/// GET. The only thing a caller supplies that reaches the API is an account code, and it is
/// validated before it is put into the path. Nothing else is reachable. The other arguments
/// of `indexa_capital_performance` choose which parts of the answer are returned and are
/// never sent anywhere.
public enum ToolCatalog {

    public static let userName = "indexa_capital_user"
    public static let accountName = "indexa_capital_account"
    public static let portfolioName = "indexa_capital_portfolio"
    public static let performanceName = "indexa_capital_performance"

    /// What a tool fetches. `path(account:)` is the only way a path is built.
    enum Endpoint {
        case user
        case account
        case portfolio
        case performance

        var needsAccount: Bool { self != .user }

        /// The arguments the schema lists; any other is refused.
        var argumentNames: [String] {
            switch self {
            case .user: []
            case .account, .portfolio: ["account"]
            case .performance:
                ["account", PerformanceResponse.fromArgument, PerformanceResponse.toArgument,
                 PerformanceResponse.projectionArgument]
            }
        }

        /// `account` must already have passed `AccountCode.normalise`.
        func path(account: String) -> String {
            switch self {
            case .user: "/users/me"
            case .account: "/accounts/\(account)"
            case .portfolio: "/accounts/\(account)/portfolio"
            case .performance: "/accounts/\(account)/performance"
            }
        }
    }

    static func endpoint(named name: String) -> Endpoint? {
        switch name {
        case userName: .user
        case accountName: .account
        case portfolioName: .portfolio
        case performanceName: .performance
        default: nil
        }
    }

    /// Sorted by name, so `tools/list` is stable and can be diffed between builds.
    public static func all() -> [Tool] {
        [account, performance, portfolio, user]
    }

    // MARK: Schemas

    /// An empty `required` is sent rather than left out: it is what the server has always
    /// advertised, and a client that diffs the catalogue sees no change.
    private static let noArguments: Value = [
        "type": "object", "properties": [:], "required": [],
    ]

    private static let accountArgument: Value = [
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

    private static let performanceArguments: Value = [
        "type": "object",
        "properties": [
            "account": [
                "type": "string",
                "description":
                    "Indexa Capital account code (e.g. ABCD1234), obtainable via indexa_capital_user. 6 to 10 characters from A-Z and 0-9",
            ],
            PerformanceResponse.fromArgument: [
                "type": "string",
                "description":
                    "First day of daily data to include, as YYYY-MM-DD. Without from_date and to_date, no daily data is returned. With to_date alone, the range starts at the first day there is",
            ],
            PerformanceResponse.toArgument: [
                "type": "string",
                "description":
                    "Last day of daily data to include, as YYYY-MM-DD. With from_date alone, the range ends at the last day there is. A range may hold at most \(PerformanceResponse.maximumDays) days",
            ],
            PerformanceResponse.projectionArgument: [
                "type": "boolean",
                "description":
                    "Include the monthly projection of expected, best and worst outcomes. Left out by default",
            ],
        ],
        "required": ["account"],
    ]

    /// One shared value rather than one per tool: every tool is a fixed GET, so these
    /// describe the server, not any one entry. Clients treat a tool with no annotations as
    /// write-capable, destructive and non-idempotent, the opposite of what this server is.
    /// `openWorldHint` is true because the data comes from an external API.
    private static let readOnly = Tool.Annotations(
        readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true)

    // MARK: Tools

    static let user = Tool(
        name: userName,
        title: "Indexa Capital user and accounts",
        description: userDescription,
        inputSchema: noArguments, annotations: readOnly)

    static let account = Tool(
        name: accountName,
        title: "Indexa Capital account details",
        description: accountDescription,
        inputSchema: accountArgument, annotations: readOnly)

    static let portfolio = Tool(
        name: portfolioName,
        title: "Indexa Capital portfolio",
        description: portfolioDescription,
        inputSchema: accountArgument, annotations: readOnly)

    static let performance = Tool(
        name: performanceName,
        title: "Indexa Capital performance",
        description: performanceDescription,
        inputSchema: performanceArguments, annotations: readOnly)

    /// The API's own JSON, unmodified. It takes no parameter that selects less, so a
    /// response longer than a result may be is refused with its size, never cut.
    private static let passthroughSuffix =
        "Returns the API's JSON unmodified; a response longer than \(ToolStandard.longestResult) characters is refused with its size"

    static let userDescription =
        "Authenticated user's data and the list of their accounts (codes). \(passthroughSuffix)"
    static let accountDescription =
        "Basic information for an account (status, risk profile). \(passthroughSuffix)"
    static let portfolioDescription =
        "Current portfolio: positions and valuation. \(passthroughSuffix)"

    static let performanceDescription =
        "Account performance: returns, volatility and monthly history, with no daily data and no projection by default; the first text block says what was left out. Daily data (valuation, cash flows and return index per day) only for the days from_date and to_date select, at most \(PerformanceResponse.maximumDays) per call; the projection only when projection is true. A result longer than \(ToolStandard.longestResult) characters is refused with its size"
}

/// An Indexa Capital account code: 6 to 10 characters from A–Z and 0–9.
enum AccountCode {

    /// The code to put in a path, or `nil` when `raw` is not one. Surrounding whitespace is
    /// dropped and lowercase is accepted. Only ASCII letters are uppercased, so nothing that
    /// was not already an ASCII letter or digit can become one.
    static func normalise(_ raw: String) -> String? {
        let code = String(
            raw.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.map { scalar in
                ("a"..."z").contains(scalar) ? Character(Unicode.Scalar(scalar.value - 32)!) : Character(scalar)
            })
        let scalars = code.unicodeScalars
        guard (6...10).contains(scalars.count),
            scalars.allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) })
        else { return nil }
        return code
    }
}
