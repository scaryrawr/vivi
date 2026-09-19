import Foundation

@MainActor
protocol WebHostDomainAdapter: AnyObject {
  var snapshot: [String: Any] { get }
  func selectSession(_ id: UUID) -> HostCommandResult
  func createConversation(projectPath: String) -> HostCommandResult
  func sendMessage(sessionID: UUID, submissionID: UUID, text: String) -> HostCommandResult
}

enum HostCommandResult: Equatable {
  case accepted
  case rejected(reason: RejectionReason, message: String)

  enum RejectionReason: String {
    case invalid
    case busy
    case stopping
    case closed
    case failed
  }

  var wireValue: [String: Any] {
    switch self {
    case .accepted:
      return ["kind": "accepted"]
    case .rejected(let reason, let message):
      return [
        "kind": "rejected",
        "reason": reason.rawValue,
        "message": message,
      ]
    }
  }
}

@MainActor
final class NativeHostRuntime {
  private enum State {
    case awaitingConnect
    case connected(UUID)
    case disconnected(UUID)
  }

  private let adapter: any WebHostDomainAdapter
  private var requestIDSet: Set<UUID> = []
  private let maximumRememberedRequestIDs = 512
  private var state = State.awaitingConnect

  init(adapter: any WebHostDomainAdapter) {
    self.adapter = adapter
  }

  func handle(_ request: HostWireV1.Request) -> [[String: Any]] {
    if case .disconnected = state, request.command == .connect {
      requestIDSet.removeAll(keepingCapacity: true)
      state = .awaitingConnect
    }
    if requestIDSet.contains(request.requestID) {
      let error = HostWireV1.ValidationError(
        code: .duplicateRequest,
        path: "request.requestId",
        reason: "request ID was already handled")
      return [HostWireV1.failure(bridgeSessionID: request.bridgeSessionID, error: error)]
    }
    if let lifecycleError = validateLifecycle(request) {
      return [HostWireV1.failure(bridgeSessionID: request.bridgeSessionID, error: lifecycleError)]
    }
    guard requestIDSet.count < maximumRememberedRequestIDs else {
      let error = HostWireV1.ValidationError(
        code: .capacityExceeded,
        path: "request.requestId",
        reason: "request ledger is full")
      return [HostWireV1.failure(bridgeSessionID: request.bridgeSessionID, error: error)]
    }
    _ = requestIDSet.insert(request.requestID)

    switch request.command {
    case .connect:
      state = .connected(request.bridgeSessionID)
      return [
        HostWireV1.snapshot(
          bridgeSessionID: request.bridgeSessionID,
          value: adapter.snapshot),
        HostWireV1.connection(
          bridgeSessionID: request.bridgeSessionID,
          kind: "connected"),
        HostWireV1.response(
          bridgeSessionID: request.bridgeSessionID,
          requestID: request.requestID,
          result: HostCommandResult.accepted.wireValue),
      ]
    case .selectSession(let id):
      return commandMessages(
        request: request,
        result: adapter.selectSession(id))
    case .createConversation(let projectPath):
      return commandMessages(
        request: request,
        result: adapter.createConversation(projectPath: projectPath))
    case .sendMessage(let sessionID, let submissionID, let text):
      return commandMessages(
        request: request,
        result: adapter.sendMessage(
          sessionID: sessionID,
          submissionID: submissionID,
          text: text))
    case .disconnect:
      state = .disconnected(request.bridgeSessionID)
      return []
    }

  }

  func deliveryFailed() {
    if case .connected(let bridgeSessionID) = state {
      state = .disconnected(bridgeSessionID)
    }
  }

  private func commandMessages(
    request: HostWireV1.Request,
    result: HostCommandResult
  ) -> [[String: Any]] {
    var messages: [[String: Any]] = []
    if result == .accepted {
      messages.append(
        HostWireV1.snapshot(
          bridgeSessionID: request.bridgeSessionID,
          value: adapter.snapshot))
    }
    messages.append(
      HostWireV1.response(
        bridgeSessionID: request.bridgeSessionID,
        requestID: request.requestID,
        result: result.wireValue))
    return messages
  }

