import Combine
import Foundation
import ViviBackend

enum ChatLifecycle: Equatable {
  case starting
  case idle
  case responding
  case closing
  case closed
}

enum ReasoningEffort: Int32, CaseIterable, Hashable, Identifiable {
  case off = 0
  case low = 1
  case medium = 2
  case high = 3
  case xhigh = 4
  case max = 5

  var id: Int32 { rawValue }

  var label: String {
    switch self {
    case .off: "Off"
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    case .xhigh: "Extra high"
    case .max: "Maximum"
    }
  }
}

struct ModelSelection: Equatable, Hashable {
  let modelID: String
  let reasoning: ReasoningEffort
}

struct ModelInfo: Equatable, Identifiable {
  let id: String
  let displayName: String
  let maxContextWindowTokens: UInt64
  let maxOutputTokens: UInt64
  let supportsVision: Bool
  let reasoning: [ReasoningEffort]
  let advertisedDefaultReasoning: ReasoningEffort?

  var detail: String {
    var values: [String] = []
    if maxContextWindowTokens > 0 {
      values.append("\(maxContextWindowTokens.formatted()) context")
    }
    if maxOutputTokens > 0 {
      values.append("\(maxOutputTokens.formatted()) output")
    }
    if supportsVision {
      values.append("vision")
    }
    return values.joined(separator: " · ")
  }
}

struct ModelCatalog: Equatable {
  let selected: ModelSelection
  let models: [ModelInfo]
}

enum ModelSwitchOutcome: Equatable {
  case unchanged(model: ModelInfo, selection: ModelSelection)
  case defaultUpdated(model: ModelInfo, selection: ModelSelection)
  case switched(
    model: ModelInfo,
    selection: ModelSelection,
    historyReset: Bool,
    defaultSaved: Bool,
    cleanupFailed: Bool)
  case failed(String)

  var confirmedSelection: ModelSelection? {
    switch self {
    case .unchanged(_, let selection), .defaultUpdated(_, let selection),
      .switched(_, let selection, _, _, _):
      selection
    case .failed:
      nil
    }
  }
}

enum ModelControlState: Equatable {
  case loading
  case ready
  case refreshing
  case switching
}

enum ChatItem: Identifiable, Equatable {
  case user(id: UUID, text: String)
  case assistant(id: UUID, text: String)
  case reasoning(id: UUID, text: String)
  case status(id: UUID, text: String)
  case failure(id: UUID, text: String)

  var id: UUID {
    switch self {
    case .user(let id, _), .assistant(let id, _), .reasoning(let id, _),
      .status(let id, _), .failure(let id, _):
      id
    }
  }

  var text: String {
    switch self {
    case .user(_, let text), .assistant(_, let text), .reasoning(_, let text),
      .status(_, let text), .failure(_, let text):
      text
    }
  }
}

enum ChatEvent: Equatable {
  case ready
  case status(String)
  case sessionTitle(String)
  case assistantStarted
  case reasoningDelta(String)
  case reasoningComplete(String)
  case assistantDelta(String)
  case assistantComplete(String)
  case modelCatalog(ModelCatalog)
  case modelCatalogFailure(String)
  case modelSwitch(ModelSwitchOutcome)
  case idle
  case failure(String)
  case closed
}

enum ConversationOperationResult: Equatable {
  case accepted
  case busy
  case stopping
  case closed
  case failed
}

protocol ViviConversationDriving: AnyObject {
  func start(receive: @escaping @MainActor (ChatEvent) -> Void) -> ConversationOperationResult
  func submit(_ prompt: String) -> ConversationOperationResult
  func refreshModels() -> ConversationOperationResult
  func switchModel(_ selection: ModelSelection) -> ConversationOperationResult
  func close(completion: @escaping @MainActor () -> Void)
}

@MainActor
final class NativeChatStore: ObservableObject {
  @Published private(set) var lifecycle: ChatLifecycle = .starting
  @Published private(set) var transcript: [ChatItem] = []
  @Published private(set) var sessionTitle: String
  @Published private(set) var modelState: ModelControlState = .loading
  @Published private(set) var catalog: ModelCatalog?
  @Published private(set) var confirmedSelection: ModelSelection?
  @Published var draft = ""

