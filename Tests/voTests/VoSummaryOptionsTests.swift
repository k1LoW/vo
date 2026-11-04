import ArgumentParser
import Foundation
import Testing
@testable import vo

@Suite("Vo CLI summary options")
struct VoSummaryOptionsTests {
    @Test func summaryFlagWithoutValue() throws {
        let vo = try Vo.parse(["--summary"])
        #expect(vo.summary == "")
    }

    @Test func summaryOptionWithValue() throws {
        let vo = try Vo.parse(["--summary", "min.md"])
        #expect(vo.summary == "min.md")
    }

    @Test func summaryOptionWithEqualSign() throws {
        let vo = try Vo.parse(["--summary=min.md"])
        #expect(vo.summary == "min.md")
    }

    @Test func summaryWithoutValueFollowedByAnotherFlag() throws {
        let vo = try Vo.parse(["--summary", "--json"])
        #expect(vo.summary == "")
        #expect(vo.json == true)
    }

    @Test func summaryNotSpecified() throws {
        let vo = try Vo.parse([])
        #expect(vo.summary == nil)
    }
}