  private func validateLifecycle(
    _ request: HostWireV1.Request
  ) -> HostWireV1.ValidationError? {
    switch state {
    case .awaitingConnect:
      guard request.command == .connect else {
        return HostWireV1.ValidationError(
          code: .handshakeRequired,
          path: "request.command",
          reason: "connect must be the first command")
      }
    case .connected(let bridgeSessionID):
      guard bridgeSessionID == request.bridgeSessionID else {
        return HostWireV1.ValidationError(
          code: .staleSession,
          path: "request.bridgeSessionId",
          reason: "bridge session does not match the connected session")
      }
      if request.command == .connect {
        return HostWireV1.ValidationError(
          code: .alreadyConnected,
          path: "request.command",
          reason: "connect may only establish a session once")
      }
    case .disconnected(let bridgeSessionID):
      guard bridgeSessionID == request.bridgeSessionID else {
        return HostWireV1.ValidationError(
          code: .staleSession,
          path: "request.bridgeSessionId",
          reason: "bridge session does not match the disconnected session")
      }
      return HostWireV1.ValidationError(
        code: .disconnected,
        path: "request.command",
        reason: "bridge session is disconnected")
    }
    return nil
  }
}

@MainActor
final class DeterministicWebHostAdapter: WebHostDomainAdapter {
  private struct Session {
    let id: UUID
    let path: String
    var title: String
    var transcript: [[String: Any]]
  }

  private let projectPath = "/test/vivi"
  private var sessions: [Session]
  private var selectedID: UUID?
  private var revision = 1
  private var nextSessionSuffix = 2
  private var acceptedSubmissions: Set<UUID> = []
  private let maximumAcceptedSubmissions: Int

  init(maximumAcceptedSubmissions: Int = 256) {
    self.maximumAcceptedSubmissions = maximumAcceptedSubmissions
    let id = UUID(uuidString: "0c8f9cc7-4767-4cec-92a3-9d7759e89a01")!
    sessions = [
      Session(
        id: id,
        path: projectPath,
        title: "Native bridge proof",
        transcript: [
          [
            "id": "status-1",
            "kind": "status",
            "text": "Loaded from the deterministic native test host.",
          ]
        ])
    ]
    selectedID = id
  }

  var snapshot: [String: Any] {
    let selectedSession: Any = selectedSessionSnapshot() ?? NSNull()
    return [
      "schemaVersion": 1,
      "revision": revision,
      "projects": [
        [
          "path": projectPath,
          "displayName": "vivi",
          "sessions": sessions.map { session in
            [
              "id": session.id.uuidString.lowercased(),
              "projectPath": session.path,
              "title": session.title,
              "lifecycle": ["kind": "idle"],
            ]
          },
        ]
      ],
      "selectedSession": selectedSession,
      "applicationError": NSNull(),
    ]
  }

  func selectSession(_ id: UUID) -> HostCommandResult {
    guard sessions.contains(where: { $0.id == id }) else {
      return .rejected(reason: .invalid, message: "That conversation is no longer available.")
    }
    guard selectedID != id else { return .accepted }
    selectedID = id
    revision += 1
    return .accepted
  }

  func createConversation(projectPath: String) -> HostCommandResult {
    guard projectPath == self.projectPath else {
      return .rejected(reason: .invalid, message: "That project is no longer available.")
    }
    let suffix = String(format: "%012d", nextSessionSuffix)
    nextSessionSuffix += 1
    let id = UUID(uuidString: "00000000-0000-4000-8000-\(suffix)")!
    sessions.append(Session(id: id, path: projectPath, title: "", transcript: []))
    selectedID = id
    revision += 1
    return .accepted
  }

  func sendMessage(
    sessionID: UUID,
    submissionID: UUID,
    text: String
  ) -> HostCommandResult {
    if acceptedSubmissions.contains(submissionID) {
      return .accepted
    }
    guard acceptedSubmissions.count < maximumAcceptedSubmissions else {
      return .rejected(
        reason: .failed,
        message: "The accepted submission ledger is full.")
    }
    guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
      selectedID == sessionID
    else {
      return .rejected(reason: .invalid, message: "Select the conversation before sending.")
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .rejected(reason: .invalid, message: "Enter a message first.")
    }

    acceptedSubmissions.insert(submissionID)
    let suffix = revision + 1
    sessions[index].transcript.append(contentsOf: [
      [
        "id": "user-\(suffix)",
        "kind": "user",
        "text": text,
      ],
      [
        "id": "assistant-\(suffix)",
        "kind": "assistant",
        "markdown": "The test-only native host accepted the typed V1 command.",
        "streaming": false,
      ],
    ])
    revision += 1
    return .accepted
  }

  private func selectedSessionSnapshot() -> [String: Any]? {
    guard let selectedID,
      let session = sessions.first(where: { $0.id == selectedID })
    else { return nil }
    return [
      "id": session.id.uuidString.lowercased(),
      "activeWorkspace": session.path,
      "transcript": session.transcript,
      "error": NSNull(),
    ]
  }

}
