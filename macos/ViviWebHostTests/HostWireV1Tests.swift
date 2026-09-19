import XCTest

final class HostWireV1Tests: XCTestCase {
  func testDecodesEveryNamedV1Command() throws {
    let bridge = UUID()
    let request = UUID()
    let session = UUID()
    let submission = UUID()
    let commands: [(String, [String: Any], HostWireV1.Command)] = [
      ("connect", [:], .connect),
      ("selectSession", ["id": session.uuidString], .selectSession(id: session)),
      (
        "createConversation",
        ["projectPath": "/test/vivi"],
        .createConversation(projectPath: "/test/vivi")
      ),
      (
        "sendMessage",
        [
          "sessionId": session.uuidString,
          "submissionId": submission.uuidString,
          "text": "hello",
        ],
        .sendMessage(sessionID: session, submissionID: submission, text: "hello")
      ),
      ("disconnect", [:], .disconnect),
    ]

    for (name, payload, expected) in commands {
      let decoded = try HostWireV1.decodeRequest([
        "protocol": "vivi.host",
        "version": 1,
        "bridgeSessionId": bridge.uuidString,
        "requestId": request.uuidString,
        "command": name,
        "payload": payload,
      ])
      XCTAssertEqual(decoded.command, expected)
    }
  }

  func testFailsClosedForUnknownFieldsUnsafeNumbersAndMalformedValues() {
    let valid: [String: Any] = [
      "protocol": "vivi.host",
      "version": 1,
      "bridgeSessionId": UUID().uuidString,
      "requestId": UUID().uuidString,
      "command": "connect",
      "payload": [:],
    ]
    assertInvalid(valid.merging(["extra": true]) { _, new in new }, path: "request.extra")
    assertInvalid(
      valid.merging(["protocol": "other.host"]) { _, new in new },
      code: .protocolMismatch)
    assertInvalid(
      valid.merging(["version": 2]) { _, new in new },
      code: .protocolMismatch)
    assertInvalid(valid.merging(["version": 9_007_199_254_740_992]) { _, new in new })
    assertInvalid(valid.merging(["requestId": "not-a-uuid"]) { _, new in new })
    assertInvalid(valid.merging(["command": "runAnything"]) { _, new in new })
    assertInvalid(
      valid.merging([
        "command": "createConversation",
        "payload": ["projectPath": "relative"],
      ]) { _, new in new })
    for path in ["/test/../vivi", "/test/./vivi", "/test//vivi", "/test/vivi/", "/bad\0path"] {
      assertInvalid(
        valid.merging([
          "command": "createConversation",
          "payload": ["projectPath": path],
        ]) { _, new in new })
    }
    assertInvalid(
      valid.merging([
        "command": "sendMessage",
        "payload": [
          "sessionId": UUID().uuidString,
          "submissionId": UUID().uuidString,
          "text": String(repeating: "💥", count: 250_001),
        ],
      ]) { _, new in new })
    assertInvalid(
      valid.merging([
        "command": "sendMessage",
        "payload": [
          "sessionId": UUID().uuidString,
          "submissionId": UUID().uuidString,
          "text": "hello",
          "spans": [],
        ],
      ]) { _, new in new },
      path: "request.payload.spans")
  }

  private func assertInvalid(
    _ body: [String: Any],
    code: HostWireV1.ErrorCode? = nil,
    path: String? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(try HostWireV1.decodeRequest(body), file: file, line: line) { error in
      guard let error = error as? HostWireV1.ValidationError else {
        return XCTFail("Unexpected error \(error)", file: file, line: line)
      }
      if let code {
        XCTAssertEqual(error.code, code, file: file, line: line)
      }
      if let path {
        XCTAssertEqual(error.path, path, file: file, line: line)
      }
    }
  }
}
