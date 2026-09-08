import Foundation

nonisolated struct PositiveMoney: Equatable, Sendable {
  enum ValidationError: Error, Equatable {
    case amountMustBePositive
  }

  let minorUnits: Int64
  let currencyCode: CurrencyCode

  init(minorUnits: Int64, currencyCode: CurrencyCode) throws {
    guard minorUnits > 0 else {
      throw ValidationError.amountMustBePositive
    }

    self.minorUnits = minorUnits
    self.currencyCode = currencyCode
  }
}
