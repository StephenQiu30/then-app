import Foundation

nonisolated enum ReceiptOCRFieldSource: Sendable, Equatable {
  case keyword
  case explicitValue
  case layout
  case inferredBaseCurrency
}

nonisolated enum ReceiptOCRFieldKind: Sendable, Equatable, CaseIterable {
  case amount
  case payee
  case occurredAt
  case currency
  case orderIdentifier
}

nonisolated struct ReceiptOCRField<Value: Sendable & Equatable>: Sendable, Equatable {
  let value: Value
  let confidence: Float
  let source: ReceiptOCRFieldSource

  var isLowConfidence: Bool {
    confidence < 0.8 || source == .inferredBaseCurrency
  }
}

nonisolated struct ReceiptOCRCandidate: Sendable, Equatable {
  let amount: ReceiptOCRField<String>?
  let payee: ReceiptOCRField<String>?
  let occurredAt: ReceiptOCRField<Date>?
  let currencyCode: ReceiptOCRField<CurrencyCode>?
  let orderIdentifier: ReceiptOCRField<String>?

  var lowConfidenceFields: [ReceiptOCRFieldKind] {
    var fields: [ReceiptOCRFieldKind] = []
    if amount?.isLowConfidence == true { fields.append(.amount) }
    if payee?.isLowConfidence == true { fields.append(.payee) }
    if occurredAt?.isLowConfidence == true { fields.append(.occurredAt) }
    if currencyCode?.isLowConfidence == true { fields.append(.currency) }
    if orderIdentifier?.isLowConfidence == true { fields.append(.orderIdentifier) }
    return fields
  }

  var hasUsableContent: Bool {
    amount != nil || payee != nil || occurredAt != nil || orderIdentifier != nil
  }
}

nonisolated struct ReceiptOCRLine: Sendable, Equatable {
  let text: String
  let confidence: Float
}

nonisolated enum ReceiptOCRError: Error, Sendable, Equatable {
  case emptyImage
  case noRecognizedText
  case noUsableCandidate
}

nonisolated protocol ReceiptOCRService: Sendable {
  func recognizeReceipt(
    imageData: Data,
    referenceDate: Date,
    baseCurrencyCode: CurrencyCode
  ) async throws -> ReceiptOCRCandidate
}

nonisolated enum ReceiptCameraAccess: Sendable, Equatable {
  case allowed
  case denied
}

nonisolated protocol ReceiptCameraAccessService: Sendable {
  func requestAccess() async -> ReceiptCameraAccess
}

