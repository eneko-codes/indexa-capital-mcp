import Foundation
import Testing

@testable import IndexaCapitalMCPCore

/// The edges of the tool standard for this server's tools: the longest result, what is
/// refused instead of cut, the time limit and the texts the model reads. Every response in
/// here is invented.
@Suite("Bounds")
struct BoundsTests {

    private func call(
        _ name: String, _ arguments: [String: Value] = [:], body: String, timeout: Duration = IndexaCapitalTools.defaultTimeout,
        transport: (any HTTPTransport)? = nil
    ) async -> ToolOutput {
        let tools = IndexaCapitalTools(
            api: IndexaCapitalAPI(token: FakeTokenSource(), transport: transport ?? FakeTransport(body: body)),
            timeout: timeout)
        return await tools.handle(ToolCall(name: name, arguments: arguments))
    }

    private static let passthroughTools: [(name: String, arguments: [String: Value])] = [
        (ToolCatalog.userName, [:]),
        (ToolCatalog.accountName, ["account": "ABCD1234"]),
        (ToolCatalog.portfolioName, ["account": "ABCD1234"]),
    ]

    @Test("A passed-through response at the longest result goes out whole and one unit more is refused with its size")
    func passthroughEdge() async {
        for tool in Self.passthroughTools {
            let atLimit = String(repeating: "x", count: ToolStandard.longestResult)
            #expect(await call(tool.name, tool.arguments, body: atLimit) == ToolOutput(text: atLimit, isError: false))

            let over = String(repeating: "x", count: ToolStandard.longestResult + 1)
            let refused = await call(tool.name, tool.arguments, body: over)
            #expect(refused.isError)
            #expect(refused.text.hasPrefix("Error: the response from /"))
            #expect(refused.text.contains("holds \(ToolStandard.longestResult + 1) characters"))
            #expect(refused.text.contains("more than the \(ToolStandard.longestResult)"))
            #expect(refused.text.utf16.count <= ToolStandard.longestError)
        }
    }

    @Test("The longest result is counted in UTF-16 units, not bytes or characters")
    func passthroughCountsUnits() async {
        // Two units and four bytes each: 20,001 of them are 40,002 units.
        let body = String(repeating: "😀", count: ToolStandard.longestResult / 2 + 1)
        let refused = await call(ToolCatalog.userName, body: body)
        #expect(refused.text.contains("holds 40002 characters"))
        let fits = String(repeating: "😀", count: ToolStandard.longestResult / 2)
        #expect(await call(ToolCatalog.userName, body: fits).isError == false)
    }

    @Test("The body cap of 1 MiB stays, and it is reported before the length check")
    func bodyCapStays() async {
        #expect(IndexaCapitalAPI.maximumBodyBytes == 1 << 20)
        let over = FakeTransport(
            HTTPResponse(status: 200, body: .success(Data(repeating: 0x20, count: IndexaCapitalAPI.maximumBodyBytes + 1))))
        let refused = await call(ToolCatalog.userName, body: "", transport: over)
        #expect(refused.text.contains("exceeds the 1048576 byte limit"))
    }

    @Test("The request timeout stays at 20 seconds")
    func requestTimeoutStays() {
        #expect(URLSessionTransport.defaultTimeout == 20)
    }

    // MARK: Performance

    /// A summary whose JSON is exactly `characters` long once written out again.
    private static func summary(ofLength characters: Int) -> String {
        let frame = #"{"x":""}"#
        return #"{"x":""# + String(repeating: "a", count: characters - frame.utf16.count) + #""}"#
    }

