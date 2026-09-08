import Foundation

nonisolated enum LedgerAmountText {
  enum ParsingError: Error, Equatable {
    case empty
    case invalidCharacters
    case tooManyFractionDigits
    case outOfRange
  }

  static func parsePositiveMoney(
    _ text: String,
    currencyCode: CurrencyCode,
    locale: Locale = .current
  ) throws -> PositiveMoney {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ParsingError.empty
    }

    let localeSeparator = locale.decimalSeparator ?? "."
    var normalized =
      trimmed
      .replacingOccurrences(of: "。", with: ".")
      .replacingOccurrences(of: "，", with: ",")
    if localeSeparator != "." {
      normalized = normalized.replacingOccurrences(of: localeSeparator, with: ".")
    }
    if localeSeparator != "," {
      normalized = normalized.replacingOccurrences(of: ",", with: ".")
    }

    let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count <= 2,
      let wholePart = components.first,
      !wholePart.isEmpty,
      wholePart.allSatisfy(\.isNumber)
    else {
      throw ParsingError.invalidCharacters
    }

    let fractionPart = components.count == 2 ? components[1] : Substring()
    guard fractionPart.allSatisfy(\.isNumber) else {
      throw ParsingError.invalidCharacters
    }

    let fractionDigits = currencyFractionDigits(currencyCode)
    guard fractionPart.count <= fractionDigits else {
      throw ParsingError.tooManyFractionDigits
    }
    guard let wholeMinorUnits = Int64(wholePart) else {
      throw ParsingError.outOfRange
    }

    var scale: Int64 = 1
    for _ in 0..<fractionDigits {
      let (nextScale, overflow) = scale.multipliedReportingOverflow(by: 10)
      guard !overflow else { throw ParsingError.outOfRange }
      scale = nextScale
    }
    let (scaledWhole, wholeOverflow) = wholeMinorUnits.multipliedReportingOverflow(by: scale)
    guard !wholeOverflow else {
      throw ParsingError.outOfRange
    }

    let paddedFraction =
      String(fractionPart)
      + String(repeating: "0", count: fractionDigits - fractionPart.count)
    let fractionalMinorUnits = Int64(paddedFraction) ?? 0
    let (minorUnits, totalOverflow) = scaledWhole.addingReportingOverflow(fractionalMinorUnits)
    guard !totalOverflow else {
      throw ParsingError.outOfRange
    }
    return try PositiveMoney(minorUnits: minorUnits, currencyCode: currencyCode)
  }

  static func formatted(
    _ money: PositiveMoney,
    locale: Locale = .current
  ) -> String {
    let fractionDigits = currencyFractionDigits(money.currencyCode)
    var scale = Decimal(1)
    for _ in 0..<fractionDigits {
      scale *= 10
    }
    let value = Decimal(money.minorUnits) / scale

    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .currency
    formatter.currencyCode = money.currencyCode.rawValue
    formatter.minimumFractionDigits = fractionDigits
    formatter.maximumFractionDigits = fractionDigits
    return formatter.string(from: NSDecimalNumber(decimal: value))
      ?? "\(money.currencyCode.rawValue) \(money.minorUnits)"
  }

  static func formatted(
    _ money: SignedMoney,
    locale: Locale = .current
  ) -> String {
    let fractionDigits = currencyFractionDigits(money.currencyCode)
    var scale = Decimal(1)
    for _ in 0..<fractionDigits {
      scale *= 10
    }
    let value = Decimal(money.minorUnits) / scale

    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .currency
    formatter.currencyCode = money.currencyCode.rawValue
    formatter.minimumFractionDigits = fractionDigits
    formatter.maximumFractionDigits = fractionDigits
    return formatter.string(from: NSDecimalNumber(decimal: value))
      ?? "\(money.currencyCode.rawValue) \(money.minorUnits)"
  }

  static func accessibilityFormatted(
    _ money: SignedMoney,
    locale: Locale = .current
  ) -> String {
    let fractionDigits = currencyFractionDigits(money.currencyCode)
    var scale = Decimal(1)
    for _ in 0..<fractionDigits {
      scale *= 10
    }
    let value = Decimal(money.minorUnits) / scale

    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .currencyPlural
    formatter.currencyCode = money.currencyCode.rawValue
    formatter.minimumFractionDigits = fractionDigits
    formatter.maximumFractionDigits = fractionDigits
    return formatter.string(from: NSDecimalNumber(decimal: value))
      ?? "\(money.minorUnits) \(money.currencyCode.rawValue) 最小货币单位"
  }

  static func accessibilityFormatted(
    _ money: PositiveMoney,
    locale: Locale = .current
  ) -> String {
    accessibilityFormatted(
      SignedMoney(minorUnits: money.minorUnits, currencyCode: money.currencyCode),
      locale: locale
    )
  }

  private static func currencyFractionDigits(_ currencyCode: CurrencyCode) -> Int {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = currencyCode.rawValue
    return max(0, formatter.maximumFractionDigits)
  }
}
