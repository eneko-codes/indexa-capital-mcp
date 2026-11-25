import Foundation
import Testing

@testable import IndexaCapitalMCPCore

@Suite("Diagnostics")
struct DiagnosticsTests {

    @Test("An error is reported by case, never by its account code or path")
    func enumPayloadStaysOut() {
        let kind = Diagnostics.kind(of: ToolError.httpStatus(404, path: "/accounts/ABCD1234"))
        #expect(kind == "ToolError.httpStatus")
        #expect(Diagnostics.kind(of: ToolError.unknownTool("secret")) == "ToolError.unknownTool")
        #expect(Diagnostics.kind(of: ToolError.invalidAccount) == "ToolError.invalidAccount")
    }

    @Test("A non-enum error is reduced to domain and code, dropping its description")
    func foundationErrorHasNoDescription() {
        let error = NSError(
            domain: "TestDomain", code: 7, userInfo: [NSLocalizedDescriptionKey: "token NOT-A-REAL-TOKEN"])
        #expect(Diagnostics.kind(of: error) == "TestDomain#7")
    }

    @Test("A tool name that is not a plain identifier cannot reach the log")
    func toolNameIsSanitised() {
        #expect(Diagnostics.toolName("indexa_capital_account") == "indexa_capital_account")
        #expect(Diagnostics.toolName("evil\nfatal forged line") == "invalid")
        #expect(Diagnostics.toolName("") == "invalid")
        #expect(Diagnostics.toolName(String(repeating: "a", count: 65)) == "invalid")
    }

    @Test("Every line names the process that wrote it, so two instances can be told apart")
    func lineCarriesProcessID() {
        let first = Diagnostics.line("info", "started", processID: 4242)
        let second = Diagnostics.line("info", "started", processID: 4243)
        #expect(first.contains("[4242] started"))
        #expect(first.hasSuffix("\n"))
        #expect(first != second)
    }
}
