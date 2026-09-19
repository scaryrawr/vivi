import CoreFoundation
import Foundation

enum HostWireV1 {
  static let protocolName = "vivi.host"
  static let version = 1
  static let maximumTextLength = 1_000_000

  enum Command: Equatable {
    case connect
    case selectSession(id: UUID)
    case createConversation(projectPath: String)
    case sendMessage(sessionID: UUID, submissionID: UUID, text: String)
    case disconnect
  }

  struct Request: Equatable {
    let bridgeSessionID: UUID
    let requestID: UUID
    let command: Command
  }

  enum ErrorCode: String {
    case invalidMessage = "invalid_message"
    case protocolMismatch = "protocol_mismatch"
    case staleSession = "stale_session"
    case duplicateRequest = "duplicate_request"
    case handshakeRequired = "handshake_required"
    case alreadyConnected = "already_connected"
    case disconnected = "disconnected"
    case capacityExceeded = "capacity_exceeded"
  }

  struct ValidationError: Swift.Error, Equatable, CustomStringConvertible {
    let code: ErrorCode
    let path: String
    let reason: String

    var description: String {
      "\(code.rawValue) at \(path): \(reason)"
    }
  }

  static func decodeRequest(_ body: Any) throws -> Request {
    let value = try object(body, path: "request")
    try exactKeys(
      value,
      allowed: ["protocol", "version", "bridgeSessionId", "requestId", "command", "payload"],
      path: "request")
    guard try string(value["protocol"], path: "request.protocol") == protocolName,
      try integer(value["version"], path: "request.version") == version
    else {
      throw ValidationError(
        code: .protocolMismatch,
        path: "request",
        reason: "protocol must be \(protocolName) version \(version)")
    }
    let bridgeSessionID = try uuid(value["bridgeSessionId"], path: "request.bridgeSessionId")
    let requestID = try uuid(value["requestId"], path: "request.requestId")
    let payload = try object(value["payload"], path: "request.payload")
    let commandName = try string(value["command"], path: "request.command")
    let command: Command
    switch commandName {
    case "connect":
      try exactKeys(payload, allowed: [], path: "request.payload")
      command = .connect
    case "selectSession":
      try exactKeys(payload, allowed: ["id"], path: "request.payload")
      command = .selectSession(id: try uuid(payload["id"], path: "request.payload.id"))
    case "createConversation":
      try exactKeys(payload, allowed: ["projectPath"], path: "request.payload")
      command = .createConversation(
        projectPath: try absolutePath(payload["projectPath"], path: "request.payload.projectPath"))
    case "sendMessage":
      try exactKeys(
        payload,
        allowed: ["sessionId", "submissionId", "text"],
        path: "request.payload")
      command = .sendMessage(
        sessionID: try uuid(payload["sessionId"], path: "request.payload.sessionId"),
        submissionID: try uuid(payload["submissionId"], path: "request.payload.submissionId"),
        text: try boundedString(
          payload["text"],
          path: "request.payload.text",
          maximum: maximumTextLength))
    case "disconnect":
      try exactKeys(payload, allowed: [], path: "request.payload")
      command = .disconnect
    default:
      throw ValidationError(
        code: .invalidMessage,
        path: "request.command",
        reason: "unknown command")
    }
    return Request(
      bridgeSessionID: bridgeSessionID,
      requestID: requestID,
      command: command)
  }

  static func response(
    bridgeSessionID: UUID,
    requestID: UUID,
    result: [String: Any]
  ) -> [String: Any] {
    envelope(bridgeSessionID: bridgeSessionID, kind: "response").merging([
      "requestId": requestID.uuidString.lowercased(),
      "result": result,
    ]) { _, new in new }
  }

  static func snapshot(
    bridgeSessionID: UUID,
    value: [String: Any]
  ) -> [String: Any] {
    envelope(bridgeSessionID: bridgeSessionID, kind: "snapshot").merging([
      "snapshot": value
    ]) { _, new in new }
  }

  static func connection(
    bridgeSessionID: UUID,
    kind: String
  ) -> [String: Any] {
    envelope(bridgeSessionID: bridgeSessionID, kind: "connection").merging([
      "connectionState": ["kind": kind]
    ]) { _, new in new }
  }

  static func failure(
    bridgeSessionID: UUID,
    error: ValidationError
  ) -> [String: Any] {
    envelope(bridgeSessionID: bridgeSessionID, kind: "failure").merging([
      "error": [
        "code": error.code.rawValue,
        "message": error.description,
      ]
    ]) { _, new in new }
  }

  private static func envelope(
    bridgeSessionID: UUID,
    kind: String
  ) -> [String: Any] {
    [
      "protocol": protocolName,
      "version": version,
      "bridgeSessionId": bridgeSessionID.uuidString.lowercased(),
      "kind": kind,
    ]
  }

  private static func object(_ value: Any?, path: String) throws -> [String: Any] {
    guard let value = value as? [String: Any] else {
      throw ValidationError(code: .invalidMessage, path: path, reason: "must be an object")
    }
    return value
  }

  private static func exactKeys(
    _ value: [String: Any],
    allowed: Set<String>,
    path: String
  ) throws {
    if let unknown = value.keys.first(where: { !allowed.contains($0) }) {
      throw ValidationError(
        code: .invalidMessage,
        path: "\(path).\(unknown)",
        reason: "unknown field")
    }
  }

  private static func string(_ value: Any?, path: String) throws -> String {
    guard let value = value as? String else {
      throw ValidationError(code: .invalidMessage, path: path, reason: "must be a string")
    }
    return value
  }

  private static func boundedString(
    _ value: Any?,
    path: String,
    maximum: Int
  ) throws -> String {
    let value = try string(value, path: path)
    guard value.utf8.count <= maximum else {
      throw ValidationError(
        code: .invalidMessage,
        path: path,
        reason: "must contain at most \(maximum) UTF-8 bytes")
    }
    return value
  }

  private static func absolutePath(_ value: Any?, path: String) throws -> String {
    let value = try boundedString(value, path: path, maximum: 32_768)
    guard value.first == "/", !value.utf8.contains(0) else {
      throw ValidationError(
        code: .invalidMessage,
        path: path,
        reason: "must be an absolute path")
    }
    if value != "/" {
      let components = value.split(separator: "/", omittingEmptySubsequences: false)
      guard components.first == "",
        components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
      else {
        throw ValidationError(
          code: .invalidMessage,
          path: path,
          reason: "must be a canonical absolute path without dot or empty components")
      }
    }
    return value
  }

  private static func uuid(_ value: Any?, path: String) throws -> UUID {
    let value = try string(value, path: path)
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    let pattern =
      "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"
    guard value.range(of: pattern, options: .regularExpression) != nil,
      range.length == 36,
      let uuid = UUID(uuidString: value)
    else {
      throw ValidationError(code: .invalidMessage, path: path, reason: "must be a UUID")
    }
    return uuid
  }

  private static func integer(_ value: Any?, path: String) throws -> Int {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue.rounded() == number.doubleValue,
      number.doubleValue <= Double(9_007_199_254_740_991),
      number.doubleValue >= Double(Int.min)
    else {
      throw ValidationError(
        code: .invalidMessage,
        path: path,
        reason: "must be a JavaScript-safe integer")
    }
    return number.intValue
  }
}
