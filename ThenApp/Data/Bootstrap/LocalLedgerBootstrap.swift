import Foundation
import GRDB

nonisolated struct LocalLedgerIdentity: Equatable, Sendable {
  let profileID: UUID
  let defaultCashAccountID: UUID
  let defaultExpenseCategoryID: UUID
  let defaultIncomeCategoryID: UUID
  let baseCurrencyCode: CurrencyCode
  let baseCurrencyState: BaseCurrencyState

  func updating(profile: LocalLedgerProfile) throws -> LocalLedgerIdentity {
    guard profile.id == profileID else {
      throw LocalLedgerBootstrapError.inconsistentLocalProfile
    }
    return LocalLedgerIdentity(
      profileID: profileID,
      defaultCashAccountID: defaultCashAccountID,
      defaultExpenseCategoryID: defaultExpenseCategoryID,
      defaultIncomeCategoryID: defaultIncomeCategoryID,
      baseCurrencyCode: profile.baseCurrencyCode,
      baseCurrencyState: profile.baseCurrencyState
    )
  }
}

nonisolated struct LocalLedgerBootstrap: Sendable {
  private struct AccountDefinition: Equatable, Sendable {
    let systemKey: String
    let kind: String
    let subtype: String
    let name: String
    let configurationState: String
    let displayOrder: Int
  }

  private static let defaultCashSystemKey = "asset.cash.default"

  private static let accountDefinitions = [
    AccountDefinition(
      systemKey: "equity.opening",
      kind: "equity",
      subtype: "opening_balance",
      name: "期初权益",
      configurationState: "ready",
      displayOrder: 0
    ),
    AccountDefinition(
      systemKey: "expense.uncategorized",
      kind: "expense",
      subtype: "uncategorized",
      name: "未分类支出",
      configurationState: "ready",
      displayOrder: 1
    ),
    AccountDefinition(
      systemKey: "expense.food",
      kind: "expense",
      subtype: "food",
      name: "餐饮",
      configurationState: "ready",
      displayOrder: 2
    ),
    AccountDefinition(
      systemKey: "expense.transport",
      kind: "expense",
      subtype: "transport",
      name: "交通",
      configurationState: "ready",
      displayOrder: 3
    ),
    AccountDefinition(
      systemKey: "expense.shopping",
      kind: "expense",
      subtype: "shopping",
      name: "购物",
      configurationState: "ready",
      displayOrder: 4
    ),
    AccountDefinition(
      systemKey: "expense.housing",
      kind: "expense",
      subtype: "housing",
      name: "居住",
      configurationState: "ready",
      displayOrder: 5
    ),
    AccountDefinition(
      systemKey: "expense.other",
      kind: "expense",
      subtype: "other_expense",
      name: "其他支出",
      configurationState: "ready",
      displayOrder: 6
    ),
    AccountDefinition(
      systemKey: "income.uncategorized",
      kind: "income",
      subtype: "uncategorized",
      name: "未分类收入",
      configurationState: "ready",
      displayOrder: 7
    ),
    AccountDefinition(
      systemKey: "income.salary",
      kind: "income",
      subtype: "salary",
      name: "工资",
      configurationState: "ready",
      displayOrder: 8
    ),
    AccountDefinition(
      systemKey: "income.other",
      kind: "income",
      subtype: "other_income",
      name: "其他收入",
      configurationState: "ready",
      displayOrder: 9
    ),
    AccountDefinition(
      systemKey: defaultCashSystemKey,
      kind: "asset",
      subtype: "cash",
      name: "现金",
      configurationState: "pending_currency_confirmation",
      displayOrder: 10
    ),
  ]

  private let database: AppDatabase

  init(database: AppDatabase) {
    self.database = database
  }

  func initializeIfNeeded(
    suggestedCurrencyCode: CurrencyCode,
    now: Date = Date()
  ) throws -> LocalLedgerIdentity {
    try database.pool.write { database in
      let timestamp = now.timeIntervalSince1970
      let existingProfileID = try String.fetchOne(
        database,
        sql: "SELECT id FROM local_profiles WHERE singleton_key = 1"
      )
      let profileID = existingProfileID ?? UUID().uuidString.lowercased()

      if existingProfileID == nil {
        try database.execute(
          sql: """
            INSERT INTO local_profiles (
              id,
              singleton_key,
              base_currency_code,
              base_currency_state,
              created_at,
              updated_at
            ) VALUES (?, 1, ?, 'suggested', ?, ?)
            """,
          arguments: [profileID, suggestedCurrencyCode.rawValue, timestamp, timestamp]
        )
      }

      guard
        let profileRow = try Row.fetchOne(
          database,
          sql: """
            SELECT base_currency_code, base_currency_state
            FROM local_profiles
            WHERE id = ?
            """,
          arguments: [profileID]
        )
      else {
        throw LocalLedgerBootstrapError.inconsistentLocalProfile
      }
      let storedCurrencyCodeRawValue: String = profileRow["base_currency_code"]
      let storedCurrencyStateRawValue: String = profileRow["base_currency_state"]
      guard let storedCurrencyCode = CurrencyCode(rawValue: storedCurrencyCodeRawValue),
        let storedCurrencyState = BaseCurrencyState(rawValue: storedCurrencyStateRawValue)
      else {
        throw LocalLedgerBootstrapError.inconsistentLocalProfile
      }

      for definition in Self.accountDefinitions {
        try database.execute(
          sql: """
            INSERT INTO ledger_accounts (
              id,
              owner_id,
              parent_id,
              kind,
              subtype,
              name,
              native_currency_code,
              configuration_state,
              system_key,
              status,
              display_order,
              created_at,
              updated_at
            ) VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?, 'active', ?, ?, ?)
            ON CONFLICT (owner_id, system_key) DO NOTHING
            """,
          arguments: [
            UUID().uuidString.lowercased(),
            profileID,
            definition.kind,
            definition.subtype,
            definition.name,
            storedCurrencyCode.rawValue,
            definition.configurationState,
            definition.systemKey,
            definition.displayOrder,
            timestamp,
            timestamp,
          ]
        )
      }

      let accountRows = try Row.fetchAll(
        database,
        sql: """
          SELECT
            id,
            system_key,
            kind,
            subtype,
            name,
            native_currency_code,
            configuration_state,
            display_order
          FROM ledger_accounts
          WHERE owner_id = ? AND system_key IS NOT NULL
          """,
        arguments: [profileID]
      )
      guard accountRows.count == Self.accountDefinitions.count else {
        throw LocalLedgerBootstrapError.inconsistentBuiltInAccounts
      }

      let expectedDefinitions = Dictionary(
        uniqueKeysWithValues: Self.accountDefinitions.map { definition in
          let expectedConfigurationState =
            storedCurrencyState == .confirmed ? "ready" : definition.configurationState
          return (
            definition.systemKey,
            AccountDefinition(
              systemKey: definition.systemKey,
              kind: definition.kind,
              subtype: definition.subtype,
              name: definition.name,
              configurationState: expectedConfigurationState,
              displayOrder: definition.displayOrder
            )
          )
        }
      )
      var defaultCashAccountID: UUID?
      var defaultExpenseCategoryID: UUID?
      var defaultIncomeCategoryID: UUID?

      for row in accountRows {
        let systemKey: String = row["system_key"]
        let actualDefinition = AccountDefinition(
          systemKey: systemKey,
          kind: row["kind"],
          subtype: row["subtype"],
          name: row["name"],
          configurationState: row["configuration_state"],
          displayOrder: row["display_order"]
        )
        guard expectedDefinitions[systemKey] == actualDefinition else {
          throw LocalLedgerBootstrapError.inconsistentBuiltInAccounts
        }
        let nativeCurrencyCode: String = row["native_currency_code"]
        guard nativeCurrencyCode == storedCurrencyCode.rawValue else {
          throw LocalLedgerBootstrapError.inconsistentBuiltInAccounts
        }

        let identifier: String = row["id"]
        let accountID = UUID(uuidString: identifier)
        switch systemKey {
        case Self.defaultCashSystemKey:
          defaultCashAccountID = accountID
        case "expense.uncategorized":
          defaultExpenseCategoryID = accountID
        case "income.uncategorized":
          defaultIncomeCategoryID = accountID
        default:
          break
        }
      }

      guard let parsedProfileID = UUID(uuidString: profileID),
        let defaultCashAccountID,
        let defaultExpenseCategoryID,
        let defaultIncomeCategoryID
      else {
        throw LocalLedgerBootstrapError.invalidIdentifier
      }

      return LocalLedgerIdentity(
        profileID: parsedProfileID,
        defaultCashAccountID: defaultCashAccountID,
        defaultExpenseCategoryID: defaultExpenseCategoryID,
        defaultIncomeCategoryID: defaultIncomeCategoryID,
        baseCurrencyCode: storedCurrencyCode,
        baseCurrencyState: storedCurrencyState
      )
    }
  }
}

nonisolated enum LocalLedgerBootstrapError: Error, Equatable {
  case inconsistentBuiltInAccounts
  case inconsistentLocalProfile
  case invalidIdentifier
}
