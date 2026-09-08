import Foundation
import Testing
import UIKit

@testable import ThenApp

@Suite("端侧票据识别")
struct ReceiptOCRTests {
  @Test("解析金额商户日期币种和订单号并标记可信度")
  func parserExtractsReceiptFields() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let referenceDate = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 18))
    )
    let candidate = try ReceiptOCRParser(calendar: calendar).parse(
      lines: [
        ReceiptOCRLine(text: "星河餐厅", confidence: 0.98),
        ReceiptOCRLine(text: "订单号 TH20260810001", confidence: 0.93),
        ReceiptOCRLine(text: "2026-08-10 12:30", confidence: 0.96),
        ReceiptOCRLine(text: "合计 ￥88.60", confidence: 0.97),
      ],
      referenceDate: referenceDate,
      baseCurrencyCode: .cny
    )

    #expect(candidate.amount?.value == "88.6")
    #expect(candidate.amount?.isLowConfidence == false)
    #expect(candidate.payee?.value == "星河餐厅")
    #expect(candidate.currencyCode?.value == .cny)
    #expect(candidate.orderIdentifier?.value == "TH20260810001")
    let dateComponents = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute],
      from: try #require(candidate.occurredAt?.value)
    )
    #expect(dateComponents.year == 2026)
    #expect(dateComponents.month == 8)
    #expect(dateComponents.day == 10)
    #expect(dateComponents.hour == 12)
    #expect(dateComponents.minute == 30)
  }

  @Test("无关键词金额和推断币种必须提示低置信度")
  func parserMarksFallbackFieldsLowConfidence() throws {
    let candidate = try ReceiptOCRParser().parse(
      lines: [
        ReceiptOCRLine(text: "合成便利店", confidence: 0.92),
        ReceiptOCRLine(text: "58.00", confidence: 0.91),
      ],
      referenceDate: Date(timeIntervalSince1970: 1_786_287_000),
      baseCurrencyCode: .cny
    )

    #expect(candidate.amount?.value == "58")
    #expect(candidate.amount?.isLowConfidence == true)
    #expect(candidate.currencyCode?.source == .inferredBaseCurrency)
    #expect(candidate.lowConfidenceFields.contains(.amount))
    #expect(candidate.lowConfidenceFields.contains(.currency))
  }

  @Test("没有可用字段时不会生成空候选")
  func parserRejectsEmptyCandidate() {
    #expect(throws: ReceiptOCRError.noUsableCandidate) {
      try ReceiptOCRParser().parse(
        lines: [ReceiptOCRLine(text: "---", confidence: 0.9)],
        referenceDate: Date(timeIntervalSince1970: 1_786_287_000),
        baseCurrencyCode: .cny
      )
    }
  }

  @Test("Vision 可从合成图片产生会话候选")
  func visionRecognizesSyntheticReceipt() async throws {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1_200, height: 800))
    let image = renderer.image { context in
      UIColor.white.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 800))
      let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 72, weight: .medium),
        .foregroundColor: UIColor.black,
      ]
      let text = "星河餐厅\n合计 ￥88.60\n2026-08-10 12:30"
      (text as NSString).draw(
        in: CGRect(x: 80, y: 80, width: 1_040, height: 640),
        withAttributes: attributes
      )
    }
    let imageData = try #require(image.jpegData(compressionQuality: 0.95))

    let candidate = try await VisionReceiptOCRService().recognizeReceipt(
      imageData: imageData,
      referenceDate: Date(timeIntervalSince1970: 1_786_287_000),
      baseCurrencyCode: .cny
    )
    #expect(candidate.hasUsableContent)
    #expect(candidate.amount != nil)
  }

  @Test("候选采用前后都不会绕过用户保存")
  @MainActor
  func candidateOnlyPrefillsManualForm() async throws {
    try await withAsyncTestDatabase { database in
      let timestamp = Date(timeIntervalSince1970: 1_786_287_500)
      let identity = try LocalLedgerBootstrap(database: database).initializeIfNeeded(
        suggestedCurrencyCode: .cny,
        now: Date(timeIntervalSince1970: 1_786_287_000)
      )
      let repository = GRDBLedgerRepository(database: database)
      _ = try await ConfirmBaseCurrencyUseCase(repository: repository).execute(
        ownerID: identity.profileID,
        currencyCode: .cny,
        confirmedAt: Date(timeIntervalSince1970: 1_786_287_010)
      )
      _ = try await repository.createTransaction(
        CreateLedgerTransactionRequest(
          transactionID: UUID(),
          ownerID: identity.profileID,
          details: .expense(
            paymentAccountID: identity.defaultCashAccountID,
            categoryAccountID: identity.defaultExpenseCategoryID
          ),
          money: PositiveMoney(minorUnits: 4_200, currencyCode: .cny),
          occurredAt: timestamp,
          originalTimeZoneIdentifier: "Asia/Shanghai",
          payee: "合成餐厅",
          submittedAt: timestamp
        )
      )
      let candidate = ReceiptOCRCandidate(
        amount: ReceiptOCRField(value: "42", confidence: 0.98, source: .keyword),
        payee: ReceiptOCRField(value: "合成餐厅", confidence: 0.95, source: .layout),
        occurredAt: ReceiptOCRField(value: timestamp, confidence: 0.9, source: .explicitValue),
        currencyCode: ReceiptOCRField(value: .cny, confidence: 0.95, source: .explicitValue),
        orderIdentifier: ReceiptOCRField(
          value: "TEST-ORDER-001",
          confidence: 0.9,
          source: .keyword
        )
      )
      let model = QuickTransactionViewModel(
        identity: identity,
        confirmBaseCurrency: ConfirmBaseCurrencyUseCase(repository: repository),
        createTransaction: CreateTransactionUseCase(repository: repository),
        ledgerQuery: LedgerQueryService(repository: repository),
        receiptOCR: FixedReceiptOCRService(candidate: candidate),
        now: { timestamp },
        timeZoneIdentifier: { "Asia/Shanghai" }
      )
      await model.loadAccounts()
      model.amountText = "1"

      await model.recognizeReceiptImage(Data([0x01]))
      #expect(model.receiptCandidate == candidate)
      #expect(model.amountText == "1")
      #expect(model.savedTransaction == nil)
      #expect(model.receiptDuplicateMatches.count == 1)
      #expect(
        try await repository.recentTransactions(ownerID: identity.profileID, limit: 10).count == 1)

      model.applyReceiptCandidate()
      #expect(model.amountText == "42")
      #expect(model.payee == "合成餐厅")
      #expect(model.note == "订单号：TEST-ORDER-001")
      #expect(model.savedTransaction == nil)
      #expect(
        try await repository.recentTransactions(ownerID: identity.profileID, limit: 10).count == 1)

      await model.save()
      #expect(model.savedTransaction?.kind == .expense)
      #expect(model.savedTransaction?.source == .ocr)
      #expect(
        try await repository.recentTransactions(ownerID: identity.profileID, limit: 10).count == 2)
    }
  }

  @Test("相机权限拒绝不改变手动输入")
  @MainActor
  func deniedCameraPermissionPreservesManualInput() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try LocalLedgerBootstrap(database: database).initializeIfNeeded(
        suggestedCurrencyCode: .cny,
        now: Date(timeIntervalSince1970: 1_786_287_000)
      )
      let repository = GRDBLedgerRepository(database: database)
      let model = QuickTransactionViewModel(
        identity: identity,
        confirmBaseCurrency: ConfirmBaseCurrencyUseCase(repository: repository),
        createTransaction: CreateTransactionUseCase(repository: repository),
        ledgerQuery: LedgerQueryService(repository: repository),
        receiptOCR: FixedReceiptOCRService(
          candidate: ReceiptOCRCandidate(
            amount: nil,
            payee: nil,
            occurredAt: nil,
            currencyCode: nil,
            orderIdentifier: nil
          )
        ),
        receiptCameraAccess: FixedReceiptCameraAccessService(access: .denied)
      )
      model.amountText = "12.34"

      #expect(await model.requestReceiptCameraAccess() == false)
      #expect(model.amountText == "12.34")
      #expect(model.receiptMessage != nil)
      #expect(model.savedTransaction == nil)
    }
  }
}

private nonisolated struct FixedReceiptOCRService: ReceiptOCRService {
  let candidate: ReceiptOCRCandidate

  func recognizeReceipt(
    imageData: Data,
    referenceDate: Date,
    baseCurrencyCode: CurrencyCode
  ) async throws -> ReceiptOCRCandidate {
    candidate
  }
}

private nonisolated struct FixedReceiptCameraAccessService: ReceiptCameraAccessService {
  let access: ReceiptCameraAccess

  func requestAccess() async -> ReceiptCameraAccess {
    access
  }
}
