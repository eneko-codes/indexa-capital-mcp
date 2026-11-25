import Foundation
import Testing

@testable import IndexaCapitalMCPCore

/// `indexa_capital_performance` against an invented response shaped like the API's: a
/// summary, a projection, and three days of daily data in each form the API uses.
@Suite("Performance")
struct PerformanceTests {

    private static let body = """
        {"plan_expected_return":0.038399999999999997,"volatility":0.05,
         "history":{"2031-01-31":0.01,"2031-02-28":-0.02},
         "performance":{"period":["2031-01-31T02:00:00+02:00"],"expected":[100],"real":[100]},
         "return":{"pl":12.5,
                   "index":{"20310130":100,"20310131":100.5,"20310201":101},
                   "total_amounts":{"20310130":1000.0,"20310131":1005,"20310201":1010}},
         "net_amounts":{"20310130":1000,"20310131":1000,"20310201":1000},
         "portfolios":[{"date":"2031-02-01","total_amount":1010},
                       {"date":"2031-01-31","total_amount":1005},
                       {"date":"2031-01-30","total_amount":1000.0}]}
        """

    private static let projectionNote =
        #"3 members of the projection ("performance") are not shown. Pass projection=true to include them."#

    private static func notShown(_ count: Int) -> String {
        "\(count) days of daily data are not shown. Pass from_date=YYYY-MM-DD and to_date=YYYY-MM-DD (at most 31 days per call) to include them."
    }

    private func call(
        _ arguments: [String: Value], body: String = PerformanceTests.body, token: FakeTokenSource = FakeTokenSource(),
        transport: FakeTransport? = nil
    ) async -> ToolOutput {
        var arguments = arguments
        arguments["account"] = "ABCD1234"
        let tools = IndexaCapitalTools(
            api: IndexaCapitalAPI(token: token, transport: transport ?? FakeTransport(body: body)))
        return await tools.handle(ToolCall(name: ToolCatalog.performanceName, arguments: arguments))
    }

    private func blocks(_ output: ToolOutput) throws -> (note: String, json: String) {
        try #require(output.content.count == 2)
        guard case .text(let note) = output.content[0], case .text(let json) = output.content[1] else {
            Issue.record("expected two text blocks")
            return ("", "")
        }
        return (note, json)
    }