  let workspace: String
  private var activeAssistant: UUID?
  private var activeReasoning: UUID?
  private let driver: ViviConversationDriving
  private var closeCompletions: [@MainActor () -> Void] = []

  init(workspace: String, driver: ViviConversationDriving) {
    self.workspace = workspace
    sessionTitle = URL(fileURLWithPath: workspace).lastPathComponent
    self.driver = driver
    let started = driver.start { [weak self] event in
      self?.reduce(event)
    }
    if started != .accepted {
      transcript.append(.failure(id: UUID(), text: message(for: started, action: "start chat")))
      lifecycle = .closed
    }
  }

  var isBusy: Bool {
    lifecycle == .starting || lifecycle == .responding || lifecycle == .closing
  }

  var selectedModelID: String? {
    confirmedSelection?.modelID
  }

  var selectedReasoning: ReasoningEffort? {
    confirmedSelection?.reasoning
  }

  var modelChoices: [ModelInfo] {
    guard let catalog else { return [] }
    guard let selection = confirmedSelection,
      !catalog.models.contains(where: { $0.id == selection.modelID })
    else { return catalog.models }
    return [
      ModelInfo(
        id: selection.modelID,
        displayName: selection.modelID,
        maxContextWindowTokens: 0,
        maxOutputTokens: 0,
        supportsVision: false,
        reasoning: [selection.reasoning],
        advertisedDefaultReasoning: nil)
    ] + catalog.models
  }

  var reasoningChoices: [ReasoningEffort] {
    guard let selection = confirmedSelection,
      let model = modelChoices.first(where: { $0.id == selection.modelID })
    else { return [] }
    return model.reasoning
  }

  func submit() {
    let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty, lifecycle == .idle else { return }
    let result = driver.submit(prompt)
    guard result == .accepted else {
      transcript.append(.status(id: UUID(), text: message(for: result, action: "send message")))
      return
    }
    transcript.append(.user(id: UUID(), text: prompt))
    draft = ""
    lifecycle = .responding
  }

  func refreshModels() {
    guard modelState == .ready else { return }
    let result = driver.refreshModels()
    if result == .accepted {
      modelState = .refreshing
    } else {
      transcript.append(.failure(id: UUID(), text: message(for: result, action: "refresh models")))
    }
  }

  func selectModel(_ modelID: String) {
    guard let catalog, let model = catalog.models.first(where: { $0.id == modelID }) else {
      return
    }
    let reasoning =
      model.reasoning.contains(confirmedSelection?.reasoning ?? .off)
      ? confirmedSelection?.reasoning ?? .off
      : model.advertisedDefaultReasoning ?? model.reasoning.first ?? .off
    switchModel(ModelSelection(modelID: modelID, reasoning: reasoning))
  }

  func selectReasoning(_ reasoning: ReasoningEffort) {
    guard let selection = confirmedSelection, reasoningChoices.contains(reasoning) else { return }
    switchModel(ModelSelection(modelID: selection.modelID, reasoning: reasoning))
  }

  func reduce(_ event: ChatEvent) {
    if lifecycle == .closed && event != .closed { return }
    if lifecycle == .closing {
      switch event {
      case .failure, .closed:
        break
      default:
        return
      }
    }
    switch event {
    case .ready:
      lifecycle = .idle
    case .status(let text):
      transcript.append(.status(id: UUID(), text: text))
    case .sessionTitle(let title):
      sessionTitle = title
    case .assistantStarted:
      let id = UUID()
      activeAssistant = id
      activeReasoning = nil
      transcript.append(.assistant(id: id, text: ""))
      lifecycle = .responding
    case .reasoningDelta(let text):
      updateReasoning(text, append: true)
    case .reasoningComplete(let text):
      updateReasoning(text, append: false)
      activeReasoning = nil
    case .assistantDelta(let text):
      replaceActiveAssistant(text, append: true)
    case .assistantComplete(let text):
      replaceActiveAssistant(text, append: false)
    case .modelCatalog(let catalog):
      self.catalog = catalog
      confirmedSelection = catalog.selected
      modelState = .ready
    case .modelCatalogFailure(let message):
      transcript.append(.failure(id: UUID(), text: message))
      modelState = .ready
    case .modelSwitch(let outcome):
      apply(outcome)
      modelState = .ready
    case .idle:
      activeAssistant = nil
      activeReasoning = nil
      lifecycle = .idle
    case .failure(let message):
      transcript.append(.failure(id: UUID(), text: message))
    case .closed:
      activeAssistant = nil
      activeReasoning = nil
      finishClose()
    }
  }

