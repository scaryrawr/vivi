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

enum ChatItem: Identifiable, Equatable {
  case user(id: UUID, text: String)
  case assistant(id: UUID, text: String)
  case status(id: UUID, text: String)
  case failure(id: UUID, text: String)

  var id: UUID {
    switch self {
    case .user(let id, _), .assistant(let id, _), .status(let id, _), .failure(let id, _):
      return id
    }
  }

  var text: String {
    switch self {
    case .user(_, let text), .assistant(_, let text), .status(_, let text), .failure(_, let text):
      return text
    }
  }
}

enum ChatEvent: Equatable {
  case ready
  case status(String)
  case assistantStarted
  case assistantDelta(String)
  case assistantComplete(String)
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
  func close(completion: @escaping @MainActor () -> Void)
}

@MainActor
final class NativeChatStore: ObservableObject {
  @Published private(set) var lifecycle: ChatLifecycle = .starting
  @Published private(set) var transcript: [ChatItem] = []
  @Published var draft = ""

  let workspace: String
  private var activeAssistant: UUID?
  private let driver: ViviConversationDriving
  private var closeCompletions: [@MainActor () -> Void] = []

  init(workspace: String, driver: ViviConversationDriving) {
    self.workspace = workspace
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
    case .assistantStarted:
      let id = UUID()
      activeAssistant = id
      transcript.append(.assistant(id: id, text: ""))
      lifecycle = .responding
    case .assistantDelta(let text):
      replaceActiveAssistant(text, append: true)
    case .assistantComplete(let text):
      replaceActiveAssistant(text, append: false)
    case .idle:
      activeAssistant = nil
      lifecycle = .idle
    case .failure(let message):
      transcript.append(.failure(id: UUID(), text: message))
    case .closed:
      activeAssistant = nil
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
      let index = transcript.firstIndex(where: { $0.id == id })
    else { return }
    guard case .assistant(_, let existing) = transcript[index] else { return }
    transcript[index] = .assistant(id: id, text: append ? existing + text : text)
  }

  private func message(
    for result: ConversationOperationResult,
    action: String
  ) -> String {
    switch result {
    case .accepted:
      return ""
    case .busy:
      return "Chat is busy."
    case .stopping:
      return "Chat is closing."
    case .closed:
      return "Chat is closed."
    case .failed:
      return "Could not \(action)."
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
      var options = vivi_backend_conversation_options_t(
        working_directory: nil,
        working_directory_length: UInt32(bytes.count),
        copilot_cli_launch: VIVI_BACKEND_COPILOT_CLI_SEARCH_PROCESS_PATH,
        wake: Self.wake,
        wake_context: Unmanaged.passUnretained(self).toOpaque()
      )
      let result = bytes.withUnsafeBufferPointer { buffer in
        options.working_directory = buffer.baseAddress
        return vivi_backend_open(&options, &handle)
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
      let result = bytes.withUnsafeBufferPointer {
        vivi_backend_submit(handle, $0.baseAddress, UInt32($0.count))
      }
      return Self.operationResult(result)
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
    queue.async { [self] in
      drainLocked()
    }
  }

  private static let wake: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    context in
    guard let context else { return }
    let driver = Unmanaged<ViviConversationDriver>.fromOpaque(context).takeUnretainedValue()
    driver.drain()
  }

  private func drainLocked() {
    guard let handle else { return }
    var events: [ChatEvent] = []
    while true {
      var event = vivi_backend_event_t()
      let result = vivi_backend_next_event(handle, &event, nil, 0)
      if result == VIVI_BACKEND_NO_EVENT {
        deliver(events)
        return
      }
      guard result == VIVI_BACKEND_OK || result == VIVI_BACKEND_BUFFER_TOO_SMALL else {
        events.append(.failure("Could not read a backend event."))
        events.append(.closed)
        destroyLocked(handle, requestClose: true)
        deliver(events, terminal: true)
        return
      }
      let content: [UInt8]
      if result == VIVI_BACKEND_OK {
        content = []
      } else {
        var buffer = Array(repeating: UInt8(0), count: Int(event.content_length))
        let copied = buffer.withUnsafeMutableBufferPointer {
          vivi_backend_next_event(handle, &event, $0.baseAddress, UInt32($0.count))
        }
        guard copied == VIVI_BACKEND_OK else {
          events.append(.failure("Could not copy a backend event."))
          events.append(.closed)
          destroyLocked(handle, requestClose: true)
          deliver(events, terminal: true)
          return
        }
        content = buffer
      }
      let text = String(decoding: content, as: UTF8.self)
      let projected = Self.chatEvent(event.kind, text: text)
      events.append(projected)
      if projected == .closed {
        destroyLocked(handle, requestClose: false)
        deliver(events, terminal: true)
        return
      }
    }
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
    case VIVI_BACKEND_OK:
      return .accepted
    case VIVI_BACKEND_BUSY:
      return .busy
    case VIVI_BACKEND_STOPPING:
      return .stopping
    case VIVI_BACKEND_CLOSED:
      return .closed
    default:
      return .failed
    }
  }

  private static func chatEvent(
    _ kind: vivi_backend_event_kind_t,
    text: String
  ) -> ChatEvent {
    switch kind {
    case VIVI_BACKEND_EVENT_READY:
      return .ready
    case VIVI_BACKEND_EVENT_STATUS:
      return .status(text)
    case VIVI_BACKEND_EVENT_ASSISTANT_STARTED:
      return .assistantStarted
    case VIVI_BACKEND_EVENT_ASSISTANT_DELTA:
      return .assistantDelta(text)
    case VIVI_BACKEND_EVENT_ASSISTANT_COMPLETE:
      return .assistantComplete(text)
    case VIVI_BACKEND_EVENT_IDLE:
      return .idle
    case VIVI_BACKEND_EVENT_FAILURE:
      return .failure(text)
    case VIVI_BACKEND_EVENT_CLOSED:
      return .closed
    default:
      return .failure("The backend returned an unsupported event.")
    }
  }
}