    @Test("With no range and no projection, the summary comes back and the rest is named")
    func summary() async throws {
        let output = await call([:])
        #expect(!output.isError)
        let (note, json) = try blocks(output)
        #expect(
            note
                == "Daily data exists for 3 days, 2031-01-30 to 2031-02-01. None of it is included.\n\(Self.notShown(3))\n\(Self.projectionNote)"
        )
        #expect(
            json
                == #"{"history":{"2031-01-31":0.01,"2031-02-28":-0.02},"net_amounts":{},"plan_expected_return":0.0384,"portfolios":[],"return":{"index":{},"pl":12.5,"total_amounts":{}},"volatility":0.05}"#
        )
    }

    @Test("A range returns the rows and keys of those days only, in every daily series")
    func range() async throws {
        let (note, json) = try blocks(await call(["from_date": "2031-01-31", "to_date": "2031-02-01"]))
        #expect(
            note
                == "Daily data exists for 3 days, 2031-01-30 to 2031-02-01. Included: 2 days, 2031-01-31 to 2031-02-01.\n\(Self.notShown(1))\n\(Self.projectionNote)"
        )
        #expect(
            json
                == #"{"history":{"2031-01-31":0.01,"2031-02-28":-0.02},"net_amounts":{"20310131":1000,"20310201":1000},"plan_expected_return":0.0384,"portfolios":[{"date":"2031-02-01","total_amount":1010},{"date":"2031-01-31","total_amount":1005}],"return":{"index":{"20310131":100.5,"20310201":101},"pl":12.5,"total_amounts":{"20310131":1005,"20310201":1010}},"volatility":0.05}"#
        )
    }

    @Test("One bound alone runs to the other end of the data")
    func oneBound() async throws {
        let fromOnly = try blocks(await call(["from_date": "2031-02-01"]))
        #expect(fromOnly.note.contains("Included: 1 day, 2031-02-01 to 2031-02-01."))
        #expect(fromOnly.json.contains(#""net_amounts":{"20310201":1000}"#))

        let toOnly = try blocks(await call(["to_date": "2031-01-30", "from_date": nil]))
        #expect(toOnly.note.contains("Included: 1 day, 2031-01-30 to 2031-01-30."))
        #expect(toOnly.json.contains(#""portfolios":[{"date":"2031-01-30","total_amount":1000}]"#))
    }

    @Test("A range with no data in it says so")
    func emptyRange() async throws {
        let (note, json) = try blocks(await call(["from_date": "2030-01-01", "to_date": "2030-01-31"]))
        #expect(note.contains("None of it falls in the range asked for."))
        #expect(json.contains(#""portfolios":[]"#))
    }

    @Test("projection=true returns the projection and the note stops mentioning it")
    func projection() async throws {
        let (note, json) = try blocks(await call(["projection": true]))
        #expect(!note.contains("projection"))
        #expect(!note.contains("members"))
        #expect(json.contains(#""performance":{"expected":[100],"period":["2031-01-31T02:00:00+02:00"],"real":[100]}"#))

        // Anything but a boolean is refused, not read as a request for it or as none.
        let quoted = await call(["projection": "true"])
        #expect(
            quoted
                == ToolOutput(text: "Argument 'projection' is not valid: true or false was expected", isError: true))
    }

    @Test("A response with no daily data and no projection is returned whole")
    func nothingToLeaveOut() async throws {
        let output = await call([:], body: #"{"volatility":0.05,"benchmark":[]}"#)
        #expect(output == ToolOutput(text: #"{"benchmark":[],"volatility":0.05}"#, isError: false))
    }

    @Test("A range over a response with no daily data says so")
    func noDailyData() async throws {
        let (note, _) = try blocks(
            await call(["from_date": "2031-01-01"], body: #"{"volatility":0.05}"#))
        #expect(note == "The response holds no daily data.")
    }

    @Test("A range that holds every day there is leaves nothing to announce")
    func wholeRange() async throws {
        let output = await call(
            ["from_date": "2031-01-30", "to_date": "2031-02-01", "projection": true])
        #expect(output.content.count == 1)
    }

    /// 40 consecutive days, 2031-01-01 to 2031-02-09.
    private static let fortyDays: String = {
        let days = (1...31).map { String(format: "2031-01-%02d", $0) } + (1...9).map { String(format: "2031-02-%02d", $0) }
        return #"{"portfolios":["# + days.map { #"{"date":"\#($0)"}"# }.joined(separator: ",") + "]}"
    }()

    @Test("The most days one call returns is 31, and a longer range is refused with the way out")
    func tooManyDays() async throws {
        let atLimit = await call(["from_date": "2031-01-01", "to_date": "2031-01-31"], body: Self.fortyDays)
        #expect(try blocks(atLimit).note.contains("Included: 31 days, 2031-01-01 to 2031-01-31."))

        let over = await call(["from_date": "2031-01-01"], body: Self.fortyDays)
        #expect(
            over
                == ToolOutput(
                    text:
                        "the range holds 40 days of daily data and at most 31 fit in one call: narrow from_date and to_date. Daily data exists from 2031-01-01 to 2031-02-09",
                    isError: true))
    }

    /// Each of these is refused before the token is read or a request is made.
    @Test(
        "A bad date is refused without touching the Keychain or the network",
        arguments: [
            (["from_date": "2031-13-01"], "invalid from_date: expected a date written YYYY-MM-DD"),
            (["from_date": "2031-02-30"], "invalid from_date: expected a date written YYYY-MM-DD"),
            (["from_date": "20310201"], "invalid from_date: expected a date written YYYY-MM-DD"),
            (["from_date": "2031-2-1"], "invalid from_date: expected a date written YYYY-MM-DD"),
            (["from_date": ""], "invalid from_date: expected a date written YYYY-MM-DD"),
            (["from_date": 20_310_201], "invalid from_date: expected a date written YYYY-MM-DD"),
            (["to_date": "yesterday"], "invalid to_date: expected a date written YYYY-MM-DD"),
            (["to_date": "２０３１-０２-０１"], "invalid to_date: expected a date written YYYY-MM-DD"),
            (["from": "2031-02-01"], "Not an argument of this tool: 'from'. This tool takes: account, from_date, to_date, projection."),
            (["to": "2031-02-01"], "Not an argument of this tool: 'to'. This tool takes: account, from_date, to_date, projection."),
            (["from_date": "2031-02-02", "to_date": "2031-02-01"], "from_date is later than to_date"),
        ] as [([String: Value], String)])
    func refusesBadDates(arguments: [String: Value], text: String) async {
        let token = FakeTokenSource()
        let transport = FakeTransport(body: Self.body)
        let output = await call(arguments, token: token, transport: transport)
        #expect(output == ToolOutput(text: text, isError: true))
        #expect(token.reads == 0)
        #expect(transport.requests.isEmpty)
    }

    @Test("The dates choose what is returned and never reach the API")
    func datesAreNotSent() async {
        let transport = FakeTransport(body: Self.body)
        _ = await call(["from_date": "2031-01-31", "to_date": "2031-02-01", "projection": true], transport: transport)
        #expect(
            transport.requests.map { $0.request.url?.absoluteString }
                == ["https://api.indexacapital.com/accounts/ABCD1234/performance"])
    }

    @Test("A body that is not a JSON object is an error, not a guess", arguments: ["[]", "not json", ""])
    func unexpectedShape(body: String) async {
        let output = await call([:], body: body)
        #expect(
            output
                == ToolOutput(
                    text: "Error: the response from /accounts/ABCD1234/performance was not the JSON object expected",
                    isError: true))
    }

    @Test("Text and non-ASCII values come back as they were")
    func textSurvives() async throws {
        let output = await call([:], body: #"{"name":"Añadido a/b \"x\"","n":null,"ok":true}"#)
        #expect(output.text == #"{"n":null,"name":"Añadido a/b \"x\"","ok":true}"#)
    }

    @Test("The other tools still pass the body through untouched")
    func othersUntouched() async {
        let tools = IndexaCapitalTools(
            api: IndexaCapitalAPI(token: FakeTokenSource(), transport: FakeTransport(body: Self.body)))
        let output = await tools.handle(ToolCall(name: ToolCatalog.portfolioName, arguments: ["account": "ABCD1234"]))
        #expect(output == ToolOutput(text: Self.body, isError: false))
    }

    @Test("The limit in the descriptions is the limit enforced")
    func descriptionsQuoteTheLimit() {
        #expect(PerformanceResponse.maximumDays == 31)
        #expect(ToolCatalog.performanceDescription.contains("at most 31 per call"))
        #expect(ToolCatalog.performanceDescription.contains("longer than 40000 characters"))
    }
}