  func close(completion: @escaping @MainActor () -> Void = {}) {
    closeCompletions.append(completion)
    if lifecycle == .closed {
      finishClose()
      return
    }
    guard lifecycle != .closing else { return }
    lifecycle = .closing
    driver.close { [self] in
      finishClose()
    }
  }

  private func switchModel(_ selection: ModelSelection) {
    guard modelState == .ready, selection != confirmedSelection else { return }
    let result = driver.switchModel(selection)
    if result == .accepted {
      modelState = .switching
    } else {
      transcript.append(.failure(id: UUID(), text: message(for: result, action: "switch models")))
    }
  }

  private func apply(_ outcome: ModelSwitchOutcome) {
    switch outcome {
    case .unchanged(let model, let selection):
      confirm(model: model, selection: selection)
      transcript.append(.status(id: UUID(), text: "Already using that model and reasoning level."))
    case .defaultUpdated(let model, let selection):
      confirm(model: model, selection: selection)
      transcript.append(
        .status(
          id: UUID(),
          text:
            "\(model.displayName) with \(selection.reasoning.label) reasoning is now the default."))
    case .switched(let model, let selection, let historyReset, let defaultSaved, let cleanupFailed):
      confirm(model: model, selection: selection)
      var facts = ["Switched to \(model.displayName) with \(selection.reasoning.label) reasoning."]
      if historyReset {
        facts.append("Server history reset; visible transcript preserved.")
      }
      facts.append(defaultSaved ? "Saved as default." : "Default was not saved.")
      if cleanupFailed {
        facts.append("Previous session cleanup failed.")
      }
      transcript.append(.status(id: UUID(), text: facts.joined(separator: " ")))
    case .failed(let message):
      transcript.append(.failure(id: UUID(), text: message))
    }
  }

  private func confirm(model: ModelInfo, selection: ModelSelection) {
    confirmedSelection = selection
    var models = catalog?.models ?? []
    if let index = models.firstIndex(where: { $0.id == model.id }) {
      models[index] = model
    } else {
      models.append(model)
    }
    catalog = ModelCatalog(selected: selection, models: models)
  }

  private func updateReasoning(_ text: String, append: Bool) {
    if activeReasoning == nil {
      let id = UUID()
      activeReasoning = id
      transcript.append(.reasoning(id: id, text: ""))
    }
    guard let id = activeReasoning,
      let index = transcript.firstIndex(where: { $0.id == id }),
      case .reasoning(_, let existing) = transcript[index]
    else { return }
    transcript[index] = .reasoning(id: id, text: append ? existing + text : text)
  }

  private func finishClose() {
    lifecycle = .closed
    let completions = closeCompletions
    closeCompletions.removeAll()
    for completion in completions {
      completion()
    }
  }

  private func replaceActiveAssistant(_ text: String, append: Bool) {
    guard let id = activeAssistant,
      let index = transcript.firstIndex(where: { $0.id == id }),
      case .assistant(_, let existing) = transcript[index]
    else { return }
    transcript[index] = .assistant(id: id, text: append ? existing + text : text)
  }

  private func message(for result: ConversationOperationResult, action: String) -> String {
    switch result {
    case .accepted: ""
    case .busy: "Chat is busy."
    case .stopping: "Chat is closing."
    case .closed: "Chat is closed."
    case .failed: "Could not \(action)."
    }
  }
}

enum NativeEventDecodingError: Error {
  case malformed
}

