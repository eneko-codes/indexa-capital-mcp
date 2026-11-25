import Foundation

/// A calendar day, held as the eight digits (`20310130`) the API keys its daily series by.
/// That form sorts the way dates do, so a range check is a string comparison.
struct Day: Comparable, Hashable, Sendable {
    let compact: String

    /// From a tool argument, which must be a real date written `2031-01-30`.
    init?(argument: String) {
        guard let day = Day(dashed: argument) else { return nil }
        let digits = day.compact
        let components = DateComponents(
            calendar: Calendar(identifier: .gregorian), year: Int(digits.prefix(4)),
            month: Int(digits.dropFirst(4).prefix(2)), day: Int(digits.suffix(2)))
        guard components.isValidDate else { return nil }
        self = day
    }

    /// From the API, in the form `portfolios[].date` uses. Only the shape is checked.
    init?(dashed: String) {
        let parts = dashed.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else {
            return nil
        }
        self.init(compact: parts.joined())
    }

    /// From the API, in the form the daily series are keyed by. Only the shape is checked.
    init?(compact: String) {
        guard compact.utf8.count == 8, compact.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else {
            return nil
        }
        self.compact = compact
    }

    var dashed: String {
        "\(compact.prefix(4))-\(compact.dropFirst(4).prefix(2))-\(compact.suffix(2))"
    }

    static func < (left: Day, right: Day) -> Bool { left.compact < right.compact }
}

/// The optional parts of a performance response that a call asked for.
struct PerformanceSelection: Equatable, Sendable {
    var from: Day?
    var to: Day?
    var projection = false

    /// With one bound only, the range runs to the other end of the data.
    func includes(_ day: Day) -> Bool {
        guard from != nil || to != nil else { return false }
        if let from, day < from { return false }
        if let to, day > to { return false }
        return true
    }
}

extension PerformanceSelection {

    /// Read before any request is made, so a bad date costs neither a Keychain read nor a
    /// call.
    init(arguments: Arguments) throws(ToolError) {
        from = try arguments.day(PerformanceResponse.fromArgument)
        to = try arguments.day(PerformanceResponse.toArgument)
        projection = try arguments.bool(PerformanceResponse.projectionArgument, default: false)
        if let from, let to, from > to { throw .invalidRange }
    }
}

/// Cuts an account's performance response down to what one call asked for.
///
/// The endpoint takes no parameters and answers with a row for every day since the account
/// was opened, so its size grows without limit, next to a monthly projection that few
/// questions need. A call gets the summary, daily data only for the days it names, and the
/// projection only on request.
///
/// What is returned is the API's own data: members and rows are left out whole, and nothing
/// is computed or summarised. The JSON is written out again, though, so keys come back
/// sorted and numbers in their shortest form (`10000.0` as `10000`).
enum PerformanceResponse {

    /// The most days of daily data one call returns. A day takes about 300 characters in an
    /// unfunded account and more in a funded one, so a month stays well under the 50,000
    /// characters at which Claude Code moves a result out of the conversation into a file.
    static let maximumDays = 31

    static let fromArgument = "from_date"
    static let toArgument = "to_date"
    static let projectionArgument = "projection"

    static let projectionKey = "performance"
    static let dailyRowsKey = "portfolios"

