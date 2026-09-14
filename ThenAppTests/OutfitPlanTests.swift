import Foundation
import Testing
@testable import ThenApp

@Suite("计划日期与输入")
struct OutfitPlanTests {
  @Test("拒绝自动纠正的日期", arguments: ["2025-02-29", "2026-04-31", "2026-13-01", "2026-00-01", "2026-1-01", "0000-01-01", "2026-01-00", "abcd-ef-gh"])
  func invalidDate(_ text: String) {
    #expect(throws: OutfitPlanError.invalidDate) { try OutfitLocalDate(text) }
  }

  @Test("闰日、日界线与夏令时遵循原始时区")
  func localDays() throws {
    #expect(try OutfitLocalDate("2024-02-29") < OutfitLocalDate("2024-03-01"))
    let instant = Date(timeIntervalSince1970: 1_789_228_800) // 2026-09-12T16:00:00Z
    #expect(try OutfitLocalDate(instant: instant, timeZone: "Asia/Shanghai").value == "2026-09-13")
    #expect(try OutfitLocalDate(instant: instant, timeZone: "America/Los_Angeles").value == "2026-09-12")
    let transition = Date(timeIntervalSince1970: 1_772_962_200) // 2026-03-08T09:30:00Z, immediately before the DST jump
    let first = try OutfitLocalDate(instant: transition, timeZone: "America/Los_Angeles")
    #expect(try OutfitLocalDate(instant: transition.addingTimeInterval(3600), timeZone: "America/Los_Angeles") == first)
    #expect(throws: OutfitPlanError.invalidTimeZone) { try OutfitLocalDate.zone("Mars/Olympus") }
    #expect(throws: OutfitPlanError.invalidTimeZone) { try OutfitLocalDate.zone("GMT+999") }
  }

  @Test("只保存明确选择的有界组合与最小摘要")
  func inputLimits() throws {
    let date = try OutfitLocalDate("2026-09-13")
    let item = OutfitSelection(itemID: UUID(), revision: 1)
    let input = try OutfitPlanInput(localDate: date, timeZone: "UTC", contextSummary: "  ", items: [item])
    #expect(input.contextSummary == nil && input.items == [item])
    for items in [[], [item, item], [OutfitSelection(itemID: UUID(), revision: 0)],
                  (0..<21).map { _ in OutfitSelection(itemID: UUID(), revision: 1) }] {
      #expect(throws: OutfitPlanError.invalidInput) {
        try OutfitPlanInput(localDate: date, timeZone: "UTC", contextSummary: nil, items: items)
      }
    }
    #expect(throws: OutfitPlanError.invalidInput) {
      try OutfitPlanInput(localDate: date, timeZone: "UTC", contextSummary: nil, items: [item], confirmedUnavailable: [UUID()])
    }
    for summary in [String(repeating: "x", count: 121), "work\nprivate"] {
      #expect(throws: OutfitPlanError.invalidInput) {
        try OutfitPlanInput(localDate: date, timeZone: "UTC", contextSummary: summary, items: [item])
      }
    }
  }

  @Test("日期序列化仍执行校验")
  func decoding() throws {
    let valid = try OutfitLocalDate("2026-09-13")
    #expect(try JSONDecoder().decode(OutfitLocalDate.self, from: JSONEncoder().encode(valid)) == valid)
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(OutfitLocalDate.self, from: Data("\"2026-02-30\"".utf8))
    }
  }
}