enum NativeEventDecoder {
  static func decode(
    _ event: vivi_backend_event_t,
    bytes: [UInt8],
    models: [vivi_backend_model_t]
  ) throws -> ChatEvent {
    guard event.reserved == 0, bytes.count == Int(event.byte_count),
      models.count == Int(event.model_count)
    else { throw NativeEventDecodingError.malformed }

    func text(_ span: vivi_backend_span_t) throws -> String {
      let start = Int(span.offset)
      let length = Int(span.length)
      guard start >= 0, length >= 0, start <= bytes.count, length <= bytes.count - start,
        let value = String(bytes: bytes[start..<(start + length)], encoding: .utf8)
      else { throw NativeEventDecodingError.malformed }
      return value
    }

    func reasoning(_ raw: vivi_backend_reasoning_effort_t) throws -> ReasoningEffort {
      guard let value = ReasoningEffort(rawValue: raw.rawValue) else {
        throw NativeEventDecodingError.malformed
      }
      return value
    }

    func model(_ raw: vivi_backend_model_t) throws -> ModelInfo {
      guard raw.reserved == 0, raw.reasoning_mask & 0b1100_0000 == 0,
        raw.supports_vision <= 1
      else {
        throw NativeEventDecodingError.malformed
      }
      let choices = ReasoningEffort.allCases.filter {
        raw.reasoning_mask & UInt8(1 << $0.rawValue) != 0
      }
      let advertised =
        raw.advertised_default_reasoning == Int8(VIVI_BACKEND_REASONING_NONE.rawValue)
        ? nil : ReasoningEffort(rawValue: Int32(raw.advertised_default_reasoning))
      if let advertised, !choices.contains(advertised) {
        throw NativeEventDecodingError.malformed
      }
      let id = try text(raw.id)
      guard !id.isEmpty, !choices.isEmpty else { throw NativeEventDecodingError.malformed }
      return try ModelInfo(
        id: id,
        displayName: text(raw.display_name),
        maxContextWindowTokens: raw.max_context_window_tokens,
        maxOutputTokens: raw.max_output_tokens,
        supportsVision: raw.supports_vision != 0,
        reasoning: choices,
        advertisedDefaultReasoning: advertised)
    }

    guard event.default_saved <= 1, event.cleanup_failed <= 1 else {
      throw NativeEventDecodingError.malformed
    }
    let content = try text(event.content)
    switch event.kind {
    case VIVI_BACKEND_EVENT_READY: return .ready
    case VIVI_BACKEND_EVENT_STATUS: return .status(content)
    case VIVI_BACKEND_EVENT_SESSION_TITLE: return .sessionTitle(content)
    case VIVI_BACKEND_EVENT_ASSISTANT_STARTED: return .assistantStarted
    case VIVI_BACKEND_EVENT_REASONING_DELTA: return .reasoningDelta(content)
    case VIVI_BACKEND_EVENT_REASONING_COMPLETE: return .reasoningComplete(content)
    case VIVI_BACKEND_EVENT_ASSISTANT_DELTA: return .assistantDelta(content)
    case VIVI_BACKEND_EVENT_ASSISTANT_COMPLETE: return .assistantComplete(content)
    case VIVI_BACKEND_EVENT_MODEL_CATALOG:
      guard event.content_kind == VIVI_BACKEND_CONTENT_MODEL_CATALOG else {
        throw NativeEventDecodingError.malformed
      }
      let selected = ModelSelection(
        modelID: try text(event.selected_model_id),
        reasoning: try reasoning(event.selected_reasoning))
      let decoded = try models.map(model)
      guard !selected.modelID.isEmpty, Set(decoded.map(\.id)).count == decoded.count else {
        throw NativeEventDecodingError.malformed
      }
      if let selectedModel = decoded.first(where: { $0.id == selected.modelID }),
        !selectedModel.reasoning.contains(selected.reasoning)
      {
        throw NativeEventDecodingError.malformed
      }
      return .modelCatalog(ModelCatalog(selected: selected, models: decoded))
    case VIVI_BACKEND_EVENT_MODEL_CATALOG_FAILURE:
      return .modelCatalogFailure(content)
    case VIVI_BACKEND_EVENT_MODEL_SWITCH:
      guard event.content_kind == VIVI_BACKEND_CONTENT_MODEL_SWITCH else {
        throw NativeEventDecodingError.malformed
      }
      if event.switch_outcome == VIVI_BACKEND_MODEL_SWITCH_FAILED {
        guard models.isEmpty else { throw NativeEventDecodingError.malformed }
        return .modelSwitch(.failed(content))
      }
      guard models.count == 1 else { throw NativeEventDecodingError.malformed }
      let selection = ModelSelection(
        modelID: try text(event.selected_model_id),
        reasoning: try reasoning(event.selected_reasoning))
      let decoded = try model(models[0])
      guard decoded.id == selection.modelID, decoded.reasoning.contains(selection.reasoning) else {
        throw NativeEventDecodingError.malformed
      }
      switch event.switch_outcome {
      case VIVI_BACKEND_MODEL_SWITCH_UNCHANGED:
        return .modelSwitch(.unchanged(model: decoded, selection: selection))
      case VIVI_BACKEND_MODEL_SWITCH_DEFAULT_UPDATED:
        return .modelSwitch(.defaultUpdated(model: decoded, selection: selection))
      case VIVI_BACKEND_MODEL_SWITCH_SWITCHED:
        guard
          event.history_effect
            == VIVI_BACKEND_HISTORY_RESET_VISIBLE_TRANSCRIPT_PRESERVED
            || event.history_effect == VIVI_BACKEND_HISTORY_PRESERVED
        else { throw NativeEventDecodingError.malformed }
        return .modelSwitch(
          .switched(
            model: decoded,
            selection: selection,
            historyReset: event.history_effect
              == VIVI_BACKEND_HISTORY_RESET_VISIBLE_TRANSCRIPT_PRESERVED,
            defaultSaved: event.default_saved != 0,
            cleanupFailed: event.cleanup_failed != 0))
      default:
        throw NativeEventDecodingError.malformed
      }
    case VIVI_BACKEND_EVENT_IDLE: return .idle
    case VIVI_BACKEND_EVENT_FAILURE: return .failure(content)
    case VIVI_BACKEND_EVENT_CLOSED: return .closed
    default: throw NativeEventDecodingError.malformed
    }
  }
}

