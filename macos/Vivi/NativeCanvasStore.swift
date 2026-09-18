import Combine
import Foundation

enum NativeCanvasMode {
  case disabled
  case enabled
}

enum CanvasValueError: Error {
  case invalidIdentifier
  case invalidJSON
}

private enum CanvasLimits {
  static let identifierBytes = 256
  static let keyBytes = 768
  static let textBytes = 4_096
  static let jsonBytes = 64 * 1_024
  static let declarations = 128
  static let actionsPerDeclaration = 32
  static let instances = 64
}

private func validateCanvasIdentifier(_ value: String) throws -> String {
  let count = value.utf8.count
  guard count > 0, count <= CanvasLimits.identifierBytes else {
    throw CanvasValueError.invalidIdentifier
  }
  return value
}

struct CanvasDeclarationID: Hashable {
  let extensionID: String
  let canvasID: String

  init(extensionID: String, canvasID: String) throws {
    self.extensionID = try validateCanvasIdentifier(extensionID)
    self.canvasID = try validateCanvasIdentifier(canvasID)
  }
}

struct CanvasInstanceID: Hashable {
  let encodedValue: String

  init(validating value: String) throws {
    encodedValue = try validateCanvasIdentifier(value)
  }
}

struct CanvasInstanceIDGenerator {
  private let generate: () -> String

  init(_ generate: @escaping () -> String = { UUID().uuidString.lowercased() }) {
    self.generate = generate
  }

  func next() throws -> CanvasInstanceID {
    try CanvasInstanceID(validating: generate())
  }
}

struct CanvasInstanceKey: Hashable {
  let declarationID: CanvasDeclarationID
  let instanceID: CanvasInstanceID

  init(declarationID: CanvasDeclarationID, instanceID: CanvasInstanceID) throws {
    let total =
      declarationID.extensionID.utf8.count + declarationID.canvasID.utf8.count
      + instanceID.encodedValue.utf8.count
    guard total <= CanvasLimits.keyBytes else {
      throw CanvasValueError.invalidIdentifier
    }
    self.declarationID = declarationID
    self.instanceID = instanceID
  }
}

struct CanvasOperationID: Hashable {
  let rawValue: UInt64

  init?(_ rawValue: UInt64) {
    guard rawValue != 0 else { return nil }
    self.rawValue = rawValue
  }
}

struct CanvasRendererGeneration: Hashable, Comparable {
  let rawValue: UInt64