nonisolated struct ReceiptOCRParser: Sendable {
  private struct ScoredField<Value: Sendable & Equatable>: Sendable {
    let field: ReceiptOCRField<Value>
    let score: Float
  }

  private let calendar: Calendar

  init(calendar: Calendar = .current) {
    self.calendar = calendar
  }

  func parse(
    lines: [ReceiptOCRLine],
    referenceDate: Date,
    baseCurrencyCode: CurrencyCode
  ) throws -> ReceiptOCRCandidate {
    let sanitizedLines = lines.compactMap { line -> ReceiptOCRLine? in
      let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      return ReceiptOCRLine(text: text, confidence: normalizedConfidence(line.confidence))
    }
    guard !sanitizedLines.isEmpty else { throw ReceiptOCRError.noRecognizedText }

    let candidate = ReceiptOCRCandidate(
      amount: amount(in: sanitizedLines),
      payee: payee(in: sanitizedLines),
      occurredAt: occurredAt(in: sanitizedLines, referenceDate: referenceDate),
      currencyCode: currency(in: sanitizedLines, fallback: baseCurrencyCode),
      orderIdentifier: orderIdentifier(in: sanitizedLines)
    )
    guard candidate.hasUsableContent else { throw ReceiptOCRError.noUsableCandidate }
    return candidate
  }

  private func amount(in lines: [ReceiptOCRLine]) -> ReceiptOCRField<String>? {
    let keywordPattern =
      "(?i)(?:合计|总计|应付|实付|付款金额|金额|total|amount)[^0-9]{0,12}([0-9][0-9,.]{0,14})"
    let currencyPattern = "(?i)(?:¥|￥|CNY|RMB)\\s*([0-9][0-9,.]{0,14})"
    let fallbackPattern = "(?:^|[^0-9])([0-9]{1,7}(?:[.,][0-9]{1,2})?)(?:$|[^0-9])"
    var matches: [ScoredField<String>] = []

    for line in lines {
      if let raw = firstCapture(pattern: keywordPattern, in: line.text),
        let value = normalizedPositiveAmount(raw)
      {
        let confidence = min(1, line.confidence + 0.08)
        matches.append(
          ScoredField(
            field: ReceiptOCRField(
              value: value,
              confidence: confidence,
              source: .keyword
            ),
            score: confidence + 0.3
          )
        )
        continue
      }

      if let raw = firstCapture(pattern: currencyPattern, in: line.text),
        let value = normalizedPositiveAmount(raw)
      {
        matches.append(
          ScoredField(
            field: ReceiptOCRField(
              value: value,
              confidence: line.confidence,
              source: .explicitValue
            ),
            score: line.confidence + 0.15
          )
        )
        continue
      }

      let lowercase = line.text.lowercased()
      let excludedKeywords = ["日期", "时间", "订单", "流水", "电话", "会员", "date", "time", "order"]
      guard !excludedKeywords.contains(where: lowercase.contains) else { continue }
      if let raw = firstCapture(pattern: fallbackPattern, in: line.text),
        let value = normalizedPositiveAmount(raw)
      {
        let confidence = min(0.65, line.confidence * 0.7)
        matches.append(
          ScoredField(
            field: ReceiptOCRField(
              value: value,
              confidence: confidence,
              source: .layout
            ),
            score: confidence
          )
        )
      }
    }

    return matches.max(by: { $0.score < $1.score })?.field
  }

  private func payee(in lines: [ReceiptOCRLine]) -> ReceiptOCRField<String>? {
    let excluded = [
      "小票", "收据", "发票", "订单", "流水", "电话", "地址", "时间", "日期", "欢迎", "谢谢", "合计", "总计",
      "金额", "total", "amount", "receipt", "order",
    ]
    var matches: [ScoredField<String>] = []

    for (index, line) in lines.prefix(8).enumerated() {
      let lowercase = line.text.lowercased()
      guard !excluded.contains(where: lowercase.contains) else { continue }
      guard line.text.count >= 2, line.text.count <= 40 else { continue }
      guard line.text.range(of: "[A-Za-z\\p{Han}]", options: .regularExpression) != nil else {
        continue
      }
      let digitCount = line.text.unicodeScalars.filter(CharacterSet.decimalDigits.contains).count
      guard digitCount * 2 <= line.text.count else { continue }

      let positionBonus: Float = index < 3 ? 0.12 : 0
      let confidence = min(1, line.confidence + positionBonus)
      matches.append(
        ScoredField(
          field: ReceiptOCRField(
            value: line.text,
            confidence: confidence,
            source: .layout
          ),
          score: confidence - Float(index) * 0.025
        )
      )
    }

    return matches.max(by: { $0.score < $1.score })?.field
  }

  private func occurredAt(
    in lines: [ReceiptOCRLine],
    referenceDate: Date
  ) -> ReceiptOCRField<Date>? {
    let fullDatePattern =
      "(?:^|[^0-9])(20[0-9]{2})[-/.年]([01]?[0-9])[-/.月]([0-3]?[0-9])(?:日|[^0-9]|$)"
    let shortDatePattern = "(?:^|[^0-9])([01]?[0-9])[-/.月]([0-3]?[0-9])(?:日|[^0-9]|$)"

    for line in lines {
      if let groups = captureGroups(pattern: fullDatePattern, in: line.text),
        groups.count == 3,
        let year = Int(groups[0]),
        let month = Int(groups[1]),
        let day = Int(groups[2]),
        let date = date(
          year: year,
          month: month,
          day: day,
          line: line.text,
          referenceDate: referenceDate
        )
      {
        return ReceiptOCRField(value: date, confidence: line.confidence, source: .explicitValue)
      }
    }

    let referenceYear = calendar.component(.year, from: referenceDate)
    for line in lines {
      if let groups = captureGroups(pattern: shortDatePattern, in: line.text),
        groups.count == 2,
        let month = Int(groups[0]),
        let day = Int(groups[1]),
        let date = date(
          year: referenceYear,
          month: month,
          day: day,
          line: line.text,
          referenceDate: referenceDate
        )
      {
        return ReceiptOCRField(
          value: date,
          confidence: min(0.72, line.confidence),
          source: .layout
        )
      }
    }
    return nil
  }

  private func currency(
    in lines: [ReceiptOCRLine],
    fallback: CurrencyCode
  ) -> ReceiptOCRField<CurrencyCode> {
    for line in lines {
      let uppercase = line.text.uppercased()
      if uppercase.contains("CNY") || uppercase.contains("RMB")
        || line.text.contains("人民币") || line.text.contains("¥") || line.text.contains("￥")
      {
        return ReceiptOCRField(
          value: .cny,
          confidence: line.confidence,
          source: .explicitValue
        )
      }
      if uppercase.contains("USD") || line.text.contains("$") {
        if let usd = CurrencyCode(rawValue: "USD") {
          return ReceiptOCRField(
            value: usd,
            confidence: line.confidence,
            source: .explicitValue
          )
        }
      }
      if uppercase.contains("EUR") || line.text.contains("€") {
        if let eur = CurrencyCode(rawValue: "EUR") {
          return ReceiptOCRField(
            value: eur,
            confidence: line.confidence,
            source: .explicitValue
          )
        }
      }
    }

    return ReceiptOCRField(
      value: fallback,
      confidence: 0.5,
      source: .inferredBaseCurrency
    )
  }

  private func orderIdentifier(in lines: [ReceiptOCRLine]) -> ReceiptOCRField<String>? {
    let pattern =
      "(?i)(?:订单号|流水号|交易号|单号|order(?:\\s*no)?)[\\s:#：-]*([A-Z0-9-]{5,40})"
    for line in lines {
      if let value = firstCapture(pattern: pattern, in: line.text) {
        return ReceiptOCRField(
          value: value,
          confidence: line.confidence,
          source: .keyword
        )
      }
    }
    return nil
  }

  private func date(
    year: Int,
    month: Int,
    day: Int,
    line: String,
    referenceDate: Date
  ) -> Date? {
    guard (1...12).contains(month), (1...31).contains(day) else { return nil }
    let timePattern = "(?:^|[^0-9])([0-2]?[0-9]):([0-5][0-9])(?:[^0-9]|$)"
    let timeGroups = captureGroups(pattern: timePattern, in: line)
    let referenceComponents = calendar.dateComponents([.hour, .minute], from: referenceDate)
    let hour = timeGroups.flatMap { $0.first }.flatMap(Int.init) ?? referenceComponents.hour ?? 12
    let minute =
      timeGroups.flatMap { $0.dropFirst().first }.flatMap(Int.init)
      ?? referenceComponents.minute ?? 0
    guard (0...23).contains(hour) else { return nil }

    var components = DateComponents()
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    guard let result = calendar.date(from: components) else { return nil }
    let validated = calendar.dateComponents([.year, .month, .day], from: result)
    guard validated.year == year, validated.month == month, validated.day == day else { return nil }
    return result
  }

  private func normalizedPositiveAmount(_ rawValue: String) -> String? {
    var value =
      rawValue
      .replacingOccurrences(of: "，", with: ",")
      .replacingOccurrences(of: "。", with: ".")
      .filter { $0.isNumber || $0 == "." || $0 == "," }
    guard !value.isEmpty else { return nil }

    if value.contains(".") {
      value.removeAll(where: { $0 == "," })
    } else if let comma = value.lastIndex(of: ",") {
      let fractionalCount = value.distance(from: value.index(after: comma), to: value.endIndex)
      if (1...2).contains(fractionalCount) {
        value.replaceSubrange(comma...comma, with: ".")
      } else {
        value.removeAll(where: { $0 == "," })
      }
    }

    guard value.filter({ $0 == "." }).count <= 1,
      let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
      decimal > 0
    else {
      return nil
    }
    return NSDecimalNumber(decimal: decimal).stringValue
  }

  private func firstCapture(pattern: String, in text: String) -> String? {
    captureGroups(pattern: pattern, in: text)?.first
  }

  private func captureGroups(pattern: String, in text: String) -> [String]? {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(location: 0, length: (text as NSString).length)
    guard let match = expression.firstMatch(in: text, range: range), match.numberOfRanges > 1 else {
      return nil
    }

    var values: [String] = []
    for index in 1..<match.numberOfRanges {
      guard let range = Range(match.range(at: index), in: text) else { return nil }
      values.append(String(text[range]))
    }
    return values
  }

  private func normalizedConfidence(_ confidence: Float) -> Float {
    min(1, max(0, confidence))
  }
}