final class ViviConversationDriver: ViviConversationDriving, @unchecked Sendable {
  private let workspace: String
  private let queue = DispatchQueue(label: "com.scaryrawr.vivi.conversation")
  private var handle: OpaquePointer?
  private var receive: (@MainActor (ChatEvent) -> Void)?

  init(workspace: String) {
    self.workspace = workspace
  }

  func start(
    receive: @escaping @MainActor (ChatEvent) -> Void
  ) -> ConversationOperationResult {
    queue.sync {
      self.receive = receive
      let bytes = Array(workspace.utf8)
      let settingsPath =
        FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".vivi/settings.json").path
      let settingsBytes = Array(settingsPath.utf8)
      var options = vivi_backend_conversation_options_t(
        working_directory: nil,
        working_directory_length: UInt32(bytes.count),
        settings_path: nil,
        settings_path_length: UInt32(settingsBytes.count),
        copilot_cli_launch: VIVI_BACKEND_COPILOT_CLI_SEARCH_PROCESS_PATH,
        wake: Self.wake,
        wake_context: Unmanaged.passUnretained(self).toOpaque()
      )
      let result = bytes.withUnsafeBufferPointer { buffer in
        settingsBytes.withUnsafeBufferPointer { settingsBuffer in
          options.working_directory = buffer.baseAddress
          options.settings_path = settingsBuffer.baseAddress
          return vivi_backend_open(&options, &handle)
        }
      }
      guard result == VIVI_BACKEND_OK else {
        self.receive = nil
        return Self.operationResult(result)
      }
      return .accepted
    }
  }

  func submit(_ prompt: String) -> ConversationOperationResult {
    let bytes = Array(prompt.utf8)
    return queue.sync {
      guard let handle else { return .closed }
      return Self.operationResult(
        bytes.withUnsafeBufferPointer {
          vivi_backend_submit(handle, $0.baseAddress, UInt32($0.count))
        })
    }
  }

  func refreshModels() -> ConversationOperationResult {
    queue.sync {
      guard let handle else { return .closed }
      return Self.operationResult(vivi_backend_refresh_models(handle))
    }
  }

  func switchModel(_ selection: ModelSelection) -> ConversationOperationResult {
    let bytes = Array(selection.modelID.utf8)
    return queue.sync {
      guard let handle else { return .closed }
      return Self.operationResult(
        bytes.withUnsafeBufferPointer {
          vivi_backend_switch_model(
            handle,
            $0.baseAddress,
            UInt32($0.count),
            vivi_backend_reasoning_effort_t(rawValue: selection.reasoning.rawValue))
        })
    }
  }

  func close(completion: @escaping @MainActor () -> Void) {
    queue.async { [self] in
      if let handle {
        _ = vivi_backend_close(handle)
        vivi_backend_destroy(handle)
        self.handle = nil
      }
      receive = nil
      Task { @MainActor in completion() }
    }
  }

  private func drain() {
    queue.async { [self] in drainLocked() }
  }

  private static let wake: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    context in
    guard let context else { return }
    Unmanaged<ViviConversationDriver>.fromOpaque(context).takeUnretainedValue().drain()
  }

  private func drainLocked() {
    guard let handle else { return }
    var events: [ChatEvent] = []
    while true {
      var event = vivi_backend_event_t()
      let result = vivi_backend_next_event(handle, &event, nil, 0, nil, 0)
      if result == VIVI_BACKEND_NO_EVENT {
        deliver(events)
        return
      }
      guard result == VIVI_BACKEND_OK || result == VIVI_BACKEND_BUFFER_TOO_SMALL else {
        failDrain(handle, events: &events, message: "Could not read a backend event.")
        return
      }
      var bytes = Array(repeating: UInt8(0), count: Int(event.byte_count))
      var models = Array(repeating: vivi_backend_model_t(), count: Int(event.model_count))
      if result == VIVI_BACKEND_BUFFER_TOO_SMALL {
        let copied = bytes.withUnsafeMutableBufferPointer { byteBuffer in
          models.withUnsafeMutableBufferPointer { modelBuffer in
            vivi_backend_next_event(
              handle,
              &event,
              byteBuffer.baseAddress,
              UInt32(byteBuffer.count),
              modelBuffer.baseAddress,
              UInt32(modelBuffer.count))
          }
        }
        guard copied == VIVI_BACKEND_OK else {
          failDrain(handle, events: &events, message: "Could not copy a backend event.")
          return
        }
      }
      do {
        let decoded = try NativeEventDecoder.decode(event, bytes: bytes, models: models)
        events.append(decoded)
        if decoded == .closed {
          destroyLocked(handle, requestClose: false)
          deliver(events, terminal: true)
          return
        }
      } catch {
        failDrain(handle, events: &events, message: "The backend returned a malformed event.")
        return
      }
    }
  }

  private func failDrain(
    _ handle: OpaquePointer,
    events: inout [ChatEvent],
    message: String
  ) {
    events.append(.failure(message))
    events.append(.closed)
    destroyLocked(handle, requestClose: true)
    deliver(events, terminal: true)
  }

  private func destroyLocked(_ handle: OpaquePointer, requestClose: Bool) {
    if requestClose {
      _ = vivi_backend_close(handle)
    }
    vivi_backend_destroy(handle)
    self.handle = nil
  }

  private func deliver(_ events: [ChatEvent], terminal: Bool = false) {
    guard let receive, !events.isEmpty else { return }
    DispatchQueue.main.async {
      for event in events {
        receive(event)
      }
    }
    if terminal {
      self.receive = nil
    }
  }

  private static func operationResult(
    _ result: vivi_backend_result_t
  ) -> ConversationOperationResult {
    switch result {
    case VIVI_BACKEND_OK: .accepted
    case VIVI_BACKEND_BUSY: .busy
    case VIVI_BACKEND_STOPPING: .stopping
    case VIVI_BACKEND_CLOSED: .closed
    default: .failed
    }
  }
}
