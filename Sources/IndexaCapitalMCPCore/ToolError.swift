import Foundation

/// Every failure a tool can report. The messages carry a status code, a path and fixed
/// words only: never a header, the token or a response body. The one thing quoted from a
/// response is how many days of daily data it holds and the first and last of them, when
/// a range asks for too many.
public enum ToolError: Error, Equatable {
    case unknownTool(String)
    case invalidAccount
    case unknownArguments([String], allowed: [String])
    case badArgument(name: String, reason: String)
    case invalidDate(argument: String)
    case invalidRange
    case tooManyDays(Int, limit: Int, first: String, last: String)
    case keychainTimedOut
    case keychainUnreadable
    case internalRequest
    case network
    case httpStatus(Int, path: String)
    case unreadableBody(path: String)
    case tooLarge(path: String, limit: Int)
    case unexpectedShape(path: String)
    case responseTooLong(path: String, characters: Int)
    case resultTooLong(characters: Int, narrowBy: String?)
    case timedOut(seconds: Int)

    /// The text the model reads.
    public var message: String {
        switch self {
        case .unknownTool(let name):
            return "unknown tool: \(ToolStandard.echo(name))"
        case .invalidAccount:
            return "invalid account code: expected 6 to 10 characters from A-Z and 0-9; the codes come from indexa_capital_user"
        case .invalidDate(let argument):
            return "invalid \(argument): expected a date written YYYY-MM-DD"
        case .invalidRange:
            return "from_date is later than to_date"
        case .unknownArguments(let names, let allowed):
            let shown = names.prefix(3).map { "'\(ToolStandard.echo($0))'" }.joined(separator: ", ")
            let others = names.count > 3 ? " and \(names.count - 3) more" : ""
            let form = allowed.isEmpty ? "This tool takes no arguments." : "This tool takes: \(allowed.joined(separator: ", "))."
            return "Not an argument of this tool: \(shown)\(others). \(form)"
        case .badArgument(let name, let reason):
            return "Argument '\(name)' is not valid: \(reason)"
        case .tooManyDays(let days, let limit, let first, let last):
            return
                "the range holds \(days) days of daily data and at most \(limit) fit in one call: narrow from_date and to_date. Daily data exists from \(first) to \(last)"
        case .keychainTimedOut:
            return
                "timed out reading the token from the Keychain (service \"\(KeychainTokenSource.service)\"); is the Keychain locked?"
        case .keychainUnreadable:
            return "could not read the token from the Keychain (service \"\(KeychainTokenSource.service)\")"
        case .internalRequest:
            return "internal error building the request"
        case .network:
            return "network error reaching the Indexa Capital API"
        case .httpStatus(let status, let path):
            return "the Indexa Capital API returned HTTP \(status) on \(path)"
        case .unreadableBody(let path):
            return "could not read the response body from \(path)"
        case .tooLarge(let path, let limit):
            return "the response from \(path) exceeds the \(limit) byte limit"
        case .unexpectedShape(let path):
            return "the response from \(path) was not the JSON object expected"
        case .responseTooLong(let path, let characters):
            return
                "the response from \(path) holds \(characters) characters, more than the \(ToolStandard.longestResult) one result may hold. This tool has no argument that returns less of it, and the API takes no parameter that does"
        case .resultTooLong(let characters, let narrowBy):
            let way = narrowBy.map { "Narrow it by \($0)." } ?? "Nothing in the call can be left out."
            return
                "the result would hold \(characters) characters, more than the \(ToolStandard.longestResult) one result may hold. \(way)"
        case .timedOut(let seconds):
            return
                "the call did not finish within \(seconds) seconds and was abandoned. This server only reads, so nothing was changed. Try again"
        }
    }

    /// A failure to reach the data is prefixed with "Error: "; a call refused for its
    /// arguments is not. That is the wording the server has always used.
    var output: ToolOutput {
        switch self {
        case .unknownTool, .invalidAccount, .invalidDate, .invalidRange, .tooManyDays, .unknownArguments,
            .badArgument, .resultTooLong:
            return ToolOutput(text: message, isError: true)
        default:
            return ToolOutput(text: "Error: " + message, isError: true)
        }
    }
}