    @Test("A performance result at the longest result is returned and one unit more is refused")
    func performanceEdge() async {
        let atLimit = await call(
            ToolCatalog.performanceName, ["account": "ABCD1234"],
            body: Self.summary(ofLength: ToolStandard.longestResult))
        #expect(!atLimit.isError)
        #expect(atLimit.content.count == 1)
        #expect(atLimit.text.utf16.count == ToolStandard.longestResult)

        let over = await call(
            ToolCatalog.performanceName, ["account": "ABCD1234"],
            body: Self.summary(ofLength: ToolStandard.longestResult + 1))
        #expect(
            over
                == ToolOutput(
                    text:
                        "the result would hold 40001 characters, more than the 40000 one result may hold. Nothing in the call can be left out.",
                    isError: true))
    }

    @Test("A result too long through the days or the projection says which argument narrows it")
    func performanceNarrowing() async {
        let wide = String(repeating: "w", count: 2_000)
        let days = (1...28).map { #"{"date":"2031-02-\#(String(format: "%02d", $0))","note":"\#(wide)"}"# }
        let body = #"{"portfolios":["# + days.joined(separator: ",") + "]}"
        let tooManyRows = await call(
            ToolCatalog.performanceName,
            ["account": "ABCD1234", "from_date": "2031-02-01", "to_date": "2031-02-28"], body: body)
        #expect(tooManyRows.isError)
        #expect(tooManyRows.text.hasSuffix("Narrow it by from_date and to_date (fewer days)."))
        #expect(tooManyRows.text.contains("more than the 40000 one result may hold"))

        let oneDay = await call(
            ToolCatalog.performanceName,
            ["account": "ABCD1234", "from_date": "2031-02-28", "to_date": "2031-02-28"], body: body)
        #expect(!oneDay.isError)

        let projection = #"{"performance":{"real":["# + String(repeating: "1,", count: 30_000) + "1]}}"
        let withProjection = await call(
            ToolCatalog.performanceName, ["account": "ABCD1234", "projection": true], body: projection)
        #expect(withProjection.text.hasSuffix("Narrow it by leaving out projection."))
        let without = await call(ToolCatalog.performanceName, ["account": "ABCD1234"], body: projection)
        #expect(!without.isError)
    }

    @Test("The most days one call returns is the constant the descriptions quote")
    func dayLimit() async {
        let january = (1...31).map { String(format: "2031-01-%02d", $0) }
        let body = #"{"portfolios":["# + (january + ["2031-02-01"]).map { #"{"date":"\#($0)"}"# }.joined(separator: ",") + "]}"
        #expect(january.count == PerformanceResponse.maximumDays)
        let over = await call(
            ToolCatalog.performanceName,
            ["account": "ABCD1234", "from_date": "2031-01-01", "to_date": "2031-02-01"], body: body)
        #expect(over.text.hasPrefix("the range holds \(PerformanceResponse.maximumDays + 1) days"))
        let at = await call(
            ToolCatalog.performanceName,
            ["account": "ABCD1234", "from_date": "2031-01-02", "to_date": "2031-02-01"], body: body)
        #expect(!at.isError)
    }

    // MARK: Time

    private struct NeverAnswers: HTTPTransport {
        func get(_ request: URLRequest, byteLimit: Int) async throws -> HTTPResponse {
            try await Task.sleep(for: .seconds(120))
            throw CancellationError()
        }
    }

    @Test("A call that does not finish is answered inside the limit, saying nothing was changed")
    func deadline() async {
        #expect(IndexaCapitalTools.defaultTimeout < ToolStandard.timeLimit)
        let started = ContinuousClock.now
        let output = await call(
            ToolCatalog.userName, body: "", timeout: .seconds(1), transport: NeverAnswers())
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(
            output
                == ToolOutput(
                    text:
                        "Error: the call did not finish within 1 seconds and was abandoned. This server only reads, so nothing was changed. Try again",
                    isError: true))
    }

    // MARK: What the model reads

    @Test("The instructions and every tool description are within the longest a client keeps")
    func textsWithinTheLimit() {
        #expect(
            ToolStandard.overlongTexts(
                instructions: IndexaCapitalMCPServer.instructions, catalog: ToolCatalog.all()
            ).isEmpty)
        #expect(!IndexaCapitalMCPServer.instructions.isEmpty)
    }

    @Test("The instructions state the bounds the code enforces")
    func instructionsStateTheBounds() {
        let instructions = IndexaCapitalMCPServer.instructions
        #expect(instructions.contains("longer than \(ToolStandard.longestResult)"))
        #expect(instructions.contains("at most\n\(PerformanceResponse.maximumDays) days per call"))
        #expect(instructions.contains("from_date and to_date"))
        #expect(!instructions.contains("from and to"))
    }

    @Test("Every schema lists the arguments the dispatcher accepts, and nothing else")
    func schemasMatchDispatch() throws {
        for tool in ToolCatalog.all() {
            let endpoint = try #require(ToolCatalog.endpoint(named: tool.name))
            let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
            #expect(Set(properties.keys) == Set(endpoint.argumentNames), "\(tool.name)")
        }
    }

    @Test("The figures in the README and the manifest are the constants")
    func figuresMatch() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        #expect(readme.contains("\(ToolStandard.longestResult) characters"))
        #expect(readme.contains("at most \(PerformanceResponse.maximumDays) days"))
        let manifest = try String(
            contentsOf: root.appendingPathComponent("extension/manifest.json"), encoding: .utf8)
        #expect(manifest.contains("longer than \(ToolStandard.longestResult) characters"))
    }
}
