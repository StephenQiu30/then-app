import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
import ThenTransport

@Suite("生成 API 跨模块契约")
struct ThenTransportTests {
  @Test("非 MainActor 调用生成 Client 并解码存活响应")
  @concurrent
  func livenessFromConcurrentContext() async throws {
    let transport = FixtureTransport(
      status: .ok,
      json: #"{"status":"live","request_id":"TESTREQUESTIDENTIFIER00000001"}"#
    )
    let client = Client(serverURL: try #require(URL(string: "https://example.invalid/v1")),
                        transport: transport)
    let result = try await client.getLiveness().ok.body.json
    #expect(result.status == .live)
    #expect(result.requestId == "TESTREQUESTIDENTIFIER00000001")
    let request = try #require(await transport.lastRequest)
    #expect(request.method == .get)
    #expect(request.path == "/health/live")
    #expect(await transport.lastBaseURL?.path == "/v1")
    #expect(await transport.lastOperationID == "getLiveness")
    #expect(await transport.receivedBody == false)
  }

  @Test("未就绪响应保留错误码、重试标志与 Retry-After")
  @concurrent
  func readinessError() async throws {
    let transport = FixtureTransport(
      status: .serviceUnavailable,
      json: #"{"code":"NOT_READY","message":"Service is not ready.","request_id":"TESTREQUESTIDENTIFIER00000003","retryable":true}"#
    )
    let client = Client(serverURL: try #require(URL(string: "https://example.invalid/v1")),
                        transport: transport)
    let response = try await client.getReadiness().serviceUnavailable
    let error = try response.body.json
    #expect(error.code == .notReady)
    #expect(error.retryable)
    #expect(error.requestId == "TESTREQUESTIDENTIFIER00000003")
    #expect(response.headers.retryAfter?.rawValue == "1")
    #expect(await transport.lastRequest?.path == "/health/ready")
    #expect(await transport.lastOperationID == "getReadiness")
  }

  @Test("契约外状态枚举不得静默解码为成功")
  @concurrent
  func invalidResponseIsRejected() async throws {
    let transport = FixtureTransport(status: .ok,
      json: #"{"status":"unknown","request_id":"TESTREQUESTIDENTIFIER00000001"}"#)
    let client = Client(serverURL: try #require(URL(string: "https://example.invalid/v1")),
                        transport: transport)
    await #expect(throws: ClientError.self) {
      _ = try await client.getLiveness()
    }
  }
}

private actor FixtureTransport: ClientTransport {
  let status: HTTPResponse.Status
  let json: String
  private(set) var lastRequest: HTTPRequest?
  private(set) var lastBaseURL: URL?
  private(set) var lastOperationID: String?
  private(set) var receivedBody = false

  init(status: HTTPResponse.Status, json: String) {
    self.status = status
    self.json = json
  }

  func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String)
    async throws -> (HTTPResponse, HTTPBody?) {
    lastRequest = request
    lastBaseURL = baseURL
    lastOperationID = operationID
    receivedBody = body != nil
    return (HTTPResponse(status: status, headerFields: [
      .contentType: "application/json", .retryAfter: "1",
    ]), HTTPBody(json))
  }
}