    /// Two text blocks: what was left out and how to ask for it, then the JSON.
    static func select(
        _ body: String, _ selection: PerformanceSelection, path: String
    ) throws(ToolError) -> ToolOutput {
        guard case .object(var fields)? = try? JSONDecoder().decode(Value.self, from: Data(body.utf8))
        else { throw .unexpectedShape(path: path) }

        let hasProjection = fields[projectionKey] != nil
        let projectionMembers = fields[projectionKey]?.objectValue?.count ?? 1
        if !selection.projection { fields[projectionKey] = nil }

        var available: Set<Day> = []
        if let rows = fields[dailyRowsKey]?.arrayValue {
            // A row with no readable date cannot be placed in a range, so it is never kept.
            fields[dailyRowsKey] = .array(
                rows.filter { row in
                    guard let day = row.objectValue?["date"]?.stringValue.flatMap(Day.init(dashed:))
                    else { return false }
                    available.insert(day)
                    return selection.includes(day)
                })
        }
        let kept = keepingSelectedDays(.object(fields), selection, available: &available)

        let returned = available.filter(selection.includes)
        if returned.count > maximumDays, let first = available.min(), let last = available.max() {
            throw .tooManyDays(
                returned.count, limit: maximumDays, first: first.dashed, last: last.dashed)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(kept) else { throw .unexpectedShape(path: path) }
        let json = String(decoding: data, as: UTF8.self)
        let notices = leftOutNotices(
            available: available, returned: returned, selection: selection,
            projectionMembers: hasProjection && !selection.projection ? projectionMembers : nil)
        let note = notices.joined(separator: "\n")

        // The result is bounded here, not by the guard: what is too long is refused with
        // its size, never cut, and the way to ask for less is named.
        let characters = note.utf16.count + json.utf16.count
        if characters > ToolStandard.longestResult {
            var narrowing: [String] = []
            if returned.count > 1 { narrowing.append("\(fromArgument) and \(toArgument) (fewer days)") }
            if selection.projection { narrowing.append("leaving out \(projectionArgument)") }
            throw .resultTooLong(
                characters: characters, narrowBy: narrowing.isEmpty ? nil : narrowing.joined(separator: " or "))
        }
        return ToolOutput(
            content: note.isEmpty ? [.text(json)] : [.text(note), .text(json)], isError: false)
    }

    /// An object keyed by day is recognised by its keys rather than by its name, so a
    /// series the API adds later is bounded too. Arrays are not searched.
    private static func keepingSelectedDays(
        _ value: Value, _ selection: PerformanceSelection, available: inout Set<Day>
    ) -> Value {
        guard case .object(let fields) = value else { return value }
        let days = fields.keys.compactMap(Day.init(compact:))
        if !fields.isEmpty, days.count == fields.count {
            available.formUnion(days)
            return .object(fields.filter { key, _ in Day(compact: key).map(selection.includes) ?? false })
        }
        return .object(fields.mapValues { keepingSelectedDays($0, selection, available: &available) })
    }

    /// What this result leaves out, in the fixed wording of `Notice` where one fits, one
    /// sentence a line. The sentence about which days exist and which are included is the
    /// server's own: no `Notice` form places a range of days in a whole. A result that holds
    /// everything and was asked for nothing carries no notice.
    private static func leftOutNotices(
        available: Set<Day>, returned: Set<Day>, selection: PerformanceSelection, projectionMembers: Int?
    ) -> [String] {
        var notices: [String] = []
        if let first = available.min(), let last = available.max() {
            let asked = selection.from != nil || selection.to != nil
            if !asked || returned.count < available.count {
                let held: String
                if let firstReturned = returned.min(), let lastReturned = returned.max() {
                    held = "Included: \(count(returned.count)), \(firstReturned.dashed) to \(lastReturned.dashed)."
                } else {
                    held = asked ? "None of it falls in the range asked for." : "None of it is included."
                }
                notices.append(
                    "Daily data exists for \(count(available.count)), \(first.dashed) to \(last.dashed). \(held)")
                notices.append(
                    Notice.notShown(
                        count: available.count - returned.count, things: "days of daily data",
                        pass:
                            "\(fromArgument)=YYYY-MM-DD and \(toArgument)=YYYY-MM-DD (at most \(maximumDays) days per call)"
                    ))
            }
        } else if selection.from != nil || selection.to != nil {
            notices.append("The response holds no daily data.")
        }
        if let projectionMembers {
            notices.append(
                Notice.notShown(
                    count: projectionMembers, things: "members of the projection (\"\(projectionKey)\")",
                    pass: "\(projectionArgument)=true"))
        }
        return notices
    }

    private static func count(_ days: Int) -> String {
        days == 1 ? "1 day" : "\(days) days"
    }
}
