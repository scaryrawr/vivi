import XCTest

@MainActor
final class NativeHostRuntimeTests: XCTestCase {
  func testSnapshotIsCompleteStableAndRevisionChangesOnlyForSemanticMutation() {
    let adapter = DeterministicWebHostAdapter()
    let first = adapter.snapshot
    XCTAssertEqual(first["schemaVersion"] as? Int, 1)
    XCTAssertEqual(first["revision"] as? Int, 1)

    let selected = UUID(uuidString: "0c8f9cc7-4767-4cec-92a3-9d7759e89a01")!
    XCTAssertEqual(adapter.selectSession(selected), .accepted)
    XCTAssertEqual(adapter.snapshot["revision"] as? Int, 1)

    XCTAssertEqual(adapter.createConversation(projectPath: "/test/vivi"), .accepted)
    let second = adapter.snapshot
    XCTAssertEqual(second["revision"] as? Int, 2)
    XCTAssertEqual((second["projects"] as? [[String: Any]])?.count, 1)
    XCTAssertNotNil(second["selectedSession"])
    XCTAssertNotNil(second["applicationError"])
  }

  func testDuplicateSubmissionIsAcceptedWithoutPublishingAnotherRevision() {
    let adapter = DeterministicWebHostAdapter()
    let session = UUID(uuidString: "0c8f9cc7-4767-4cec-92a3-9d7759e89a01")!
    let submission = UUID()

    XCTAssertEqual(
      adapter.sendMessage(sessionID: session, submissionID: submission, text: "hello"),
      .accepted)
    let revision = adapter.snapshot["revision"] as? Int
    XCTAssertEqual(
      adapter.sendMessage(sessionID: session, submissionID: submission, text: "hello"),
      .accepted)
    XCTAssertEqual(adapter.snapshot["revision"] as? Int, revision)
  }

  func testSubmissionLedgerFailsClosedAtCapacityWithoutPermittingReplay() {
    let adapter = DeterministicWebHostAdapter(maximumAcceptedSubmissions: 1)
    let session = UUID(uuidString: "0c8f9cc7-4767-4cec-92a3-9d7759e89a01")!
    let first = UUID()
    XCTAssertEqual(
      adapter.sendMessage(sessionID: session, submissionID: first, text: "one"),
      .accepted)
    let revision = adapter.snapshot["revision"] as? Int
    XCTAssertEqual(
      adapter.sendMessage(sessionID: session, submissionID: UUID(), text: "two"),
      .rejected(reason: .failed, message: "The accepted submission ledger is full."))
    XCTAssertEqual(adapter.snapshot["revision"] as? Int, revision)
    XCTAssertEqual(
      adapter.sendMessage(sessionID: session, submissionID: first, text: "one"),
      .accepted)
    XCTAssertEqual(adapter.snapshot["revision"] as? Int, revision)
  }

  func testValidHandshakePublishesSnapshotConnectionAndResponse() {
    let runtime = NativeHostRuntime(adapter: DeterministicWebHostAdapter())
    let request = request(command: .connect)
    let messages = runtime.handle(request)
    XCTAssertEqual(messages.map { $0["kind"] as? String }, ["snapshot", "connection", "response"])
  }

  func testRejectsCommandBeforeHandshakeAndMismatchedOrRepeatedConnect() {
    let runtime = NativeHostRuntime(adapter: DeterministicWebHostAdapter())
    let bridge = UUID()
    XCTAssertEqual(
      errorCode(runtime.handle(request(bridge: bridge, command: .disconnect))), "handshake_required"
    )

    XCTAssertEqual(runtime.handle(request(bridge: bridge, command: .connect)).count, 3)
    XCTAssertEqual(
      errorCode(runtime.handle(request(bridge: bridge, command: .connect))), "already_connected")
    XCTAssertEqual(
      errorCode(runtime.handle(request(bridge: UUID(), command: .disconnect))),
      "stale_session")
  }

  func testDisconnectClosesSessionAndRejectsLaterCommands() {
    let runtime = NativeHostRuntime(adapter: DeterministicWebHostAdapter())
    let bridge = UUID()
    _ = runtime.handle(request(bridge: bridge, command: .connect))
    let disconnect = runtime.handle(request(bridge: bridge, command: .disconnect))
    XCTAssertTrue(disconnect.isEmpty)
    XCTAssertEqual(
      errorCode(runtime.handle(request(bridge: bridge, command: .disconnect))),
      "disconnected")
  }

  func testFreshConnectAfterDisconnectPreservesDomainState() {
    let adapter = DeterministicWebHostAdapter()
    let runtime = NativeHostRuntime(adapter: adapter)
    let firstBridge = UUID()
    _ = runtime.handle(request(bridge: firstBridge, command: .connect))
    XCTAssertEqual(adapter.createConversation(projectPath: "/test/vivi"), .accepted)
    let disconnectRequest = request(bridge: firstBridge, command: .disconnect)
    _ = runtime.handle(disconnectRequest)
    XCTAssertEqual(errorCode(runtime.handle(disconnectRequest)), "duplicate_request")

    let secondBridge = UUID()
    let reconnect = runtime.handle(request(bridge: secondBridge, command: .connect))
    XCTAssertEqual(
      reconnect.map { $0["kind"] as? String },
      ["snapshot", "connection", "response"])
    let snapshot = reconnect.first?["snapshot"] as? [String: Any]
    XCTAssertEqual(snapshot?["revision"] as? Int, 2)
  }

  func testDeliveryFailureClosesConnectedSession() {
    let runtime = NativeHostRuntime(adapter: DeterministicWebHostAdapter())
    let bridge = UUID()
    _ = runtime.handle(request(bridge: bridge, command: .connect))
    runtime.deliveryFailed()
    XCTAssertEqual(
      errorCode(runtime.handle(request(bridge: bridge, command: .disconnect))),
      "disconnected")
  }

  func testRuntimeRejectsDuplicateRequestIDs() {
    let runtime = NativeHostRuntime(adapter: DeterministicWebHostAdapter())
    let request = request(command: .connect)

    XCTAssertEqual(runtime.handle(request).count, 3)
    let duplicate = runtime.handle(request)
    XCTAssertEqual(duplicate.count, 1)
    XCTAssertEqual(
      (duplicate[0]["error"] as? [String: Any])?["code"] as? String,
      "duplicate_request")
  }

  private func request(
    bridge: UUID = UUID(),
    requestID: UUID = UUID(),
    command: HostWireV1.Command
  ) -> HostWireV1.Request {
    HostWireV1.Request(
      bridgeSessionID: bridge,
      requestID: requestID,
      command: command)
  }

  private func errorCode(_ messages: [[String: Any]]) -> String? {
    (messages.first?["error"] as? [String: Any])?["code"] as? String
  }
}
