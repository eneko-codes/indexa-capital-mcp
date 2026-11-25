import Foundation

/// Typed access to the argument bag of one `tools/call`.
///
/// No argument of this server is a quantity (nothing pages, nothing has a size), so there
/// is nothing to move into a range: every value is either what the schema allows or is
/// refused with the form expected.
struct Arguments {
    private let values: [String: Value]

    init(_ values: [String: Value]?) {
        self.values = values ?? [:]
    }

    /// Refuses an argument the schema does not list, and names the ones that are allowed.
    /// A caller still using a name this server renamed (`from`, `to`) fails here, instead
    /// of running without the argument it believed it had passed.
    func refuseUnknown(allowed: [String]) throws(ToolError) {
        let unknown = values.keys.filter { !allowed.contains($0) }.sorted()
        if !unknown.isEmpty { throw .unknownArguments(unknown, allowed: allowed) }
    }

    /// `nil` when the argument is absent or null, which mean the same: not given. Models
    /// send `null` for an argument they leave out.
    private func given(_ name: String) -> Value? {
        guard let raw = values[name], !raw.isNull else { return nil }
        return raw
    }

    /// The account code as written, for `AccountCode.normalise`. Anything that is not text
    /// reads as no code, so a stray number is never taken for one.
    var account: String {
        given("account")?.stringValue ?? ""
    }

    /// A real calendar day written `YYYY-MM-DD`, or `nil` when not given.
    func day(_ name: String) throws(ToolError) -> Day? {
        guard let raw = given(name) else { return nil }
        guard let day = raw.stringValue.flatMap(Day.init(argument:)) else {
            throw .invalidDate(argument: name)
        }
        return day
    }

    func bool(_ name: String, default fallback: Bool) throws(ToolError) -> Bool {
        guard let raw = given(name) else { return fallback }
        guard let flag = raw.boolValue else {
            throw .badArgument(name: name, reason: "true or false was expected")
        }
        return flag
    }
}