  init?(_ rawValue: UInt64) {
    guard rawValue != 0 else { return nil }
    self.rawValue = rawValue
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

struct CanvasRendererEpoch: Hashable, Comparable {
  let rawValue: UInt64

  init?(_ rawValue: UInt64) {
    guard rawValue != 0 else { return nil }
    self.rawValue = rawValue
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

enum CanvasSchemaRole {}
enum CanvasOpenInputRole {}
enum CanvasActionInputRole {}
enum CanvasActionResultRole {}

struct CanvasJSON<Role>: Equatable {
  let data: Data

  init(jsonUTF8: String) throws {
    try self.init(data: Data(jsonUTF8.utf8))
  }

  init(data: Data) throws {
    guard !data.isEmpty, data.count <= CanvasLimits.jsonBytes,
      String(data: data, encoding: .utf8) != nil
    else {
      throw CanvasValueError.invalidJSON
    }
    do {
      _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    } catch {
      throw CanvasValueError.invalidJSON
    }
    self.data = data
  }
}

typealias CanvasSchema = CanvasJSON<CanvasSchemaRole>
typealias CanvasOpenInput = CanvasJSON<CanvasOpenInputRole>
typealias CanvasActionInput = CanvasJSON<CanvasActionInputRole>
typealias CanvasActionResult = CanvasJSON<CanvasActionResultRole>

struct CanvasActionName: Hashable {
  let rawValue: String

  init(_ rawValue: String) throws {
    self.rawValue = try validateCanvasIdentifier(rawValue)
  }
}

struct CanvasActionDeclaration: Equatable {
  let name: CanvasActionName
  let description: String
  let inputSchema: CanvasSchema?
}

struct CanvasDeclaration: Equatable {
  let id: CanvasDeclarationID
  let extensionName: String
  let displayName: String
  let description: String
  let inputSchema: CanvasSchema?
  let actions: [CanvasActionDeclaration]
}

enum CanvasCapability: Equatable {
  case unknown
  case unsupported
  case supported
}

enum CanvasDegradation: Equatable {
  case invalidSignal
  case limitExceeded
  case backpressure
  case hostFailure
}

struct CanvasOpenedRuntime: Equatable {
  let generation: CanvasRendererGeneration
  let title: String?
  let url: String?
  let status: String?
}

enum CanvasRuntime: Equatable {
  case closed
  case opening
  case opened(CanvasOpenedRuntime)
  case closing
  case unavailable
}

enum CanvasRecord: Equatable {
  case recorded(title: String?, input: CanvasOpenInput?)
  case removed
}

struct CanvasInstanceSnapshot: Equatable {
  let key: CanvasInstanceKey
  let openInput: CanvasOpenInput?
  let runtime: CanvasRuntime
  let record: CanvasRecord
  let degradation: CanvasDegradation?
}

struct CanvasSnapshot: Equatable {
  let capability: CanvasCapability
  let registryDegradation: CanvasDegradation?
  let operationDegradation: CanvasDegradation?
  let shutdownRequested: Bool
  let declarations: [CanvasDeclaration]
  let instances: [CanvasInstanceSnapshot]
}

enum CanvasOperationFailure: Error, Equatable {
  case disabled
  case unsupported
  case unavailable
  case invalidRequest
  case backpressure
  case hostFailure
  case invalidSDKResult
  case stale
  case shutdown
}

struct CanvasOpenMetadata: Equatable {
  let title: String?
  let url: String?
  let status: String?
}

enum CanvasOperationCompletion: Equatable {
  case openSucceeded(id: CanvasOperationID, metadata: CanvasOpenMetadata)
  case openFailed(id: CanvasOperationID, failure: CanvasOperationFailure)
  case closeSucceeded(id: CanvasOperationID)
  case closeFailed(id: CanvasOperationID, failure: CanvasOperationFailure)
  case actionSucceeded(id: CanvasOperationID, result: CanvasActionResult)
  case actionFailed(id: CanvasOperationID, failure: CanvasOperationFailure)

  var id: CanvasOperationID {
    switch self {
    case .openSucceeded(let id, _), .openFailed(let id, _), .closeSucceeded(let id),
      .closeFailed(let id, _), .actionSucceeded(let id, _), .actionFailed(let id, _):
      id
    }
  }

  var kind: CanvasOperationKind {
    switch self {
    case .openSucceeded, .openFailed: .open
    case .closeSucceeded, .closeFailed: .close
    case .actionSucceeded, .actionFailed: .action
    }
  }
}

enum CanvasEvent: Equatable {
  case snapshot(CanvasSnapshot)
  case completion(CanvasOperationCompletion)
}

enum CanvasOperationKind: Equatable {
  case open
  case close
  case action
}

struct CanvasRenderLease: Hashable {
  let key: CanvasInstanceKey
  let generation: CanvasRendererGeneration
  let epoch: CanvasRendererEpoch
}

enum CanvasCommand: Equatable {
  case open(key: CanvasInstanceKey, input: CanvasOpenInput?)
  case close(key: CanvasInstanceKey, generation: CanvasRendererGeneration)
  case action(
    key: CanvasInstanceKey,
    generation: CanvasRendererGeneration,
    name: CanvasActionName,
    input: CanvasActionInput?
  )

  fileprivate var kind: CanvasOperationKind {
    switch self {
    case .open: .open
    case .close: .close
    case .action: .action
    }
  }
}

enum CanvasCommandTransportResult: Equatable {
  case accepted(CanvasOperationID)
  case busy
  case stopping
  case closed
  case failed
}

protocol CanvasCommandDriving: AnyObject {
  func openCanvas(
    key: CanvasInstanceKey,
    input: CanvasOpenInput?
  ) -> CanvasCommandTransportResult
  func openCanvasSameKey(
    key: CanvasInstanceKey,
    input: CanvasOpenInput?
  ) -> CanvasCommandTransportResult
  func closeCanvas(lease: CanvasRenderLease) -> CanvasCommandTransportResult
  func invokeCanvasAction(
    name: CanvasActionName,
    on lease: CanvasRenderLease,
    input: CanvasActionInput?
  ) -> CanvasCommandTransportResult
}

enum CanvasCommandRejection: Equatable {
  case disabled
  case unsupported
  case unavailable
  case notOpen
  case actionUnavailable
  case staleGeneration
  case instanceIDCollision
  case shuttingDown
  case busy
  case transportFailure
}

enum CanvasOpenSubmission: Equatable {
  case submitted(key: CanvasInstanceKey, operationID: CanvasOperationID)
  case rejected(CanvasCommandRejection)
}

enum CanvasSubmission: Equatable {
  case submitted(CanvasOperationID)
  case rejected(CanvasCommandRejection)
}

enum CanvasHostTeardownReason: Equatable {
  case runtimeEnded
  case generationReplaced
  case instanceDisappeared
  case conversationClosing
  case conversationClosed
  case sessionResumed
  case backendShutdown
  case protocolFailure
}

enum CanvasHostDirective: Equatable {
  case teardown(CanvasRenderLease, reason: CanvasHostTeardownReason)
  case teardownAll(reason: CanvasHostTeardownReason)
}

struct CanvasOperationReceipt: Equatable {
  let command: CanvasCommand
  let completion: CanvasOperationCompletion
}

struct NativeCanvasInstance: Equatable, Identifiable {
  var id: CanvasInstanceKey { key }

  let key: CanvasInstanceKey
  let declaration: CanvasDeclaration?
  let openInput: CanvasOpenInput?
  let runtime: CanvasRuntime
  let record: CanvasRecord
  let degradation: CanvasDegradation?
}

struct NativeCanvasPresentation: Equatable {
  let capability: CanvasCapability
  let declarations: [CanvasDeclaration]
  let instances: [NativeCanvasInstance]
  let registryDegradation: CanvasDegradation?
  let operationDegradation: CanvasDegradation?
  let shutdownRequested: Bool
  let completions: [CanvasOperationReceipt]

  static let empty = NativeCanvasPresentation(
    capability: .unknown,
    declarations: [],
    instances: [],
    registryDegradation: nil,
    operationDegradation: nil,
    shutdownRequested: false,
    completions: [])
}

@MainActor
final class NativeCanvasStore: ObservableObject {
  @Published private(set) var presentation = NativeCanvasPresentation.empty

  private let driver: (any CanvasCommandDriving)?
  private let instanceIDs: CanvasInstanceIDGenerator
  private let emitHostDirective: (CanvasHostDirective) -> Void
  private var currentDeclarations: [CanvasDeclarationID: CanvasDeclaration] = [:]
  private var retainedDeclarations: [CanvasDeclarationID: CanvasDeclaration] = [:]
  private var pending: [CanvasOperationID: CanvasCommand] = [:]
  private var renderLeases: [CanvasInstanceKey: CanvasRenderLease] = [:]
  private var revokedRendererGenerations: [CanvasInstanceKey: CanvasRendererGeneration] = [:]
  private var nextRendererEpoch: UInt64 = 1
  private var acceptingCommands = true
  private var terminal = false

  init(
    driver: (any CanvasCommandDriving)?,
    instanceIDs: CanvasInstanceIDGenerator = CanvasInstanceIDGenerator(),
    emitHostDirective: @escaping (CanvasHostDirective) -> Void = { _ in }
  ) {
    self.driver = driver
    self.instanceIDs = instanceIDs
    self.emitHostDirective = emitHostDirective
  }

  func open(
    _ declarationID: CanvasDeclarationID,
    input: CanvasOpenInput?
  ) -> CanvasOpenSubmission {
    guard let rejection = commandRejection(for: declarationID) else {
      do {
        let key = try CanvasInstanceKey(
          declarationID: declarationID,
          instanceID: instanceIDs.next())
        guard !isInstanceIDReserved(key.instanceID) else {
          return .rejected(.instanceIDCollision)
        }
        return submitOpen(key: key, input: input, sameKey: false)
      } catch {
        return .rejected(.transportFailure)
      }
    }
    return .rejected(rejection)
  }

  func openSameKey(
    _ key: CanvasInstanceKey,
    input: CanvasOpenInput?
  ) -> CanvasSubmission {
    guard let rejection = commandRejection(for: key.declarationID) else {
      guard !hasInstanceIDCollision(for: key) else {
        return .rejected(.instanceIDCollision)
      }
      switch submitOpen(key: key, input: input, sameKey: true) {
      case .submitted(_, let operationID): return .submitted(operationID)
      case .rejected(let rejection): return .rejected(rejection)
      }
    }
    return .rejected(rejection)
  }

  func close(_ lease: CanvasRenderLease) -> CanvasSubmission {
    guard acceptingCommands else { return .rejected(.shuttingDown) }
    guard acceptsRendererCallback(for: lease) else {
      return .rejected(.staleGeneration)
    }
    guard let opened = currentOpenedRuntime(for: lease.key) else {
      return .rejected(.notOpen)
    }
    guard opened.generation == lease.generation else {
      return .rejected(.staleGeneration)
    }
    guard let driver else { return .rejected(.disabled) }
    let submission = remember(
      .close(key: lease.key, generation: lease.generation),
      result: driver.closeCanvas(lease: lease))
    if case .submitted = submission {
      revokedRendererGenerations[lease.key] = lease.generation
      renderLeases.removeValue(forKey: lease.key)
      emitHostDirective(.teardown(lease, reason: .runtimeEnded))
    }
    return submission
  }

  func invoke(
    _ action: CanvasActionName,
    on lease: CanvasRenderLease,
    input: CanvasActionInput?
  ) -> CanvasSubmission {
    guard acceptingCommands else { return .rejected(.shuttingDown) }
    guard acceptsRendererCallback(for: lease) else {
      return .rejected(.staleGeneration)
    }
    guard let opened = currentOpenedRuntime(for: lease.key) else {
      return .rejected(.notOpen)
    }
    guard opened.generation == lease.generation else {
      return .rejected(.staleGeneration)
    }
    guard
      let declaration = currentDeclarations[lease.key.declarationID],
      declaration.actions.contains(where: { $0.name == action })
    else {
      return .rejected(.actionUnavailable)
    }
    guard let driver else { return .rejected(.disabled) }
    return remember(
      .action(
        key: lease.key,
        generation: lease.generation,
        name: action,
        input: input),
      result: driver.invokeCanvasAction(name: action, on: lease, input: input))
  }

  func apply(_ event: CanvasEvent) {
    switch event {
    case .snapshot(let snapshot):
      apply(snapshot)
    case .completion(let completion):
      apply(completion)
    }
  }

  func resetForSuccessfulResume() {
    currentDeclarations.removeAll(keepingCapacity: true)
    retainedDeclarations.removeAll(keepingCapacity: true)
    pending.removeAll(keepingCapacity: true)
    renderLeases.removeAll(keepingCapacity: true)
    revokedRendererGenerations.removeAll(keepingCapacity: true)
    emitHostDirective(.teardownAll(reason: .sessionResumed))
    terminal = false
    acceptingCommands = true
    presentation = .empty
  }

  func shutdown(reason: CanvasHostTeardownReason) {
    guard acceptingCommands || !renderLeases.isEmpty || !pending.isEmpty else { return }
    terminal = true
    acceptingCommands = false
    pending.removeAll(keepingCapacity: true)
    renderLeases.removeAll(keepingCapacity: true)
    revokedRendererGenerations.removeAll(keepingCapacity: true)
    emitHostDirective(.teardownAll(reason: reason))
  }

  func acceptsRendererCallback(for lease: CanvasRenderLease) -> Bool {
    renderLeases[lease.key] == lease
  }

  func renderLease(for key: CanvasInstanceKey) -> CanvasRenderLease? {
    renderLeases[key]
  }

  func renewRendererLeasesForPresentation() {
    guard !terminal else { return }
    var renewed: [CanvasInstanceKey: CanvasRenderLease] = [:]
    for lease in renderLeases.values {
      guard
        let replacement = takeRenderLease(
          key: lease.key,
          generation: lease.generation)
      else {
        failCanvasProtocol()
        return
      }
      renewed[lease.key] = replacement
    }
    renderLeases = renewed
  }

  private func submitOpen(
    key: CanvasInstanceKey,
    input: CanvasOpenInput?,
    sameKey: Bool
  ) -> CanvasOpenSubmission {
    guard let driver else { return .rejected(.disabled) }
    let command = CanvasCommand.open(key: key, input: input)
    let result =
      sameKey
      ? driver.openCanvasSameKey(key: key, input: input)
      : driver.openCanvas(key: key, input: input)
    switch remember(command, result: result) {
    case .submitted(let operationID):
      return .submitted(key: key, operationID: operationID)
    case .rejected(let rejection):
      return .rejected(rejection)
    }
  }

  private func remember(
    _ command: CanvasCommand,
    result: CanvasCommandTransportResult
  ) -> CanvasSubmission {
    switch result {
    case .accepted(let operationID):
      guard pending[operationID] == nil else {
        failCanvasProtocol()
        return .rejected(.transportFailure)
      }
      pending[operationID] = command
      return .submitted(operationID)
    case .busy:
      return .rejected(.busy)
    case .stopping, .closed:
      return .rejected(.shuttingDown)
    case .failed:
      return .rejected(.transportFailure)
    }
  }

  private func commandRejection(
    for declarationID: CanvasDeclarationID
  ) -> CanvasCommandRejection? {
    guard acceptingCommands else { return .shuttingDown }
    guard driver != nil else { return .disabled }
    switch presentation.capability {
    case .unknown: return .unavailable
    case .unsupported: return .unsupported
    case .supported: break
    }
    guard currentDeclarations[declarationID] != nil else { return .unavailable }
    return nil
  }

  private func currentOpenedRuntime(for key: CanvasInstanceKey) -> CanvasOpenedRuntime? {
    guard
      let instance = presentation.instances.first(where: { $0.key == key }),
      case .opened(let opened) = instance.runtime
    else { return nil }
    return opened
  }

  private func isInstanceIDReserved(_ instanceID: CanvasInstanceID) -> Bool {
    if presentation.instances.contains(where: { $0.key.instanceID == instanceID }) {
      return true
    }
    return pending.values.contains { command in
      guard case .open(let key, _) = command else { return false }
      return key.instanceID == instanceID
    }
  }

  private func hasInstanceIDCollision(for key: CanvasInstanceKey) -> Bool {
    if presentation.instances.contains(where: {
      $0.key.instanceID == key.instanceID && $0.key != key
    }) {
      return true
    }
    return pending.values.contains { command in
      guard case .open(let pendingKey, _) = command else { return false }
      return pendingKey.instanceID == key.instanceID && pendingKey != key
    }
  }

  private func apply(_ snapshot: CanvasSnapshot) {
    guard !terminal else { return }
    let declarations = Dictionary(
      uniqueKeysWithValues: snapshot.declarations.map { ($0.id, $0) })
    let oldInstances = Dictionary(
      uniqueKeysWithValues: presentation.instances.map { ($0.key, $0) })
    var nextRetained: [CanvasDeclarationID: CanvasDeclaration] = [:]
    let instances = snapshot.instances.map { instance in
      let declaration =
        declarations[instance.key.declarationID]
        ?? oldInstances[instance.key]?.declaration
        ?? retainedDeclarations[instance.key.declarationID]
      if let declaration {
        nextRetained[declaration.id] = declaration
      }
      return NativeCanvasInstance(
        key: instance.key,
        declaration: declaration,
        openInput: instance.openInput,
        runtime: instance.runtime,
        record: instance.record,
        degradation: instance.degradation)
    }
    var nextLeases: [CanvasInstanceKey: CanvasRenderLease] = [:]
    for instance in instances {
      guard case .opened(let opened) = instance.runtime else { continue }
      if revokedRendererGenerations[instance.key] == opened.generation {
        continue
      }
      if let existing = renderLeases[instance.key],
        existing.generation == opened.generation
      {
        nextLeases[instance.key] = existing
        continue
      }
      guard let lease = takeRenderLease(key: instance.key, generation: opened.generation) else {
        failCanvasProtocol()
        return
      }
      nextLeases[instance.key] = lease
    }
    revokedRendererGenerations = revokedRendererGenerations.filter { key, generation in
      instances.contains { instance in
        guard instance.key == key, case .opened(let opened) = instance.runtime else {
          return false
        }
        return opened.generation == generation
      }
    }
    if !snapshot.shutdownRequested {
      for (key, lease) in renderLeases where nextLeases[key] != lease {
        let reason: CanvasHostTeardownReason
        if nextLeases[key] != nil {
          reason = .generationReplaced
        } else if oldInstances[key] != nil && instances.contains(where: { $0.key == key }) {
          reason = .runtimeEnded
        } else {
          reason = .instanceDisappeared
        }
        emitHostDirective(.teardown(lease, reason: reason))
      }
    }
    currentDeclarations = declarations
    retainedDeclarations = nextRetained
    renderLeases = snapshot.shutdownRequested ? [:] : nextLeases
    presentation = NativeCanvasPresentation(
      capability: snapshot.capability,
      declarations: snapshot.declarations,
      instances: instances,
      registryDegradation: snapshot.registryDegradation,
      operationDegradation: snapshot.operationDegradation,
      shutdownRequested: snapshot.shutdownRequested,
      completions: presentation.completions)
    if snapshot.shutdownRequested {
      terminal = true
      acceptingCommands = false
      pending.removeAll(keepingCapacity: true)
      emitHostDirective(.teardownAll(reason: .backendShutdown))
    }
  }

  private func apply(_ completion: CanvasOperationCompletion) {
    guard !terminal else { return }
    guard let command = pending.removeValue(forKey: completion.id),
      command.kind == completion.kind
    else {
      failCanvasProtocol()
      return
    }
    var completions = presentation.completions
    completions.append(CanvasOperationReceipt(command: command, completion: completion))
    if completions.count > 128 {
      completions.removeFirst(completions.count - 128)
    }
    presentation = NativeCanvasPresentation(
      capability: presentation.capability,
      declarations: presentation.declarations,
      instances: presentation.instances,
      registryDegradation: presentation.registryDegradation,
      operationDegradation: presentation.operationDegradation,
      shutdownRequested: presentation.shutdownRequested,
      completions: completions)
  }

  private func failCanvasProtocol() {
    terminal = true
    acceptingCommands = false
    pending.removeAll(keepingCapacity: true)
    renderLeases.removeAll(keepingCapacity: true)
    revokedRendererGenerations.removeAll(keepingCapacity: true)
    emitHostDirective(.teardownAll(reason: .protocolFailure))
  }

  private func takeRenderLease(
    key: CanvasInstanceKey,
    generation: CanvasRendererGeneration
  ) -> CanvasRenderLease? {
    guard let epoch = CanvasRendererEpoch(nextRendererEpoch) else { return nil }
    let (next, overflow) = nextRendererEpoch.addingReportingOverflow(1)
    guard !overflow, next != 0 else { return nil }
    nextRendererEpoch = next
    return CanvasRenderLease(key: key, generation: generation, epoch: epoch)
  }
}
