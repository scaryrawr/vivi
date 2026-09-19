import Combine
import Foundation
import ViviBackend

enum ChatLifecycle: Equatable {
  case starting
  case idle
  case responding
  case awaitingInput
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

struct ResumeKey: Equatable, Hashable {
  let generation: UInt64
  let slot: UInt32
}

struct SessionSummary: Equatable {
  let key: ResumeKey
  let workingDirectory: String
  let title: String?
  let isCurrent: Bool
}

struct SessionCatalog: Equatable {
  let sessions: [SessionSummary]
}

enum TranscriptSnapshotItem: Equatable {
  case user(String)
  case assistant(String)
  case reasoning(String)
}

struct ResumedSession: Equatable {
  let summary: SessionSummary
  let transcript: [TranscriptSnapshotItem]
  let cleanupFailed: Bool
}

enum SessionResumeResult: Equatable {
  case resumed(ResumedSession)
  case failed(String)
}

enum SessionControlState: Equatable {
  case ready
  case refreshing
  case resuming(ResumeKey)
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

enum ToolResultState: Equatable {
  case running
  case succeeded
  case failed
  case image
}

enum PresentationLanguage: Int32, Equatable {
  case zig = 1
  case bash = 2
  case json = 3
  case yaml = 4
  case diff = 5
  case javascript = 6
  case typescript = 7
  case tsx = 8
  case rust = 9
  case c = 10
  case cpp = 11
  case go = 12
  case java = 13
  case lua = 14
  case python = 15
}

enum SemanticToken: Int32, Equatable {
  case comment = 1
  case string = 2
  case number = 3
  case constant = 4
  case keyword = 5
  case function = 6
  case property = 7
  case `operator` = 8
  case inserted = 9
  case deleted = 10
  case meta = 11
}

struct SemanticSpan: Equatable {
  let byteRange: Range<Int>
  let token: SemanticToken
}

enum ToolPresentation: Equatable {
  case literal(String)
  case markdown(String)
  case source(text: String, language: PresentationLanguage, spans: [SemanticSpan])

  var text: String {
    switch self {
    case .literal(let text), .markdown(let text), .source(let text, _, _):
      text
    }
  }
}

struct ToolActivity: Equatable {
  let callID: String
  let title: String
  let detail: String
  let input: String
  let inputPresentation: ToolPresentation
  var result: ToolResultState
  var output: Data?
  var outputPresentation: ToolPresentation?
}

struct UserInputRequest: Equatable {
  let id: String
  let question: String
  let choices: [String]
  let allowsFreeform: Bool
}

enum UserInputAnswer: Equatable {
  case choice(String)
  case freeform(String)

  var text: String {
    switch self {
    case .choice(let text), .freeform(let text): text
    }
  }
}

enum UserInputSubmissionState: Equatable {
  case pending
  case submitting
  case failed(String)
}

struct ActiveUserInput: Equatable {
  let request: UserInputRequest
  var state: UserInputSubmissionState = .pending
  var showsFreeform: Bool
  var freeformDraft = ""
}

enum ChatItem: Identifiable, Equatable {
  case user(id: UUID, text: String)
  case assistantHeader(id: UUID)
  case assistant(id: UUID, text: String)
  case reasoning(id: UUID, text: String)
  case tool(id: UUID, activity: ToolActivity)
  case status(id: UUID, text: String)
  case failure(id: UUID, text: String)
  case userInput(id: UUID, request: UserInputRequest, answer: UserInputAnswer?)

  var id: UUID {
    switch self {
    case .assistantHeader(let id):
      id
    case .user(let id, _), .assistant(let id, _), .reasoning(let id, _),
      .tool(let id, _), .status(let id, _), .failure(let id, _),
      .userInput(let id, _, _):
      id
    }
  }

