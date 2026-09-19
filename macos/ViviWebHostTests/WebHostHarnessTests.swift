import WebKit
import XCTest

@MainActor
final class WebHostHarnessTests: XCTestCase {
  func testScriptMessagePolicyRejectsWrongHandlerOriginAndFrame() {
    assertPolicyRejection(context(name: "other"), equals: .wrongHandler)
    assertPolicyRejection(context(isMainFrame: false), equals: .nonMainFrame)
    assertPolicyRejection(context(securityHost: "attacker"), equals: .unexpectedOrigin)
    XCTAssertNoThrow(try ScriptMessagePolicy.validate(context()))
  }

  func testLoadsPackagedProductionAssetsWithEphemeralStorageAndTearsDown() async throws {
    let harness = WebHostHarness()
    try await harness.start()
    let webView = try XCTUnwrap(harness.webView)

    XCTAssertFalse(webView.configuration.websiteDataStore === WKWebsiteDataStore.default())
    let protocolName = try await webView.evaluateJavaScript(
      "window.webkit.messageHandlers.viviHostV1 ? 'vivi.host' : 'missing'")
    XCTAssertEqual(protocolName as? String, "vivi.host")
    let rendered = try await waitForBoolean(
      in: webView,
      expression: "document.body.textContent.includes('Native bridge proof')")
    let bodyText = try await webView.evaluateJavaScript("document.body.textContent")
    XCTAssertGreaterThan(harness.receivedMessageCount, 0)
    XCTAssertNil(harness.lastBridgeError)
    XCTAssertTrue(
      rendered,
      "\(bodyText ?? "missing body"); messages=\(harness.receivedMessageCount); error=\(String(describing: harness.lastBridgeError))"
    )

    harness.stop()
    XCTAssertNil(harness.webView)
    XCTAssertFalse(harness.hasInstalledScriptHandlers)
    XCTAssertNil(webView.navigationDelegate)
    XCTAssertNil(webView.uiDelegate)
    let receivedBeforeLateMessage = harness.receivedMessageCount
    await harness.receive(
      context: context(),
      body: requestBody(bridge: UUID(), command: "connect", payload: [:]))
    XCTAssertEqual(harness.receivedMessageCount, receivedBeforeLateMessage)
    harness.stop()

    try await harness.start()
    let restartedWebView = try XCTUnwrap(harness.webView)
    let restarted = try await waitForBoolean(
      in: restartedWebView,
      expression: "document.body.textContent.includes('Native bridge proof')")
    XCTAssertTrue(restarted)
    harness.stop()
  }

  func testNavigationPolicyRejectsNetworkAndPopupRequests() async throws {
    let harness = WebHostHarness()
    try await harness.start()
    XCTAssertFalse(
      harness.allowsNavigation(
        to: URL(string: "https://example.com"),
        isMainFrame: true,
        navigationType: .other))
    XCTAssertFalse(
      harness.allowsNavigation(
        to: URL(string: "vivi-test://app/native.html"),
        isMainFrame: false,
        navigationType: .other))
    XCTAssertFalse(
      harness.allowsNavigation(
        to: URL(string: "vivi-test://app/native.html"),
        isMainFrame: true,
        navigationType: .linkActivated))
    XCTAssertFalse(
      harness.allowsNavigation(
        to: URL(string: "vivi-test://app/assets/native.js"),
        isMainFrame: true,
        navigationType: .other))
    XCTAssertTrue(
      harness.allowsNavigation(
        to: URL(string: "vivi-test://app/native.html#transcript"),
        isMainFrame: true,
        navigationType: .other))
    harness.stop()
  }

  func testDeliveryFailureIsReportedAndClosesRuntime() async throws {
    let harness = WebHostHarness()
    try await harness.start()
    let webView = try XCTUnwrap(harness.webView)
    _ = try await waitForBoolean(
      in: webView,
      expression: "document.body.textContent.includes('Native bridge proof')")
    _ = try await webView.evaluateJavaScript("delete window.__viviHostV1Receive")
    let bridge = try XCTUnwrap(harness.bridgeSessionID)

    await harness.receive(
      context: context(),
      body: requestBody(
        bridge: bridge,
        command: "selectSession",
        payload: ["id": "0c8f9cc7-4767-4cec-92a3-9d7759e89a01"]))

    XCTAssertNotNil(harness.lastDeliveryError)
    harness.stop()
  }

  func testCreateConversationPublishesATypeScriptValidSessionID() async throws {
    let harness = WebHostHarness()
    try await harness.start()
    let webView = try XCTUnwrap(harness.webView)
    _ = try await waitForBoolean(
      in: webView,
      expression: "document.body.textContent.includes('Native bridge proof')")
    let bridge = try XCTUnwrap(harness.bridgeSessionID)

    _ = try await webView.callAsyncJavaScript(
      """
      window.webkit.messageHandlers.viviHostV1.postMessage({
        protocol: "vivi.host",
        version: 1,
        bridgeSessionId: bridgeSessionId,
        requestId: crypto.randomUUID(),
        command: "createConversation",
        payload: { projectPath: "/test/vivi" }
      });
      """,
      arguments: ["bridgeSessionId": bridge.uuidString.lowercased()],
      in: nil,
      contentWorld: .page)

    let createdSessionRendered = try await waitForBoolean(
      in: webView,
      expression: "document.querySelectorAll('.session-row').length === 2")
    XCTAssertTrue(createdSessionRendered)
    XCTAssertNil(harness.lastBridgeError)
    XCTAssertNil(harness.lastDeliveryError)
    harness.stop()
  }

  private func waitForBoolean(
    in webView: WKWebView,
    expression: String
  ) async throws -> Bool {
    for _ in 0..<50 {
      if try await webView.evaluateJavaScript(expression) as? Bool == true {
        return true
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    return false
  }

  private func context(
    name: String = "viviHostV1",
    isMainFrame: Bool = true,
    securityHost: String = "app"
  ) -> ScriptMessageContext {
    ScriptMessageContext(
      name: name,
      isMainFrame: isMainFrame,
      securityProtocol: "vivi-test",
      securityHost: securityHost,
      securityPort: 0)
  }

  private func assertPolicyRejection(
    _ context: ScriptMessageContext,
    equals expected: ScriptMessagePolicy.Rejection,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try ScriptMessagePolicy.validate(context),
      file: file,
      line: line
    ) { error in
      XCTAssertEqual(error as? ScriptMessagePolicy.Rejection, expected, file: file, line: line)
    }
  }

  private func requestBody(
    bridge: UUID,
    command: String,
    payload: [String: Any]
  ) -> [String: Any] {
    [
      "protocol": "vivi.host",
      "version": 1,
      "bridgeSessionId": bridge.uuidString,
      "requestId": UUID().uuidString,
      "command": command,
      "payload": payload,
    ]
  }
}
