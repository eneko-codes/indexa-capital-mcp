import Foundation

/// The catalogue is the authorisation surface: a tool that is not listed here cannot be
/// called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop.
///
/// Each entry is a closed path template on `IndexaCapitalAPI.baseURL`, always fetched with
/// GET. The only thing a caller supplies is an account code, and it is validated before it
/// is put into the path. Nothing else is reachable.
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
                    "Indexa Capital account code (e.g. ABCD1234), obtainable via indexa_capital_user",
            ]
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
        description: "Authenticated user's data and the list of their accounts (codes)",
        inputSchema: noArguments, annotations: readOnly)

    static let account = Tool(
        name: accountName,
        title: "Indexa Capital account details",
        description: "Basic information for an account (status, risk profile)",
        inputSchema: accountArgument, annotations: readOnly)

    static let portfolio = Tool(
        name: portfolioName,
        title: "Indexa Capital portfolio",
        description: "Current portfolio: positions and valuation",
        inputSchema: accountArgument, annotations: readOnly)

    static let performance = Tool(
        name: performanceName,
        title: "Indexa Capital performance",
        description: "Account performance and evolution",
        inputSchema: accountArgument, annotations: readOnly)
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
