import Foundation
import Testing

@testable import ThenApp

@Suite("金额输入")
struct LedgerAmountTextTests {
  @Test("VoiceOver 金额使用货币全称")
  func accessibilityAmountUsesCurrencyName() throws {
    let amount = SignedMoney(minorUnits: 1_234, currencyCode: .cny)
    let positiveAmount = try PositiveMoney(minorUnits: 1_234, currencyCode: .cny)

    let result = LedgerAmountText.accessibilityFormatted(
      amount,
      locale: Locale(identifier: "zh_CN")
    )
    let positiveResult = LedgerAmountText.accessibilityFormatted(
      positiveAmount,
      locale: Locale(identifier: "zh_CN")
    )

    #expect(result.contains("12.34"))
    #expect(result.contains("人民币"))
    #expect(!result.contains("¥"))
    #expect(positiveResult == result)
  }

  @Test("按币种小数位精确转换为整数最小货币单位")
  func parsesExactMinorUnits() throws {
    let dotMoney = try LedgerAmountText.parsePositiveMoney(
      "12.50",
      currencyCode: .cny,
      locale: Locale(identifier: "zh_CN")
    )
    let commaMoney = try LedgerAmountText.parsePositiveMoney(
      "12,5",
      currencyCode: .cny,
      locale: Locale(identifier: "fr_FR")
    )
    let fullWidthMoney = try LedgerAmountText.parsePositiveMoney(
      "12。50",
      currencyCode: .cny,
      locale: Locale(identifier: "zh_CN")
    )

    #expect(dotMoney.minorUnits == 1_250)
    #expect(commaMoney.minorUnits == 1_250)
    #expect(fullWidthMoney.minorUnits == 1_250)
    #expect(dotMoney.currencyCode == .cny)
  }

  @Test("拒绝空值、多余小数位、负数和溢出金额")
  func rejectsInvalidAmountText() {
    #expect(throws: LedgerAmountText.ParsingError.empty) {
      try LedgerAmountText.parsePositiveMoney("  ", currencyCode: .cny)
    }
    #expect(throws: LedgerAmountText.ParsingError.tooManyFractionDigits) {
      try LedgerAmountText.parsePositiveMoney("1.001", currencyCode: .cny)
    }
    #expect(throws: LedgerAmountText.ParsingError.invalidCharacters) {
      try LedgerAmountText.parsePositiveMoney("-1", currencyCode: .cny)
    }
    #expect(throws: LedgerAmountText.ParsingError.outOfRange) {
      try LedgerAmountText.parsePositiveMoney(
        "999999999999999999999999999",
        currencyCode: .cny
      )
    }
  }
}
