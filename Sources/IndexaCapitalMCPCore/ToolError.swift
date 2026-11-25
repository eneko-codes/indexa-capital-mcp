import Foundation

/// Every failure a tool can report. The messages carry a status code, a path and fixed
/// words only: never a header, the token or a response body. The one thing quoted from a
/// response is how many days of daily data it holds and the first and last of them, when
/// a range asks for too many.
public enum ToolError: Error, Equatable {
    case unknownTool(String)
    case invalidAccount
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

    /// The text the model reads.
    public var message: String {
        switch self {
        case .unknownTool(let name):
            return "unknown tool: \(name)"
        case .invalidAccount:
            return "invalid account code"
        case .invalidDate(let argument):
            return "invalid \(argument): expected a date written YYYY-MM-DD"
        case .invalidRange:
            return "from is later than to"
        case .tooManyDays(let days, let limit, let first, let last):
            return
                "the range holds \(days) days of daily data and at most \(limit) fit in one call: narrow from and to. Daily data exists from \(first) to \(last)"
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
        }
    }

    /// A failure to reach the data is prefixed with "Error: "; a call refused for its
    /// arguments is not. That is the wording the server has always used.
    var output: ToolOutput {
        switch self {
        case .unknownTool, .invalidAccount, .invalidDate, .invalidRange, .tooManyDays:
            return ToolOutput(text: message, isError: true)
        default:
            return ToolOutput(text: "Error: " + message, isError: true)
        }
    }
}
