import Foundation

nonisolated struct CurrencyCode: Codable, Hashable, RawRepresentable, Sendable {
  enum ValidationError: Error, Equatable {
    case invalidISO4217Code
  }

  let rawValue: String

  init?(rawValue: String) {
    let normalized = rawValue.uppercased()
    guard normalized.utf8.count == 3,
      normalized.utf8.allSatisfy({ character in
        character >= 65 && character <= 90
      })
    else {
      return nil
    }

    self.rawValue = normalized
  }

  init(validating rawValue: String) throws {
    guard let currencyCode = CurrencyCode(rawValue: rawValue) else {
      throw ValidationError.invalidISO4217Code
    }

    self = currencyCode
  }

  static let cny = CurrencyCode(unchecked: "CNY")

  private init(unchecked rawValue: String) {
    self.rawValue = rawValue
  }
}