  var text: String {
    switch self {
    case .assistantHeader:
      ""
    case .user(_, let text), .assistant(_, let text), .reasoning(_, let text),
      .status(_, let text), .failure(_, let text):
      text
    case .tool(_, let activity):
      activity.outputPresentation?.text ?? ""
    case .userInput(_, let request, let answer):
      answer.map { "\(request.question)\n\($0.text)" } ?? request.question
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
  case toolStarted(ToolActivity)
  case toolFinished(
    callID: String,
    result: ToolResultState,
    output: Data,
    presentation: ToolPresentation
  )
  case modelCatalog(ModelCatalog)
  case modelCatalogFailure(String)
  case modelSwitch(ModelSwitchOutcome)
  case sessionCatalog(SessionCatalog)
  case sessionCatalogFailure(String)
  case sessionResume(SessionResumeResult)
  case userInputRequested(UserInputRequest)
  case idle
  case failure(String)
  case closed
}

enum ConversationOperationResult: Equatable {
  case accepted
  case rejected
  case busy
  case stopping
  case closed
  case failed
}

protocol ViviConversationDriving: AnyObject {
  func start(receive: @escaping @MainActor (ChatEvent) -> Void) -> ConversationOperationResult
  func submit(
    _ prompt: String,
    attachments: [ComposerAttachment]
  ) -> ConversationOperationResult
  func refreshModels() -> ConversationOperationResult
  func switchModel(_ selection: ModelSelection) -> ConversationOperationResult
  func refreshSessions() -> ConversationOperationResult
  func resumeSession(_ key: ResumeKey) -> ConversationOperationResult
  func respondToUserInput(
    requestID: String,
    answer: UserInputAnswer
  ) -> ConversationOperationResult
  func close(completion: @escaping @MainActor () -> Void)
}

struct ActiveConversationPresentation: Equatable {
  let workspace: String
  let sessionTitle: String
  let transcript: [ChatItem]
  let confirmedSelection: ModelSelection?
}

@MainActor
final class NativeChatStore: ObservableObject {
  @Published private(set) var lifecycle: ChatLifecycle = .starting
  @Published private(set) var activePresentation: ActiveConversationPresentation
  @Published private(set) var modelState: ModelControlState = .loading
  @Published private(set) var catalog: ModelCatalog?
  @Published private(set) var sessionCatalog: SessionCatalog?
  @Published private(set) var sessionCatalogFailure: String?
  @Published private(set) var sessionState: SessionControlState = .ready
  @Published private(set) var activeUserInput: ActiveUserInput?
  @Published private(set) var attachments: [ComposerAttachment] = []
  @Published private(set) var attachmentError: String?
  @Published private(set) var isAcquiringAttachments = false
  @Published var draft = ""

  var workspace: String { activePresentation.workspace }
  var sessionTitle: String { activePresentation.sessionTitle }
  private(set) var transcript: [ChatItem] {
    get { activePresentation.transcript }
    set { activePresentation = replacingActive(transcript: newValue) }
  }
  var confirmedSelection: ModelSelection? { activePresentation.confirmedSelection }

  private var activeAssistant: UUID?
  private var activeReasoning: UUID?
  private var pendingReasoningCompletion: UUID?
  private var activeReasoningPrefix = ""
  private var responseHeaderVisible = false
  private let driver: ViviConversationDriving
  private let attachmentAcquirer: ComposerAttachmentAcquiring
  private let requestNewConversation: @MainActor (WorkspaceIdentity) -> Bool
  private var attachmentAcquisitionTask: Task<Void, Never>?
  private var closeCompletions: [@MainActor () -> Void] = []

  init(
    workspace: String,
    driver: ViviConversationDriving,
    attachmentAcquirer: ComposerAttachmentAcquiring = AppKitComposerAttachmentAcquirer(),
    requestNewConversation: @escaping @MainActor (WorkspaceIdentity) -> Bool = { _ in false }
  ) {
    let presentation = ActiveConversationPresentation(
      workspace: workspace,
      sessionTitle: URL(fileURLWithPath: workspace).lastPathComponent,
      transcript: [],
      confirmedSelection: nil)
    activePresentation = presentation
    self.driver = driver
    self.attachmentAcquirer = attachmentAcquirer
    self.requestNewConversation = requestNewConversation
    let started = driver.start { [weak self] event in
      self?.reduce(event)
    }
    if started != .accepted {
      transcript.append(.failure(id: UUID(), text: message(for: started, action: "start chat")))
      lifecycle = .closed
    }
  }

  var isBusy: Bool {
    lifecycle != .idle
  }

  var canSubmit: Bool {
    !isBusy && !isAcquiringAttachments && modelState == .ready && sessionState == .ready
      && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !attachments.isEmpty)
  }

  var canAcquireAttachments: Bool {
    lifecycle == .idle && !isAcquiringAttachments
      && modelState == .ready && sessionState == .ready
      && activeUserInput == nil && attachments.count < composerAttachmentCountLimit
  }

  var canSubmitUserInput: Bool {
    guard lifecycle == .awaitingInput, let activeUserInput else { return false }
    return activeUserInput.state != .submitting
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
    guard canSubmit else { return }
    if attachments.isEmpty,
      prompt.caseInsensitiveCompare("/new") == .orderedSame,
      let activeWorkspace = WorkspaceIdentity(absolutePath: workspace)
    {
      if requestNewConversation(activeWorkspace) {
        draft = ""
      }
      return
    }
    let submittedAttachments = attachments
    let result = driver.submit(prompt, attachments: submittedAttachments)
    guard result == .accepted else {
      finishStreamingRows()
      transcript.append(.status(id: UUID(), text: message(for: result, action: "send message")))
      return
    }

    finishStreamingRows()
    responseHeaderVisible = false
    transcript.append(
      .user(
        id: UUID(),
        text: submittedMessageText(prompt: prompt, attachments: submittedAttachments)))
    draft = ""
    attachments = []
    attachmentError = nil
    lifecycle = .responding
  }

  func chooseAttachments() {
    guard canAcquireAttachments, attachmentAcquisitionTask == nil else { return }
    attachmentError = nil
    isAcquiringAttachments = true
    attachmentAcquisitionTask = Task { [weak self] in
      guard let self else { return }
      defer {
        attachmentAcquisitionTask = nil
        isAcquiringAttachments = false
      }
      guard !Task.isCancelled else { return }
      do {
        let selected = try await attachmentAcquirer.chooseImages()
        guard !Task.isCancelled, canPublishAttachmentAcquisition else { return }
        try appendAttachments(selected)
      } catch {
        guard !Task.isCancelled else { return }
        attachmentError = attachmentMessage(error)
      }
    }
  }

  func pasteAttachment() {
    guard canAcquireAttachments, attachmentAcquisitionTask == nil else { return }
    attachmentError = nil
    isAcquiringAttachments = true
    attachmentAcquisitionTask = Task { [weak self] in
      guard let self else { return }
      defer {
        attachmentAcquisitionTask = nil
        isAcquiringAttachments = false
      }
      guard !Task.isCancelled else { return }
      do {
        let selected = try await attachmentAcquirer.pasteImage()
        guard !Task.isCancelled, canPublishAttachmentAcquisition else { return }
        try appendAttachments([selected])
      } catch {
        guard !Task.isCancelled else { return }
        attachmentError = attachmentMessage(error)
      }
    }
  }

  func waitForAttachmentAcquisition() async {
    await attachmentAcquisitionTask?.value
  }

  func removeAttachment(_ id: UUID) {
    guard lifecycle != .closing && lifecycle != .closed else { return }
    attachments.removeAll { $0.id == id }
    attachmentError = nil
  }

  func revealFreeformInput() {
    guard var interaction = activeUserInput, interaction.request.allowsFreeform,
      interaction.state != .submitting
    else { return }
    interaction.showsFreeform = true
    if case .failed = interaction.state {
      interaction.state = .pending
    }
    activeUserInput = interaction
  }

  func hideFreeformInput() {
    guard var interaction = activeUserInput, !interaction.request.choices.isEmpty,
      interaction.state != .submitting
    else { return }
    interaction.showsFreeform = false
    interaction.state = .pending
    activeUserInput = interaction
  }

  func updateFreeformDraft(_ value: String) {
    guard var interaction = activeUserInput, interaction.state != .submitting else { return }
    interaction.freeformDraft = value
    if case .failed = interaction.state {
      interaction.state = .pending
    }
    activeUserInput = interaction
  }

  func submitUserInputChoice(_ choice: String) {
    guard let interaction = activeUserInput,
      interaction.request.choices.contains(choice)
    else { return }
    submitUserInput(.choice(choice))
  }

  func submitUserInputFreeform() {
    guard let interaction = activeUserInput else { return }
    let answer = interaction.freeformDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !answer.isEmpty else { return }
    submitUserInput(.freeform(answer))
  }

  func refreshModels() {
    guard !isAcquiringAttachments, modelState == .ready, sessionState == .ready else { return }
    let result = driver.refreshModels()
    if result == .accepted {
      modelState = .refreshing
    } else {
      transcript.append(.failure(id: UUID(), text: message(for: result, action: "refresh models")))
    }
  }

  func refreshSessions() {
    guard !isAcquiringAttachments, lifecycle == .idle, modelState == .ready,
      sessionState == .ready
    else { return }
    let result = driver.refreshSessions()
    if result == .accepted {
      sessionCatalog = nil
      sessionCatalogFailure = nil
      sessionState = .refreshing
    } else {
      let failure = message(for: result, action: "refresh sessions")
      sessionCatalogFailure = failure
      transcript.append(.failure(id: UUID(), text: failure))
    }
  }

  func resumeSession(_ key: ResumeKey) {
    guard !isAcquiringAttachments, lifecycle == .idle, modelState == .ready,
      sessionState == .ready,
      sessionCatalog?.sessions.contains(where: { $0.key == key }) == true
    else { return }
    let result = driver.resumeSession(key)
    if result == .accepted {
      sessionState = .resuming(key)
    } else {
      transcript.append(.failure(id: UUID(), text: message(for: result, action: "resume session")))
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
    select(modelID: selection.modelID, reasoning: reasoning)
  }

  func select(modelID: String, reasoning: ReasoningEffort) {
    guard
      let model = modelChoices.first(where: { $0.id == modelID }),
      model.reasoning.contains(reasoning)
    else { return }
    switchModel(ModelSelection(modelID: modelID, reasoning: reasoning))
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
      finishStreamingRows()
      transcript.append(.status(id: UUID(), text: text))
    case .sessionTitle(let title):
      activePresentation = replacingActive(sessionTitle: title)
    case .assistantStarted:
      activeAssistant = nil
      activeReasoning = nil
      pendingReasoningCompletion = nil
      activeReasoningPrefix = ""
      responseHeaderVisible = false
      lifecycle = .responding
    case .reasoningDelta(let text):
      updateReasoning(text, append: true)
    case .reasoningComplete(let text):
      updateReasoning(text, append: false)
      activeReasoning = nil
      activeReasoningPrefix = ""
    case .assistantDelta(let text):
      replaceActiveAssistant(text, append: true)
    case .assistantComplete(let text):
      if !text.isEmpty {
        replaceActiveAssistant(text, append: false)
      }
      activeAssistant = nil
    case .toolStarted(let activity):
      ensureResponseHeader()
      activeReasoning = nil
      pendingReasoningCompletion = nil
      activeReasoningPrefix = ""
      activeAssistant = nil
      if let index = transcript.firstIndex(where: { item in
        guard case .tool(_, let existing) = item else { return false }
        return existing.callID == activity.callID
      }) {
        let id = transcript[index].id
        transcript[index] = .tool(id: id, activity: activity)
      } else {
        transcript.append(.tool(id: UUID(), activity: activity))
      }
    case .toolFinished(let callID, let result, let output, let presentation):
      guard
        let index = transcript.firstIndex(where: { item in
          guard case .tool(_, let activity) = item else { return false }
          return activity.callID == callID
        }), case .tool(let id, var activity) = transcript[index]
      else { break }
      activity.result = result
      activity.output = output
      activity.outputPresentation = presentation
      transcript[index] = .tool(id: id, activity: activity)
    case .modelCatalog(let catalog):
      self.catalog = catalog
      activePresentation = replacingActive(confirmedSelection: catalog.selected)
      modelState = .ready
    case .modelCatalogFailure(let message):
      finishStreamingRows()
      transcript.append(.failure(id: UUID(), text: message))
      modelState = .ready
    case .modelSwitch(let outcome):
      apply(outcome)
      modelState = .ready
    case .sessionCatalog(let catalog):
      guard case .refreshing = sessionState else {
        let message = "The backend returned an unexpected session catalog."
        transcript.append(.failure(id: UUID(), text: message))
        sessionCatalogFailure = message
        sessionState = .ready
        break
      }
      sessionCatalog = catalog
      sessionCatalogFailure = nil
      sessionState = .ready
    case .sessionCatalogFailure(let message):
      transcript.append(.failure(id: UUID(), text: message))
      sessionCatalogFailure = message
      sessionState = .ready
    case .sessionResume(let result):
      apply(result)
      sessionState = .ready
    case .userInputRequested(let request):
      finishStreamingRows()
      ensureResponseHeader()
      let interaction = ActiveUserInput(
        request: request,
        showsFreeform: request.choices.isEmpty)
      activeUserInput = interaction
      transcript.append(.userInput(id: UUID(), request: request, answer: nil))
      lifecycle = .awaitingInput
    case .idle:
      activeAssistant = nil
      activeReasoning = nil
      pendingReasoningCompletion = nil
      activeReasoningPrefix = ""
      lifecycle = .idle
    case .failure(let message):
      finishStreamingRows()
      transcript.append(.failure(id: UUID(), text: message))
    case .closed:
      activeAssistant = nil
      activeReasoning = nil
      pendingReasoningCompletion = nil
      activeReasoningPrefix = ""
      activeUserInput = nil
      clearAttachments()
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
    clearAttachments()
    lifecycle = .closing
    driver.close { [self] in
      finishClose()
    }
  }

  private func appendAttachments(_ selected: [ComposerAttachment]) throws {
    guard !selected.isEmpty else { return }
    guard attachments.count + selected.count <= composerAttachmentCountLimit else {
      throw ComposerAttachmentAcquisitionError.tooMany
    }

    let total =
      attachments.reduce(0) { $0 + $1.data.count }
      + selected.reduce(0) { $0 + $1.data.count }
    guard total <= composerAttachmentByteLimit else {
      throw ComposerAttachmentAcquisitionError.totalTooLarge
    }
    attachments.append(contentsOf: selected)
  }

  private var canPublishAttachmentAcquisition: Bool {
    lifecycle == .idle && modelState == .ready && sessionState == .ready
      && activeUserInput == nil
  }

  private func clearAttachments() {
    attachmentAcquisitionTask?.cancel()
    attachmentAcquirer.cancel()
    attachments = []
    attachmentError = nil
  }

  private func switchModel(_ selection: ModelSelection) {
    guard !isAcquiringAttachments, modelState == .ready, sessionState == .ready,
      selection != confirmedSelection
    else {
      return
    }
    let result = driver.switchModel(selection)
    if result == .accepted {
      modelState = .switching
    } else {
      transcript.append(.failure(id: UUID(), text: message(for: result, action: "switch models")))
    }
  }

  private func submitUserInput(_ answer: UserInputAnswer) {
    guard var interaction = activeUserInput, canSubmitUserInput else { return }
    interaction.state = .submitting
    activeUserInput = interaction
    let result = driver.respondToUserInput(
      requestID: interaction.request.id,
      answer: answer)
    guard result == .accepted else {
      interaction.state = .failed(message(for: result, action: "send answer"))
      activeUserInput = interaction
      return
    }
    if let index = transcript.firstIndex(where: { item in
      guard case .userInput(_, let request, nil) = item else { return false }
      return request.id == interaction.request.id
    }) {
      transcript[index] = .userInput(
        id: transcript[index].id,
        request: interaction.request,
        answer: answer)
    }
    activeUserInput = nil
    lifecycle = .responding
  }

  private func apply(_ outcome: ModelSwitchOutcome) {
    finishStreamingRows()
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
    activePresentation = replacingActive(confirmedSelection: selection)
    var models = catalog?.models ?? []
    if let index = models.firstIndex(where: { $0.id == model.id }) {
      models[index] = model
    } else {
      models.append(model)
    }
    catalog = ModelCatalog(selected: selection, models: models)
  }

  private func apply(_ result: SessionResumeResult) {
    guard case .resuming(let requestedKey) = sessionState else {
      transcript.append(
        .failure(id: UUID(), text: "The backend returned an unexpected session result."))
      return
    }
    switch result {
    case .failed(let message):
      transcript.append(.failure(id: UUID(), text: message))
    case .resumed(let resumed):
      guard resumed.summary.key == requestedKey else {
        transcript.append(
          .failure(id: UUID(), text: "The backend resumed an unexpected session."))
        return
      }
      finishStreamingRows()
      responseHeaderVisible = false
      var snapshot = resumed.transcript.map { item -> ChatItem in
        switch item {
        case .user(let text): .user(id: UUID(), text: text)
        case .assistant(let text): .assistant(id: UUID(), text: text)
        case .reasoning(let text): .reasoning(id: UUID(), text: text)
        }
      }
      if resumed.cleanupFailed {
        snapshot.append(.status(id: UUID(), text: "Previous session cleanup failed."))
      }
      activePresentation = ActiveConversationPresentation(
        workspace: resumed.summary.workingDirectory,
        sessionTitle: resumed.summary.title
          ?? URL(fileURLWithPath: resumed.summary.workingDirectory).lastPathComponent,
        transcript: snapshot,
        confirmedSelection: confirmedSelection)
      sessionCatalogFailure = nil
      sessionCatalog = nil
    }
  }

  private func replacingActive(
    workspace: String? = nil,
    sessionTitle: String? = nil,
    transcript: [ChatItem]? = nil,
    confirmedSelection: ModelSelection?? = nil
  ) -> ActiveConversationPresentation {
    ActiveConversationPresentation(
      workspace: workspace ?? activePresentation.workspace,
      sessionTitle: sessionTitle ?? activePresentation.sessionTitle,
      transcript: transcript ?? activePresentation.transcript,
      confirmedSelection: confirmedSelection ?? activePresentation.confirmedSelection)
  }

  private func updateReasoning(_ text: String, append: Bool) {
    guard activeReasoning != nil || !text.isEmpty else { return }
    ensureResponseHeader()
    var startsNewSegment = false
    if activeReasoning == nil {
      activeAssistant = nil
      if case .reasoning(let id, let existing) = transcript.last {
        activeReasoning = id
        pendingReasoningCompletion = id
        activeReasoningPrefix = existing.isEmpty ? "" : existing + "\n\n"
        startsNewSegment = true
      } else if case .assistant = transcript.last,
        let id = pendingReasoningCompletion
      {
        activeReasoning = id
        activeReasoningPrefix = ""
      } else {
        let id = UUID()
        activeReasoning = id
        pendingReasoningCompletion = id
        activeReasoningPrefix = ""
        let item = ChatItem.reasoning(id: id, text: "")
        if case .assistant = transcript.last {
          transcript.insert(item, at: transcript.count - 1)
        } else {
          transcript.append(item)
        }
      }
    }
    guard let id = activeReasoning,
      let index = transcript.firstIndex(where: { $0.id == id }),
      case .reasoning(_, let existing) = transcript[index]
    else { return }
    let replacement =
      if append {
        startsNewSegment ? activeReasoningPrefix + text : existing + text
      } else {
        activeReasoningPrefix + text
      }
    transcript[index] = .reasoning(id: id, text: replacement)
  }

  private func finishClose() {
    lifecycle = .closed
    let completions = closeCompletions
    closeCompletions.removeAll()
    for completion in completions {
      completion()
    }
  }

  private func finishStreamingRows() {
    activeAssistant = nil
    activeReasoning = nil
    pendingReasoningCompletion = nil
    activeReasoningPrefix = ""
  }

  private func replaceActiveAssistant(_ text: String, append: Bool) {
    if activeAssistant == nil {
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      ensureResponseHeader()
      let id = UUID()
      activeAssistant = id
      activeReasoning = nil
      transcript.append(.assistant(id: id, text: ""))
    }
    guard let id = activeAssistant,
      let index = transcript.firstIndex(where: { $0.id == id }),
      case .assistant(_, let existing) = transcript[index]
    else { return }
    transcript[index] = .assistant(id: id, text: append ? existing + text : text)
  }

  private func ensureResponseHeader() {
    guard lifecycle == .responding, !responseHeaderVisible else { return }
    responseHeaderVisible = true
    transcript.append(.assistantHeader(id: UUID()))
  }

  private func submittedMessageText(
    prompt: String,
    attachments: [ComposerAttachment]
  ) -> String {
    guard !attachments.isEmpty else { return prompt }
    let images = attachments.map { "Attached \($0.displayName)" }.joined(separator: "\n")
    return prompt.isEmpty ? images : "\(prompt)\n\n\(images)"
  }

  private func attachmentMessage(_ error: Error) -> String {
    if let error = error as? LocalizedError, let message = error.errorDescription {
      return message
    }
    return "The image could not be attached."
  }

  private func message(for result: ConversationOperationResult, action: String) -> String {
    switch result {
    case .accepted: ""
    case .rejected: "That response was not accepted. Try again."
    case .busy: "Chat is busy."
    case .stopping: "Chat is closing."
    case .closed: "Chat is closed."
    case .failed: "Could not \(action)."
    }
  }
}

enum MarkdownBlockKind: Equatable {
  case paragraph
  case heading(level: Int)
  case unorderedListItem
  case orderedListItem(ordinal: Int)
  case code(language: String?)
  case quote
  case thematicBreak
}

struct MarkdownBlock: Equatable {
  let kind: MarkdownBlockKind
  var content: AttributedString
  var codePresentation: ToolPresentation? = nil
}

@MainActor
final class CodePresentationCache {
  static let shared = CodePresentationCache(capacity: 128)

  private struct Key: Hashable {
    let language: String
    let source: String
  }

  private let capacity: Int
  private var entries: [Key: ToolPresentation] = [:]
  private var insertionOrder: [Key] = []

  init(capacity: Int) {
    precondition(capacity > 0)
    self.capacity = capacity
  }

  func presentation(
    language: String,
    source: String,
    load: (String, String) throws -> ToolPresentation = nativeCodePresentation
  ) rethrows -> ToolPresentation {
    let key = Key(language: language, source: source)
    if let cached = entries[key] {
      return cached
    }
    let value = try load(language, source)
    if entries.count == capacity, let oldest = insertionOrder.first {
      entries.removeValue(forKey: oldest)
      insertionOrder.removeFirst()
    }
    entries[key] = value
    insertionOrder.append(key)
    return value
  }

  func removeAll() {
    entries.removeAll(keepingCapacity: true)
    insertionOrder.removeAll(keepingCapacity: true)
  }
}

@MainActor
func markdownBlocks(
  _ text: String,
  codePresentationCache: CodePresentationCache = .shared,
  loadCodePresentation: (String, String) throws -> ToolPresentation = nativeCodePresentation
) -> [MarkdownBlock] {
  guard
    let rendered = try? AttributedString(
      markdown: text,
      options: .init(interpretedSyntax: .full)
    )
  else {
    return [.init(kind: .paragraph, content: AttributedString(text))]
  }

  var blocks: [MarkdownBlock] = []
  var blockIdentity: Int?

  for run in rendered.runs {
    let components = Array(run.presentationIntent?.components ?? [])
    let identity = components.first?.identity
    let content = AttributedString(rendered[run.range])

    if identity == blockIdentity, !blocks.isEmpty {
      blocks[blocks.count - 1].content.append(content)
      continue
    }

    blockIdentity = identity
    blocks.append(.init(kind: markdownBlockKind(components), content: content))
  }

  if !blocks.isEmpty {
    for index in blocks.indices {
      guard case .code(let language) = blocks[index].kind else { continue }
      blocks[index].codePresentation = try? codePresentationCache.presentation(
        language: language ?? "",
        source: String(blocks[index].content.characters),
        load: loadCodePresentation)
    }
  }

  return blocks.isEmpty
    ? [.init(kind: .paragraph, content: AttributedString(text))]
    : blocks
}

private func markdownBlockKind(
  _ components: [PresentationIntent.IntentType]
) -> MarkdownBlockKind {
  var listItemOrdinal: Int?
  var isUnorderedList = false
  var isOrderedList = false
  var isQuote = false

  for component in components {
    switch component.kind {
    case .header(let level):
      return .heading(level: level)
    case .codeBlock(let language):
      return .code(language: language)
    case .thematicBreak:
      return .thematicBreak
    case .listItem(let ordinal):
      listItemOrdinal = ordinal
    case .unorderedList:
      isUnorderedList = true
    case .orderedList:
      isOrderedList = true
    case .blockQuote:
      isQuote = true
    default:
      break
    }
  }

  if let ordinal = listItemOrdinal {
    if isOrderedList {
      return .orderedListItem(ordinal: ordinal)
    }
    if isUnorderedList {
      return .unorderedListItem
    }
  }
  return isQuote ? .quote : .paragraph
}

enum NativeEventDecodingError: Error {
  case malformed
}

enum NativeEventDecoder {
  static func decode(
    _ event: vivi_backend_event_t,
    bytes: [UInt8],
    models: [vivi_backend_model_t],
    semanticSpans: [vivi_backend_semantic_span_t] = [],
    sessions: [vivi_backend_session_summary_t] = [],
    transcriptItems: [vivi_backend_transcript_item_t] = [],
    userInputChoices: [vivi_backend_user_input_choice_t] = []
  ) throws -> ChatEvent {
    guard event.reserved == 0, event.event_reserved == 0, event.allow_freeform <= 1,
      bytes.count == Int(event.byte_count),
      models.count == Int(event.model_count),
      semanticSpans.count == Int(event.semantic_span_count),
      sessions.count == Int(event.session_count),
      transcriptItems.count == Int(event.transcript_item_count),
      userInputChoices.count == Int(event.user_input_choice_count)
    else { throw NativeEventDecodingError.malformed }

    func text(_ span: vivi_backend_span_t) throws -> String {
      let value = try data(span)
      guard let value = String(data: value, encoding: .utf8) else {
        throw NativeEventDecodingError.malformed
      }
      return value
    }

    func data(_ span: vivi_backend_span_t) throws -> Data {
      let start = Int(span.offset)
      let length = Int(span.length)
      guard start <= bytes.count, length <= bytes.count - start else {
        throw NativeEventDecodingError.malformed
      }
      return Data(bytes[start..<(start + length)])
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
      let advertised: ReasoningEffort?
      if raw.advertised_default_reasoning == Int8(VIVI_BACKEND_REASONING_NONE.rawValue) {
        advertised = nil
      } else {
        guard
          let value = ReasoningEffort(rawValue: Int32(raw.advertised_default_reasoning))
        else { throw NativeEventDecodingError.malformed }
        advertised = value
      }
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

    func zero(_ span: vivi_backend_span_t) -> Bool {
      span.offset == 0 && span.length == 0
    }

    func canonicalSessionTitle(_ span: vivi_backend_span_t) throws -> String {
      let value = try text(span)
      let scalars = value.unicodeScalars
      guard
        !scalars.isEmpty,
        scalars.count <= Int(VIVI_BACKEND_SESSION_TITLE_MAX_CHARACTERS)
      else {
        throw NativeEventDecodingError.malformed
      }

      var previousWasSpace = true
      for scalar in scalars {
        let scalarValue = scalar.value
        guard
          scalarValue > 0x1f,
          scalarValue < 0x7f || scalarValue > 0x9f,
          scalarValue != 0x061c,
          scalarValue < 0x200e || scalarValue > 0x200f,
          scalarValue < 0x202a || scalarValue > 0x202e,
          scalarValue < 0x2066 || scalarValue > 0x2069
        else {
          throw NativeEventDecodingError.malformed
        }
        if scalar.properties.isWhitespace {
          guard scalarValue == 0x20, !previousWasSpace else {
            throw NativeEventDecodingError.malformed
          }
          previousWasSpace = true
        } else {
          previousWasSpace = false
        }
      }
      guard !previousWasSpace else {
        throw NativeEventDecodingError.malformed
      }
      return value
    }

    func session(_ raw: vivi_backend_session_summary_t) throws -> SessionSummary {
      let knownFlags =
        UInt32(VIVI_BACKEND_SESSION_TITLE_PRESENT.rawValue)
        | UInt32(VIVI_BACKEND_SESSION_CURRENT.rawValue)
      guard raw.reserved == 0, raw.flags & ~knownFlags == 0,
        raw.key.generation != 0, raw.key.reserved == 0
      else { throw NativeEventDecodingError.malformed }
      let workingDirectory = try text(raw.working_directory)
      guard !workingDirectory.isEmpty, workingDirectory.hasPrefix("/") else {
        throw NativeEventDecodingError.malformed
      }
      let hasTitle = raw.flags & UInt32(VIVI_BACKEND_SESSION_TITLE_PRESENT.rawValue) != 0
      guard hasTitle || zero(raw.title) else {
        throw NativeEventDecodingError.malformed
      }
      return SessionSummary(
        key: ResumeKey(
          generation: raw.key.generation,
          slot: raw.key.slot),
        workingDirectory: workingDirectory,
        title: hasTitle ? try canonicalSessionTitle(raw.title) : nil,
        isCurrent: raw.flags & UInt32(VIVI_BACKEND_SESSION_CURRENT.rawValue) != 0)
    }

    func transcriptItem(_ raw: vivi_backend_transcript_item_t) throws -> TranscriptSnapshotItem {
      guard raw.reserved == 0 else { throw NativeEventDecodingError.malformed }
      let value = try text(raw.text)
      switch raw.role {
      case VIVI_BACKEND_TRANSCRIPT_USER: return .user(value)
      case VIVI_BACKEND_TRANSCRIPT_ASSISTANT: return .assistant(value)
      case VIVI_BACKEND_TRANSCRIPT_REASONING: return .reasoning(value)
      default: throw NativeEventDecodingError.malformed
      }
    }

    func presentation(
      _ raw: vivi_backend_presentation_t,
      required: Bool
    ) throws -> ToolPresentation? {
      guard raw.reserved == 0 else { throw NativeEventDecodingError.malformed }
      if raw.kind == VIVI_BACKEND_PRESENTATION_NONE {
        guard !required, raw.content.offset == 0, raw.content.length == 0,
          raw.language == VIVI_BACKEND_LANGUAGE_NONE,
          raw.semantic_span_offset == 0, raw.semantic_span_count == 0
        else { throw NativeEventDecodingError.malformed }
        return nil
      }
      guard required else { throw NativeEventDecodingError.malformed }
      let contentStart = Int(raw.content.offset)
      let contentLength = Int(raw.content.length)
      let contentEnd = contentStart + contentLength
      guard contentStart <= bytes.count, contentLength <= bytes.count - contentStart,
        let value = String(bytes: bytes[contentStart..<contentEnd], encoding: .utf8)
      else { throw NativeEventDecodingError.malformed }
      let spanStart = Int(raw.semantic_span_offset)
      let spanCount = Int(raw.semantic_span_count)
      guard spanStart <= semanticSpans.count, spanCount <= semanticSpans.count - spanStart
      else { throw NativeEventDecodingError.malformed }

      switch raw.kind {
      case VIVI_BACKEND_PRESENTATION_LITERAL:
        guard raw.language == VIVI_BACKEND_LANGUAGE_NONE, spanCount == 0 else {
          throw NativeEventDecodingError.malformed
        }
        return .literal(value)
      case VIVI_BACKEND_PRESENTATION_MARKDOWN:
        guard raw.language == VIVI_BACKEND_LANGUAGE_NONE, spanCount == 0 else {
          throw NativeEventDecodingError.malformed
        }
        return .markdown(value)
      case VIVI_BACKEND_PRESENTATION_SOURCE:
        guard
          let language = PresentationLanguage(rawValue: Int32(raw.language.rawValue))
        else { throw NativeEventDecodingError.malformed }
        var decoded: [SemanticSpan] = []
        var previousEnd = contentStart
        for item in semanticSpans[spanStart..<(spanStart + spanCount)] {
          guard item.reserved == 0,
            let token = SemanticToken(rawValue: Int32(item.token.rawValue))
          else { throw NativeEventDecodingError.malformed }
          let start = Int(item.bytes.offset)
          let length = Int(item.bytes.length)
          let end = start + length
          guard length > 0, start >= contentStart, start >= previousEnd,
            end <= contentEnd,
            isUTF8Boundary(bytes, at: start),
            isUTF8Boundary(bytes, at: end)
          else { throw NativeEventDecodingError.malformed }
          decoded.append(
            SemanticSpan(
              byteRange: (start - contentStart)..<(end - contentStart),
              token: token))
          previousEnd = end
        }
        return .source(text: value, language: language, spans: decoded)
      default:
        throw NativeEventDecodingError.malformed
      }
    }

    guard event.default_saved <= 1, event.cleanup_failed <= 1 else {
      throw NativeEventDecodingError.malformed
    }
    let isSessionPayload =
      event.kind == VIVI_BACKEND_EVENT_SESSION_CATALOG
      || event.kind == VIVI_BACKEND_EVENT_SESSION_RESUME
    if !isSessionPayload {
      guard sessions.isEmpty, transcriptItems.isEmpty,
        event.session_resume_outcome == VIVI_BACKEND_SESSION_RESUME_NONE
      else { throw NativeEventDecodingError.malformed }
    }
    let isUserInputPayload = event.kind == VIVI_BACKEND_EVENT_USER_INPUT_REQUEST
    if !isUserInputPayload {
      guard userInputChoices.isEmpty, event.allow_freeform == 0,
        zero(event.user_input_request_id), zero(event.user_input_question)
      else { throw NativeEventDecodingError.malformed }
    }
    func content() throws -> String {
      try text(event.content)
    }
    let inputPresentation = try presentation(
      event.tool_input_presentation,
      required: event.kind == VIVI_BACKEND_EVENT_TOOL_STARTED)
    let outputPresentation = try presentation(
      event.tool_output_presentation,
      required: event.kind == VIVI_BACKEND_EVENT_TOOL_FINISHED)
    let hasNeutralConversationMetadata =
      zero(event.selected_model_id)
      && zero(event.tool_call_id)
      && zero(event.tool_title)
      && zero(event.tool_detail)
      && zero(event.tool_input)
      && event.tool_result == VIVI_BACKEND_TOOL_RESULT_NONE
      && event.selected_reasoning == VIVI_BACKEND_REASONING_NONE
      && event.switch_outcome == VIVI_BACKEND_MODEL_SWITCH_NONE
      && event.history_effect == VIVI_BACKEND_HISTORY_NONE
    if event.kind == VIVI_BACKEND_EVENT_TOOL_STARTED {
      guard event.tool_input_presentation.semantic_span_offset == 0,
        event.tool_input_presentation.semantic_span_count == event.semantic_span_count
      else { throw NativeEventDecodingError.malformed }
    } else if event.kind == VIVI_BACKEND_EVENT_TOOL_FINISHED {
      guard event.tool_output_presentation.semantic_span_offset == 0,
        event.tool_output_presentation.semantic_span_count == event.semantic_span_count
      else { throw NativeEventDecodingError.malformed }
    } else {
      guard event.semantic_span_count == 0 else {
        throw NativeEventDecodingError.malformed
      }
    }
    switch event.kind {
    case VIVI_BACKEND_EVENT_READY: return .ready
    case VIVI_BACKEND_EVENT_STATUS: return .status(try content())
    case VIVI_BACKEND_EVENT_SESSION_TITLE:
      guard event.content_kind == VIVI_BACKEND_CONTENT_TEXT else {
        throw NativeEventDecodingError.malformed
      }
      return .sessionTitle(try canonicalSessionTitle(event.content))
    case VIVI_BACKEND_EVENT_ASSISTANT_STARTED: return .assistantStarted
    case VIVI_BACKEND_EVENT_REASONING_DELTA: return .reasoningDelta(try content())
    case VIVI_BACKEND_EVENT_REASONING_COMPLETE: return .reasoningComplete(try content())
    case VIVI_BACKEND_EVENT_ASSISTANT_DELTA: return .assistantDelta(try content())
    case VIVI_BACKEND_EVENT_ASSISTANT_COMPLETE: return .assistantComplete(try content())
    case VIVI_BACKEND_EVENT_TOOL_STARTED:
      guard event.content_kind == VIVI_BACKEND_CONTENT_TOOL,
        event.tool_result == VIVI_BACKEND_TOOL_RESULT_RUNNING
      else { throw NativeEventDecodingError.malformed }
      let callID = try text(event.tool_call_id)
      let title = try text(event.tool_title)
      guard !callID.isEmpty, !title.isEmpty else {
        throw NativeEventDecodingError.malformed
      }
      return .toolStarted(
        ToolActivity(
          callID: callID,
          title: title,
          detail: try text(event.tool_detail),
          input: try text(event.tool_input),
          inputPresentation: inputPresentation!,
          result: .running,
          output: nil,
          outputPresentation: nil))
    case VIVI_BACKEND_EVENT_TOOL_FINISHED:
      guard event.content_kind == VIVI_BACKEND_CONTENT_TOOL else {
        throw NativeEventDecodingError.malformed
      }
      let callID = try text(event.tool_call_id)
      guard !callID.isEmpty else { throw NativeEventDecodingError.malformed }
      let result: ToolResultState
      switch event.tool_result {
      case VIVI_BACKEND_TOOL_RESULT_SUCCEEDED: result = .succeeded
      case VIVI_BACKEND_TOOL_RESULT_FAILED: result = .failed
      case VIVI_BACKEND_TOOL_RESULT_IMAGE: result = .image
      default: throw NativeEventDecodingError.malformed
      }
      return .toolFinished(
        callID: callID,
        result: result,
        output: try data(event.content),
        presentation: outputPresentation!)
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
      return .modelCatalogFailure(try content())
    case VIVI_BACKEND_EVENT_MODEL_SWITCH:
      guard event.content_kind == VIVI_BACKEND_CONTENT_MODEL_SWITCH else {
        throw NativeEventDecodingError.malformed
      }
      if event.switch_outcome == VIVI_BACKEND_MODEL_SWITCH_FAILED {
        guard models.isEmpty else { throw NativeEventDecodingError.malformed }
        return .modelSwitch(.failed(try content()))
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
    case VIVI_BACKEND_EVENT_SESSION_CATALOG:
      guard event.content_kind == VIVI_BACKEND_CONTENT_SESSION_CATALOG,
        models.isEmpty, semanticSpans.isEmpty, transcriptItems.isEmpty,
        event.session_resume_outcome == VIVI_BACKEND_SESSION_RESUME_NONE,
        event.default_saved == 0, event.cleanup_failed == 0, zero(event.content),
        hasNeutralConversationMetadata
      else { throw NativeEventDecodingError.malformed }
      let decoded = try sessions.map(session)
      if let generation = decoded.first?.key.generation {
        guard decoded.allSatisfy({ $0.key.generation == generation })
        else { throw NativeEventDecodingError.malformed }
      }
      guard Set(decoded.map(\.key)).count == decoded.count else {
        throw NativeEventDecodingError.malformed
      }
      return .sessionCatalog(SessionCatalog(sessions: decoded))
    case VIVI_BACKEND_EVENT_SESSION_CATALOG_FAILURE:
      guard event.content_kind == VIVI_BACKEND_CONTENT_TEXT,
        models.isEmpty, semanticSpans.isEmpty,
        event.default_saved == 0, event.cleanup_failed == 0,
        hasNeutralConversationMetadata
      else { throw NativeEventDecodingError.malformed }
      let message = try content()
      guard !message.isEmpty else { throw NativeEventDecodingError.malformed }
      return .sessionCatalogFailure(message)
    case VIVI_BACKEND_EVENT_SESSION_RESUME:
      guard event.content_kind == VIVI_BACKEND_CONTENT_SESSION_RESUME,
        models.isEmpty, semanticSpans.isEmpty,
        event.default_saved == 0, hasNeutralConversationMetadata
      else { throw NativeEventDecodingError.malformed }
      switch event.session_resume_outcome {
      case VIVI_BACKEND_SESSION_RESUME_FAILED:
        guard sessions.isEmpty, transcriptItems.isEmpty, event.cleanup_failed == 0
        else { throw NativeEventDecodingError.malformed }
        let message = try content()
        guard !message.isEmpty else { throw NativeEventDecodingError.malformed }
        return .sessionResume(.failed(message))
      case VIVI_BACKEND_SESSION_RESUME_RESUMED:
        guard sessions.count == 1, zero(event.content) else {
          throw NativeEventDecodingError.malformed
        }
        let summary = try session(sessions[0])
        return .sessionResume(
          .resumed(
            ResumedSession(
              summary: summary,
              transcript: try transcriptItems.map(transcriptItem),
              cleanupFailed: event.cleanup_failed != 0)))
      default:
        throw NativeEventDecodingError.malformed
      }
    case VIVI_BACKEND_EVENT_USER_INPUT_REQUEST:
      guard event.content_kind == VIVI_BACKEND_CONTENT_USER_INPUT_REQUEST,
        models.isEmpty, semanticSpans.isEmpty, sessions.isEmpty, transcriptItems.isEmpty,
        event.default_saved == 0, event.cleanup_failed == 0, zero(event.content),
        hasNeutralConversationMetadata
      else { throw NativeEventDecodingError.malformed }
      let requestID = try text(event.user_input_request_id)
      let question = try text(event.user_input_question)
      let choiceBytes = try userInputChoices.map { raw in
        guard raw.reserved == 0 else { throw NativeEventDecodingError.malformed }
        let value = try data(raw.text)
        let isBlank = value.allSatisfy { byte in
          byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
        }
        guard !value.isEmpty, !isBlank, String(data: value, encoding: .utf8) != nil else {
          throw NativeEventDecodingError.malformed
        }
        return value
      }
      let choices = choiceBytes.map { String(decoding: $0, as: UTF8.self) }
      let allowsFreeform = event.allow_freeform != 0
      guard !requestID.isEmpty, !question.isEmpty,
        Set(choiceBytes).count == choiceBytes.count,
        !choices.isEmpty || allowsFreeform
      else { throw NativeEventDecodingError.malformed }
      return .userInputRequested(
        UserInputRequest(
          id: requestID,
          question: question,
          choices: choices,
          allowsFreeform: allowsFreeform))
    case VIVI_BACKEND_EVENT_IDLE: return .idle
    case VIVI_BACKEND_EVENT_FAILURE: return .failure(try content())
    case VIVI_BACKEND_EVENT_CLOSED: return .closed
    default: throw NativeEventDecodingError.malformed
    }
  }
}

func sanitizedToolMarkdown(_ text: String) throws -> String {
  let input = Array(text.utf8)
  var required: UInt32 = 0
  let probe = input.withUnsafeBufferPointer {
    vivi_backend_sanitize_tool_markdown(
      $0.baseAddress,
      UInt32($0.count),
      nil,
      0,
      &required)
  }

  guard probe == VIVI_BACKEND_BUFFER_TOO_SMALL || (probe == VIVI_BACKEND_OK && required == 0)
  else { throw NativeEventDecodingError.malformed }
  if required == 0 { return "" }

  var output = [UInt8](repeating: 0, count: Int(required))
  let copied = input.withUnsafeBufferPointer { inputBuffer in
    output.withUnsafeMutableBufferPointer { outputBuffer in
      vivi_backend_sanitize_tool_markdown(
        inputBuffer.baseAddress,
        UInt32(inputBuffer.count),
        outputBuffer.baseAddress,
        UInt32(outputBuffer.count),
        &required)
    }
  }
  guard copied == VIVI_BACKEND_OK,
    let sanitized = String(bytes: output, encoding: .utf8)
  else { throw NativeEventDecodingError.malformed }
  return sanitized
}

func nativeCodePresentation(language: String, source: String) throws -> ToolPresentation {
  let languageBytes = Array(language.utf8)
  let sourceBytes = Array(source.utf8)
  guard languageBytes.count <= Int(UInt32.max), sourceBytes.count <= Int(UInt32.max) else {
    throw NativeEventDecodingError.malformed
  }
  var descriptor = vivi_backend_presentation_t()
  let probe = languageBytes.withUnsafeBufferPointer { languageBuffer in
    sourceBytes.withUnsafeBufferPointer { sourceBuffer in
      vivi_backend_present_code_fragment(
        languageBuffer.baseAddress, UInt32(languageBuffer.count),
        sourceBuffer.baseAddress, UInt32(sourceBuffer.count),
        &descriptor, nil, 0, nil, 0)
    }
  }
  guard
    probe == VIVI_BACKEND_BUFFER_TOO_SMALL
      || (probe == VIVI_BACKEND_OK && descriptor.content.length == 0
        && descriptor.semantic_span_count == 0)
  else { throw NativeEventDecodingError.malformed }

  var output = [UInt8](repeating: 0, count: Int(descriptor.content.length))
  var spans = [vivi_backend_semantic_span_t](
    repeating: vivi_backend_semantic_span_t(),
    count: Int(descriptor.semantic_span_count))
  let copied = languageBytes.withUnsafeBufferPointer { languageBuffer in
    sourceBytes.withUnsafeBufferPointer { sourceBuffer in
      output.withUnsafeMutableBufferPointer { outputBuffer in
        spans.withUnsafeMutableBufferPointer { spanBuffer in
          vivi_backend_present_code_fragment(
            languageBuffer.baseAddress, UInt32(languageBuffer.count),
            sourceBuffer.baseAddress, UInt32(sourceBuffer.count),
            &descriptor, outputBuffer.baseAddress, UInt32(outputBuffer.count),
            spanBuffer.baseAddress, UInt32(spanBuffer.count))
        }
      }
    }
  }
  guard copied == VIVI_BACKEND_OK, descriptor.reserved == 0,
    descriptor.content.offset == 0,
    descriptor.content.length == UInt32(output.count),
    descriptor.semantic_span_offset == 0,
    descriptor.semantic_span_count == UInt32(spans.count),
    let text = String(bytes: output, encoding: .utf8)
  else { throw NativeEventDecodingError.malformed }
  if descriptor.kind == VIVI_BACKEND_PRESENTATION_LITERAL {
    guard descriptor.language == VIVI_BACKEND_LANGUAGE_NONE, spans.isEmpty else {
      throw NativeEventDecodingError.malformed
    }
    return .literal(text)
  }
  guard descriptor.kind == VIVI_BACKEND_PRESENTATION_SOURCE,
    let decodedLanguage = PresentationLanguage(rawValue: Int32(descriptor.language.rawValue))
  else { throw NativeEventDecodingError.malformed }
  var decodedSpans: [SemanticSpan] = []
  var previousEnd = 0
  for span in spans {
    guard span.reserved == 0,
      let token = SemanticToken(rawValue: Int32(span.token.rawValue))
    else { throw NativeEventDecodingError.malformed }
    let start = Int(span.bytes.offset)
    let length = Int(span.bytes.length)
    let end = start + length
    guard length > 0, start >= previousEnd, end <= output.count,
      isUTF8Boundary(output, at: start),
      isUTF8Boundary(output, at: end)
    else { throw NativeEventDecodingError.malformed }
    decodedSpans.append(.init(byteRange: start..<end, token: token))
    previousEnd = end
  }
  return .source(text: text, language: decodedLanguage, spans: decodedSpans)
}

private func isUTF8Boundary(_ bytes: [UInt8], at index: Int) -> Bool {
  index == bytes.count || bytes[index] & 0xC0 != 0x80
}

func nativeCopilotExecutableCandidates(home: URL, path: String?) -> [String] {
  var candidates =
    (path ?? "").split(separator: ":").map {
      URL(fileURLWithPath: String($0)).appendingPathComponent("copilot").path
    }
  candidates.append(contentsOf: [
    home.appendingPathComponent(".local/bin/copilot").path,
    home.appendingPathComponent(".npm-global/bin/copilot").path,
    home.appendingPathComponent(".volta/bin/copilot").path,
    "/opt/homebrew/bin/copilot",
    "/usr/local/bin/copilot",
  ])
  var seen: Set<String> = []
  return candidates.filter { seen.insert($0).inserted }
}

func nativeNodeVersionsNewestFirst(_ versions: [URL]) -> [URL] {
  versions.sorted {
    $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
  }
}

func nativeCopilotExecutablePath(
  fileManager: FileManager = .default,
  environment: [String: String] = ProcessInfo.processInfo.environment
) -> String? {
  let home = fileManager.homeDirectoryForCurrentUser
  var candidates = nativeCopilotExecutableCandidates(home: home, path: environment["PATH"])
  let nodeVersions = home.appendingPathComponent(".nvm/versions/node")
  if let versions = try? fileManager.contentsOfDirectory(
    at: nodeVersions,
    includingPropertiesForKeys: nil
  ) {
    candidates.append(
      contentsOf: nativeNodeVersionsNewestFirst(versions).map {
        $0.appendingPathComponent("bin/copilot").path
      })
  }
  return candidates.first { fileManager.isExecutableFile(atPath: $0) }
}

final class ViviConversationDriver: ViviConversationDriving, @unchecked Sendable {
  private let workspace: String
  private let applicationConfiguration: NativeApplicationConfiguration
  private let queue = DispatchQueue(label: "com.scaryrawr.vivi.conversation")
  private var handle: OpaquePointer?
  private var receive: (@MainActor (ChatEvent) -> Void)?

  init(
    workspace: String,
    applicationConfiguration: NativeApplicationConfiguration
  ) {
    self.workspace = workspace
    self.applicationConfiguration = applicationConfiguration
  }

  func start(
    receive: @escaping @MainActor (ChatEvent) -> Void
  ) -> ConversationOperationResult {
    queue.sync {
      self.receive = receive
      let bytes = Array(workspace.utf8)
      let settingsPath = applicationConfiguration.settingsPath
      guard let copilotPath = nativeCopilotExecutablePath() else {
        self.receive = nil
        return .failed
      }
      let settingsBytes = Array(settingsPath.utf8)
      let copilotBytes = Array(copilotPath.utf8)
      var options = vivi_backend_conversation_options_t(
        abi_version: UInt32(VIVI_BACKEND_ABI_VERSION),
        struct_size: UInt32(MemoryLayout<vivi_backend_conversation_options_t>.size),
        working_directory: nil,
        working_directory_length: UInt32(bytes.count),
        settings_path: nil,
        settings_path_length: UInt32(settingsBytes.count),
        copilot_cli_path: nil,
        copilot_cli_path_length: UInt32(copilotBytes.count),
        copilot_cli_launch: VIVI_BACKEND_COPILOT_CLI_EXPLICIT_PATH,
        wake: Self.wake,
        wake_context: Unmanaged.passUnretained(self).toOpaque()
      )
      let result = bytes.withUnsafeBufferPointer { buffer in
        settingsBytes.withUnsafeBufferPointer { settingsBuffer in
          copilotBytes.withUnsafeBufferPointer { copilotBuffer in
            options.working_directory = buffer.baseAddress
            options.settings_path = settingsBuffer.baseAddress
            options.copilot_cli_path = copilotBuffer.baseAddress
            return vivi_backend_open(&options, &handle)
          }
        }
      }
      guard result == VIVI_BACKEND_OK else {
        self.receive = nil
        return Self.operationResult(result)
      }
      return .accepted
    }
  }

  func submit(
    _ prompt: String,
    attachments: [ComposerAttachment]
  ) -> ConversationOperationResult {
    let promptBytes = Array(prompt.utf8)
    guard let promptLength = UInt32(exactly: promptBytes.count),
      let attachmentCount = UInt32(exactly: attachments.count)
    else { return .rejected }
    return queue.sync {
      guard let handle else { return .closed }
      var descriptors: [vivi_backend_submission_attachment_t] = []
      descriptors.reserveCapacity(attachments.count)
      return promptBytes.withUnsafeBufferPointer { promptBuffer in
        Self.withSubmissionAttachments(
          attachments[...],
          descriptors: &descriptors
        ) { descriptorBuffer in
          var submission = vivi_backend_submission_t()
          submission.struct_size = UInt32(MemoryLayout<vivi_backend_submission_t>.size)
          submission.prompt = promptBuffer.baseAddress
          submission.prompt_length = promptLength
          submission.attachments = descriptorBuffer.baseAddress
          submission.attachment_count = attachmentCount
          return Self.operationResult(vivi_backend_submit(handle, &submission))
        }
      }
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

  func refreshSessions() -> ConversationOperationResult {
    queue.sync {
      guard let handle else { return .closed }
      return Self.operationResult(vivi_backend_refresh_sessions(handle))
    }
  }

  func resumeSession(_ key: ResumeKey) -> ConversationOperationResult {
    queue.sync {
      guard let handle else { return .closed }
      return Self.operationResult(
        vivi_backend_resume_session(
          handle,
          vivi_backend_resume_key_t(
            generation: key.generation,
            slot: key.slot,
            reserved: 0)))
    }
  }

  func respondToUserInput(
    requestID: String,
    answer: UserInputAnswer
  ) -> ConversationOperationResult {
    let requestBytes = Array(requestID.utf8)
    let answerBytes = Array(answer.text.utf8)
    let answerKind: vivi_backend_user_input_answer_kind_t =
      switch answer {
      case .choice: VIVI_BACKEND_USER_INPUT_ANSWER_CHOICE
      case .freeform: VIVI_BACKEND_USER_INPUT_ANSWER_FREEFORM
      }
    return queue.sync {
      guard let handle else { return .closed }
      var response = vivi_backend_user_input_response_t()
      response.struct_size = UInt32(MemoryLayout<vivi_backend_user_input_response_t>.size)
      response.answer_kind = answerKind
      response.request_id_length = UInt32(requestBytes.count)
      response.answer_length = UInt32(answerBytes.count)
      return requestBytes.withUnsafeBufferPointer { requestBuffer in
        answerBytes.withUnsafeBufferPointer { answerBuffer in
          response.request_id = requestBuffer.baseAddress
          response.answer = answerBuffer.baseAddress
          return Self.userInputOperationResult(
            vivi_backend_respond_to_user_input(handle, &response))
        }
      }
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

  static func withSubmissionAttachments<Result>(
    _ attachments: ArraySlice<ComposerAttachment>,
    descriptors: inout [vivi_backend_submission_attachment_t],
    body: (UnsafeBufferPointer<vivi_backend_submission_attachment_t>) -> Result
  ) -> Result {
    guard let attachment = attachments.first else {
      return descriptors.withUnsafeBufferPointer(body)
    }
    let identity = Array(attachment.id.uuidString.utf8)
    let displayName = Array(attachment.displayName.utf8)
    return identity.withUnsafeBufferPointer { identityBuffer in
      displayName.withUnsafeBufferPointer { displayNameBuffer in
        attachment.data.withUnsafeBytes { rawBytes in
          let bytes = rawBytes.bindMemory(to: UInt8.self)
          var descriptor = vivi_backend_submission_attachment_t()
          descriptor.struct_size =
            UInt32(MemoryLayout<vivi_backend_submission_attachment_t>.size)
          descriptor.media_type = vivi_backend_attachment_media_type_t(
            rawValue: attachment.media.rawValue)
          descriptor.identity = identityBuffer.baseAddress
          descriptor.identity_length = UInt32(identityBuffer.count)
          descriptor.display_name = displayNameBuffer.baseAddress
          descriptor.display_name_length = UInt32(displayNameBuffer.count)
          descriptor.bytes = bytes.baseAddress
          descriptor.byte_length = UInt32(bytes.count)
          descriptors.append(descriptor)
          defer { descriptors.removeLast() }
          return withSubmissionAttachments(
            attachments.dropFirst(),
            descriptors: &descriptors,
            body: body)
        }
      }
    }
  }

  private func drainLocked() {
    guard let handle else { return }
    var events: [ChatEvent] = []
    while true {
      var event = vivi_backend_event_t()
      let result = vivi_backend_next_event(
        handle, &event, nil, 0, nil, 0, nil, 0, nil, 0, nil, 0, nil, 0)
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
      var semanticSpans = Array(
        repeating: vivi_backend_semantic_span_t(),
        count: Int(event.semantic_span_count))
      var sessions = Array(
        repeating: vivi_backend_session_summary_t(),
        count: Int(event.session_count))
      var transcriptItems = Array(
        repeating: vivi_backend_transcript_item_t(),
        count: Int(event.transcript_item_count))
      var userInputChoices = Array(
        repeating: vivi_backend_user_input_choice_t(),
        count: Int(event.user_input_choice_count))
      if result == VIVI_BACKEND_BUFFER_TOO_SMALL {
        let copied = bytes.withUnsafeMutableBufferPointer { byteBuffer in
          models.withUnsafeMutableBufferPointer { modelBuffer in
            semanticSpans.withUnsafeMutableBufferPointer { spanBuffer in
              sessions.withUnsafeMutableBufferPointer { sessionBuffer in
                transcriptItems.withUnsafeMutableBufferPointer { transcriptBuffer in
                  userInputChoices.withUnsafeMutableBufferPointer { choiceBuffer in
                    vivi_backend_next_event(
                      handle,
                      &event,
                      byteBuffer.baseAddress,
                      UInt32(byteBuffer.count),
                      modelBuffer.baseAddress,
                      UInt32(modelBuffer.count),
                      spanBuffer.baseAddress,
                      UInt32(spanBuffer.count),
                      sessionBuffer.baseAddress,
                      UInt32(sessionBuffer.count),
                      transcriptBuffer.baseAddress,
                      UInt32(transcriptBuffer.count),
                      choiceBuffer.baseAddress,
                      UInt32(choiceBuffer.count))
                  }
                }
              }
            }
          }
        }
        guard copied == VIVI_BACKEND_OK else {
          failDrain(handle, events: &events, message: "Could not copy a backend event.")
          return
        }
      }
      do {
        let decoded = try NativeEventDecoder.decode(
          event,
          bytes: bytes,
          models: models,
          semanticSpans: semanticSpans,
          sessions: sessions,
          transcriptItems: transcriptItems,
          userInputChoices: userInputChoices)
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

  static func operationResult(
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

  static func userInputOperationResult(
    _ result: vivi_backend_result_t
  ) -> ConversationOperationResult {
    if result == VIVI_BACKEND_INVALID_ARGUMENT {
      return .rejected
    }
    return operationResult(result)
  }
}
