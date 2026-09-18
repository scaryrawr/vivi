import ViviBackend
import XCTest

@testable import Vivi

@MainActor
final class ViviBackendRuntimeTests: XCTestCase {
  func testDockReopenUsesManagedChatWindowsRegardlessOfAppKitVisibility() {
    let windows = FakeChatWindowManager()
    let delegate = ViviAppDelegate(windows: windows)

    let shouldAlsoUseDefaultReopen = delegate.applicationShouldHandleReopen(
      NSApplication.shared,
      hasVisibleWindows: true)

    XCTAssertFalse(shouldAlsoUseDefaultReopen)
    XCTAssertEqual(windows.reopenCount, 1)
  }

  func testLaunchingWithoutAChatURLOpensTheMainWindow() {
    let windows = FakeChatWindowManager()
    let delegate = ViviAppDelegate(windows: windows)

    XCTAssertTrue(delegate.applicationOpenUntitledFile(NSApplication.shared))
    XCTAssertEqual(windows.reopenCount, 1)
  }

  func testWindowRegistryReusesAnOpenWindow() {
    let factory = FakeChatWindowFactory()
    let registry = ChatWindowRegistry(
      homeDirectory: "/Users/test",
      makeController: factory.makeController)

    registry.open(request: NativeChatRequest(workspace: "/tmp/project"))
    registry.reopenLast()

    XCTAssertEqual(factory.controllers.count, 1)
    XCTAssertEqual(factory.controllers[0].workspace, "/tmp/project")
    XCTAssertEqual(factory.controllers[0].restoreCount, 2)
  }

  func testWindowRegistryReplacesAClosingWindowWithTheLastRequest() {
    let factory = FakeChatWindowFactory()
    let registry = ChatWindowRegistry(
      homeDirectory: "/Users/test",
      makeController: factory.makeController)

    registry.open(request: NativeChatRequest(workspace: "/tmp/project"))
    factory.controllers[0].isClosing = true
    registry.reopenLast()

    XCTAssertEqual(factory.controllers.map(\.workspace), ["/tmp/project", "/tmp/project"])
    XCTAssertEqual(factory.controllers.map(\.restoreCount), [1, 1])
  }

  func testWindowRegistryUsesTheHomeDirectoryWithoutAPriorRequest() {
    let factory = FakeChatWindowFactory()
    let registry = ChatWindowRegistry(
      homeDirectory: "/Users/test",
      makeController: factory.makeController)

    registry.reopenLast()

    XCTAssertEqual(factory.controllers.count, 1)
    XCTAssertEqual(factory.controllers[0].workspace, "/Users/test")
    XCTAssertEqual(factory.controllers[0].restoreCount, 1)
  }

  func testWindowRegistryRemovesClosedWindowsAndReopensTheirWorkspace() {
    let factory = FakeChatWindowFactory()
    let registry = ChatWindowRegistry(
      homeDirectory: "/Users/test",
      makeController: factory.makeController)

    registry.open(request: NativeChatRequest(workspace: "/tmp/project"))
    factory.controllers[0].closeForTermination {}
    XCTAssertTrue(registry.isEmpty)

    registry.reopenLast()

    XCTAssertEqual(factory.controllers.map(\.workspace), ["/tmp/project", "/tmp/project"])
    XCTAssertEqual(factory.controllers[1].restoreCount, 1)
  }

  func testRestoreWindowDeminiaturizesTheWindow() {
    let window = MiniaturizedTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
      styleMask: [.titled, .miniaturizable],
      backing: .buffered,
      defer: false)
    let controller = NSWindowController(window: window)
    XCTAssertTrue(window.isMiniaturized)

    restoreWindow(controller)

    XCTAssertFalse(window.isMiniaturized)
    XCTAssertEqual(window.deminiaturizeCount, 1)
    window.close()
  }

  func testReducerCreatesAssistantLazilyAfterReasoning() {
    let driver = FakeConversationDriver()
    let store = NativeChatStore(workspace: "/tmp/Vivi chat", driver: driver)

    store.reduce(.ready)
    store.reduce(.modelCatalog(testCatalog()))
    store.draft = "Write a haiku"
    store.submit()
    store.reduce(.assistantStarted)
    XCTAssertEqual(store.transcript.count, 2)
    store.reduce(.reasoningComplete("finished thought"))
    store.reduce(.assistantDelta("old "))
    store.reduce(.assistantComplete("new answer"))
    store.reduce(.idle)

    XCTAssertEqual(store.lifecycle, .idle)
    XCTAssertEqual(
      store.transcript,
      [
        .user(id: store.transcript[0].id, text: "Write a haiku"),
        .assistantHeader(id: store.transcript[1].id),
        .reasoning(id: store.transcript[2].id, text: "finished thought"),
        .assistant(id: store.transcript[3].id, text: "new answer"),
      ])
  }

  @MainActor
  private final class FakeChatWindowManager: ChatWindowManaging {
    var isEmpty = true
    var reopenCount = 0

    func open(request: NativeChatRequest) {}

    func reopenLast() {
      reopenCount += 1
    }

    func closeAll(completion: @escaping @MainActor () -> Void) {
      completion()
    }
  }

  @MainActor
  private final class FakeChatWindowFactory {
    var controllers: [FakeChatWindowController] = []

    func makeController(
      id: UUID,
      workspace: String,
      onClosed: @escaping @MainActor (UUID) -> Void
    ) -> any ChatWindowControlling {
      let controller = FakeChatWindowController(
        id: id,
        workspace: workspace,
        onClosed: onClosed)
      controllers.append(controller)
      return controller
    }
  }

  @MainActor
  private final class FakeChatWindowController: ChatWindowControlling {
    let id: UUID
    let workspace: String
    var isClosing = false
    var restoreCount = 0
    private let onClosed: @MainActor (UUID) -> Void

    init(
      id: UUID,
      workspace: String,
      onClosed: @escaping @MainActor (UUID) -> Void
    ) {
      self.id = id
      self.workspace = workspace
      self.onClosed = onClosed
    }

    func restore() {
      restoreCount += 1
    }

    func closeForTermination(completion: @escaping @MainActor () -> Void) {
      isClosing = true
      onClosed(id)
      completion()
    }
  }

  final class MiniaturizedTestWindow: NSWindow {
    var deminiaturizeCount = 0
    private var reportedMiniaturized = true

    override var isMiniaturized: Bool {
      reportedMiniaturized
    }

    override func deminiaturize(_ sender: Any?) {
      deminiaturizeCount += 1
      reportedMiniaturized = false
    }
  }

  func testBusySubmitPreservesDraft() {
    let driver = FakeConversationDriver()
    driver.submitResult = .busy
    let store = NativeChatStore(
      workspace: "/tmp/work",
      driver: driver
    )

    store.reduce(.ready)
    store.reduce(.modelCatalog(testCatalog()))
    store.draft = "Keep this"
    store.submit()

    XCTAssertEqual(store.draft, "Keep this")
    XCTAssertEqual(
      store.transcript,
      [.status(id: store.transcript[0].id, text: "Chat is busy.")])
  }

  func testFailureIsVisibleUntilClosed() {
    let store = NativeChatStore(
      workspace: "/tmp/work",
      driver: FakeConversationDriver()
    )

    store.reduce(.failure("No credentials"))
    store.reduce(.closed)

    XCTAssertEqual(
      store.transcript,
      [.failure(id: store.transcript[0].id, text: "No credentials")])
    XCTAssertEqual(store.lifecycle, .closed)
  }

  func testConsecutiveReasoningCompletionsCoalesce() {
    let store = NativeChatStore(
      workspace: "/tmp/work",
      driver: FakeConversationDriver()
    )

    store.reduce(.assistantStarted)
    store.reduce(.reasoningComplete("first"))
    store.reduce(.reasoningComplete("second"))

    XCTAssertEqual(
      store.transcript,
      [
        .assistantHeader(id: store.transcript[0].id),
        .reasoning(id: store.transcript[1].id, text: "first\n\nsecond"),
      ])
  }

  func testConsecutiveReasoningDeltaBlocksKeepParagraphBreak() {
    let store = NativeChatStore(workspace: "/tmp/work", driver: FakeConversationDriver())

    store.reduce(.assistantStarted)
    store.reduce(.reasoningComplete("first"))
    store.reduce(.reasoningDelta("sec"))
    store.reduce(.reasoningDelta("ond"))
    store.reduce(.reasoningComplete("second"))

    XCTAssertEqual(
      store.transcript,
      [
        .assistantHeader(id: store.transcript[0].id),
        .reasoning(id: store.transcript[1].id, text: "first\n\nsecond"),
      ])
  }

  func testToolBetweenReasoningBlocksPreservesChronology() {
    let store = NativeChatStore(workspace: "/tmp/work", driver: FakeConversationDriver())
    let tool = ToolActivity(
      callID: "call-1",
      title: "Read file",
      detail: "README.md",
      input: #"{"path":"README.md"}"#,
      result: .running,
      output: "")

    store.reduce(.assistantStarted)
    store.reduce(.reasoningComplete("before"))
    store.reduce(.toolStarted(tool))
    store.reduce(.reasoningComplete("after"))
    store.reduce(.assistantComplete("answer"))

    XCTAssertEqual(store.transcript.count, 5)
    guard case .assistantHeader = store.transcript[0],
      case .reasoning(_, "before") = store.transcript[1],
      case .tool(_, let inserted) = store.transcript[2],
      case .reasoning(_, "after") = store.transcript[3],
      case .assistant(_, "answer") = store.transcript[4]
    else { return XCTFail("Expected header, reasoning, tool, reasoning, assistant order") }
    XCTAssertEqual(inserted, tool)
  }

  func testEmptyToolRequestCompletionDoesNotCreateAssistantRow() {
    let store = NativeChatStore(workspace: "/tmp/work", driver: FakeConversationDriver())
    let tool = ToolActivity(
      callID: "call-1",
      title: "Read file",
      detail: "README.md",
      input: #"{"path":"README.md"}"#,
      result: .running,
      output: "")

    store.reduce(.assistantStarted)
    store.reduce(.assistantComplete(""))
    store.reduce(.toolStarted(tool))
    store.reduce(.toolFinished(callID: "call-1", result: .succeeded, output: "contents"))
    store.reduce(.assistantDelta("done"))
    store.reduce(.assistantComplete("done"))

    XCTAssertEqual(store.transcript.count, 3)
    guard case .assistantHeader = store.transcript[0],
      case .tool(_, let finished) = store.transcript[1],
      case .assistant(_, "done") = store.transcript[2]
    else { return XCTFail("Expected header and tool followed by assistant without an empty row") }
    XCTAssertEqual(finished.output, "contents")
    XCTAssertEqual(finished.result, .succeeded)
  }

  func testLeadingWhitespaceDeltaDoesNotCreateAssistantRowBeforeReasoning() {
    let store = NativeChatStore(workspace: "/tmp/work", driver: FakeConversationDriver())

    store.reduce(.assistantStarted)
    store.reduce(.assistantDelta("\n"))
    store.reduce(.reasoningComplete("thinking"))
    store.reduce(.assistantComplete("answer"))

    XCTAssertEqual(store.transcript.count, 3)
    guard case .assistantHeader = store.transcript[0],
      case .reasoning(_, "thinking") = store.transcript[1],
      case .assistant(_, "answer") = store.transcript[2]
    else { return XCTFail("Expected header and reasoning before the assistant content") }
  }

  func testToolFinishUpdatesOriginalRowByCallID() {
    let store = NativeChatStore(workspace: "/tmp/work", driver: FakeConversationDriver())
    let tool = ToolActivity(
      callID: "call-1",
      title: "Run command",
      detail: "zig build test",
      input: #"{"command":"zig build test"}"#,
      result: .running,
      output: "")
    store.reduce(.toolStarted(tool))
    let originalID = store.transcript[0].id

    store.reduce(.toolFinished(callID: "call-1", result: .succeeded, output: "**passed**"))

    XCTAssertEqual(store.transcript.count, 1)
    XCTAssertEqual(store.transcript[0].id, originalID)
    guard case .tool(_, let finished) = store.transcript[0] else {
      return XCTFail("Expected tool row")
    }
    XCTAssertEqual(finished.result, .succeeded)
    XCTAssertEqual(finished.output, "**passed**")
  }

  func testMarkdownRendererPreservesBlockStructureAndInlineFormatting() {
    let rendered = markdownBlocks(
      """
      ## Structure

      **Core**
      - `backend/` — domain
      - `cli/` — terminal
      """)

    XCTAssertEqual(
      rendered.map(\.kind),
      [.heading(level: 2), .paragraph, .unorderedListItem, .unorderedListItem])
    XCTAssertEqual(
      rendered.map { String($0.content.characters) },
      ["Structure", "Core", "backend/ — domain", "cli/ — terminal"])
    XCTAssertFalse(rendered.map { String($0.content.characters) }.joined().contains("**"))
  }

  func testRefreshFailureRetainsCatalogAndFailedSwitchRetainsSelection() {
    let driver = FakeConversationDriver()
    let store = NativeChatStore(workspace: "/tmp/work", driver: driver)
    let catalog = testCatalog()
    store.reduce(.modelCatalog(catalog))

    store.refreshModels()
    XCTAssertEqual(store.modelState, .refreshing)
    store.reduce(.modelCatalogFailure("offline"))
    XCTAssertEqual(store.catalog, catalog)
    XCTAssertEqual(store.confirmedSelection, catalog.selected)
    XCTAssertEqual(store.modelState, .ready)

    store.selectReasoning(.high)
    XCTAssertEqual(store.modelState, .switching)
    store.reduce(.modelSwitch(.failed("unavailable")))
    XCTAssertEqual(store.confirmedSelection, catalog.selected)
    XCTAssertEqual(store.modelState, .ready)
  }

  func testInitialCatalogFailureCanBeRefreshed() {
    let store = NativeChatStore(workspace: "/tmp/work", driver: FakeConversationDriver())

    store.reduce(.modelCatalogFailure("offline"))
    XCTAssertNil(store.catalog)
    XCTAssertEqual(store.modelState, .ready)

    store.refreshModels()
    XCTAssertEqual(store.modelState, .refreshing)
  }

  func testCombinedModelChoiceSubmitsOneValidSelection() {
    let driver = FakeConversationDriver()
    let store = NativeChatStore(workspace: "/tmp/work", driver: driver)
    store.reduce(.modelCatalog(testCatalog()))

    store.select(modelID: "copilot/gpt-5", reasoning: .high)

    XCTAssertEqual(
      driver.selections,
      [ModelSelection(modelID: "copilot/gpt-5", reasoning: .high)])
    XCTAssertEqual(store.modelState, .switching)
  }

  func testCatalogRepresentsActiveSelectionMissingFromDiscovery() {
    let store = NativeChatStore(workspace: "/tmp/work", driver: FakeConversationDriver())
    let catalog = ModelCatalog(
      selected: ModelSelection(modelID: "copilot/retired", reasoning: .medium),
      models: testCatalog().models)

    store.reduce(.modelCatalog(catalog))

    XCTAssertEqual(store.modelChoices.first?.id, "copilot/retired")
    XCTAssertEqual(store.reasoningChoices, [.medium])
  }

  func testSuccessfulSwitchUsesReturnedSelectionAndReportsFacts() {
    let store = NativeChatStore(workspace: "/tmp/work", driver: FakeConversationDriver())
    store.reduce(.modelCatalog(testCatalog()))
    let model = ModelInfo(
      id: "omlx/local",
      displayName: "Local",
      maxContextWindowTokens: 32_000,
      maxOutputTokens: 4_000,
      supportsVision: false,
      reasoning: [.off, .max],
      advertisedDefaultReasoning: .max)
    let returned = ModelSelection(modelID: model.id, reasoning: .max)

    store.reduce(
      .modelSwitch(
        .switched(
          model: model,
          selection: returned,
          historyReset: true,
          defaultSaved: true,
          cleanupFailed: true)))

    XCTAssertEqual(store.confirmedSelection, returned)
    XCTAssertEqual(store.catalog?.selected, returned)
    XCTAssertEqual(store.modelChoices.last, model)
    XCTAssertEqual(
      store.transcript.last?.text,
      "Switched to Local with Maximum reasoning. Server history reset; visible transcript preserved. Saved as default. Previous session cleanup failed."
    )
  }

  func testDecoderCopiesComplexCatalogValues() throws {
    let bytes = Array("copilot/gpt-5GPT-5".utf8)
    var event = vivi_backend_event_t()
    event.kind = VIVI_BACKEND_EVENT_MODEL_CATALOG
    event.content_kind = VIVI_BACKEND_CONTENT_MODEL_CATALOG
    event.byte_count = UInt32(bytes.count)
    event.model_count = 1
    event.selected_model_id = vivi_backend_span_t(offset: 0, length: 13)
    event.selected_reasoning = VIVI_BACKEND_REASONING_HIGH

    var model = vivi_backend_model_t()
    model.id = vivi_backend_span_t(offset: 0, length: 13)
    model.display_name = vivi_backend_span_t(offset: 13, length: 5)
    model.max_context_window_tokens = 128_000
    model.max_output_tokens = 16_000
    model.supports_vision = 1
    model.reasoning_mask = 0b0010_1001
    model.advertised_default_reasoning = Int8(VIVI_BACKEND_REASONING_HIGH.rawValue)

    let decoded = try NativeEventDecoder.decode(event, bytes: bytes, models: [model])
    guard case .modelCatalog(let catalog) = decoded else {
      return XCTFail("Expected a model catalog")
    }
    XCTAssertEqual(catalog.selected, ModelSelection(modelID: "copilot/gpt-5", reasoning: .high))
    XCTAssertEqual(catalog.models[0].displayName, "GPT-5")
    XCTAssertEqual(catalog.models[0].reasoning, [.off, .high, .max])
    XCTAssertTrue(catalog.models[0].supportsVision)
  }

  func testDecoderRejectsOutOfBoundsModelSpan() {
    var event = vivi_backend_event_t()
    event.kind = VIVI_BACKEND_EVENT_MODEL_CATALOG
    event.content_kind = VIVI_BACKEND_CONTENT_MODEL_CATALOG
    event.byte_count = 1
    event.model_count = 1
    event.selected_model_id = vivi_backend_span_t(offset: 0, length: 1)
    event.selected_reasoning = VIVI_BACKEND_REASONING_OFF
    var model = vivi_backend_model_t()
    model.id = vivi_backend_span_t(offset: 1, length: 1)
    model.reasoning_mask = 1

    XCTAssertThrowsError(
      try NativeEventDecoder.decode(event, bytes: [65], models: [model]))
  }

  func testDecoderRejectsUnsupportedSelectedReasoning() {
    let bytes = Array("copilot/gpt-5GPT-5".utf8)
    var event = vivi_backend_event_t()
    event.kind = VIVI_BACKEND_EVENT_MODEL_CATALOG
    event.content_kind = VIVI_BACKEND_CONTENT_MODEL_CATALOG
    event.byte_count = UInt32(bytes.count)
    event.model_count = 1
    event.selected_model_id = vivi_backend_span_t(offset: 0, length: 13)
    event.selected_reasoning = VIVI_BACKEND_REASONING_HIGH
    var model = vivi_backend_model_t()
    model.id = vivi_backend_span_t(offset: 0, length: 13)
    model.display_name = vivi_backend_span_t(offset: 13, length: 5)
    model.reasoning_mask = 1

    XCTAssertThrowsError(
      try NativeEventDecoder.decode(event, bytes: bytes, models: [model]))
  }

  func testDecoderRejectsUnknownAdvertisedReasoning() {
    let bytes = Array("copilot/gpt-5GPT-5".utf8)
    var event = vivi_backend_event_t()
    event.kind = VIVI_BACKEND_EVENT_MODEL_CATALOG
    event.content_kind = VIVI_BACKEND_CONTENT_MODEL_CATALOG
    event.byte_count = UInt32(bytes.count)
    event.model_count = 1
    event.selected_model_id = vivi_backend_span_t(offset: 0, length: 13)
    event.selected_reasoning = VIVI_BACKEND_REASONING_OFF
    var model = vivi_backend_model_t()
    model.id = vivi_backend_span_t(offset: 0, length: 13)
    model.display_name = vivi_backend_span_t(offset: 13, length: 5)
    model.reasoning_mask = 1
    model.advertised_default_reasoning = 99

    XCTAssertThrowsError(
      try NativeEventDecoder.decode(event, bytes: bytes, models: [model]))
  }

  func testDecoderCopiesToolStartFields() throws {
    let bytes = Array(#"call-1Read fileREADME.md{"path":"README.md"}"#.utf8)
    var event = vivi_backend_event_t()
    event.kind = VIVI_BACKEND_EVENT_TOOL_STARTED
    event.content_kind = VIVI_BACKEND_CONTENT_TOOL
    event.byte_count = UInt32(bytes.count)
    event.tool_call_id = vivi_backend_span_t(offset: 0, length: 6)
    event.tool_title = vivi_backend_span_t(offset: 6, length: 9)
    event.tool_detail = vivi_backend_span_t(offset: 15, length: 9)
    event.tool_input = vivi_backend_span_t(offset: 24, length: 20)
    event.tool_result = VIVI_BACKEND_TOOL_RESULT_RUNNING

    XCTAssertEqual(
      try NativeEventDecoder.decode(event, bytes: bytes, models: []),
      .toolStarted(
        ToolActivity(
          callID: "call-1",
          title: "Read file",
          detail: "README.md",
          input: #"{"path":"README.md"}"#,
          result: .running,
          output: "")))
  }

  func testNativeChatURLProducesWorkspaceOnlyRequest() {
    XCTAssertEqual(
      nativeChatRequest(
        from: URL(
          string:
            "vivi://chat?workspace=/tmp/Vivi%20chat&executable=/tmp/evil"
        )!),
      NativeChatRequest(workspace: "/tmp/Vivi chat"))
    XCTAssertNil(
      nativeChatRequest(
        from: URL(string: "vivi://chat?workspace=relative")!))
  }

  func testClosedStoreIgnoresLateReadyEvent() {
    let store = NativeChatStore(
      workspace: "/tmp/work",
      driver: FakeConversationDriver()
    )

    store.reduce(.closed)
    store.reduce(.ready)

    XCTAssertEqual(store.lifecycle, .closed)
    XCTAssertTrue(store.isBusy)
  }

  func testToolMarkdownSanitizerRemovesTerminalSequences() throws {
    XCTAssertEqual(
      try sanitizedToolMarkdown("\u{1B}[32m# Result\u{1B}[0m\r\n"),
      "# Result\n")
  }

  func testCopilotCandidatesIncludeNativePackageManagerLocations() {
    let candidates = nativeCopilotExecutableCandidates(
      home: URL(fileURLWithPath: "/Users/vivi"),
      path: "/custom/bin:/opt/homebrew/bin")

    XCTAssertEqual(candidates.first, "/custom/bin/copilot")
    XCTAssertTrue(candidates.contains("/Users/vivi/.local/bin/copilot"))
    XCTAssertTrue(candidates.contains("/Users/vivi/.volta/bin/copilot"))
    XCTAssertEqual(candidates.filter { $0 == "/opt/homebrew/bin/copilot" }.count, 1)
  }

  func testNVMVersionsSortNumericallyNewestFirst() {
    let versions = ["v9.22.1", "v20.19.5", "v18.20.8"].map {
      URL(fileURLWithPath: "/Users/vivi/.nvm/versions/node/\($0)")
    }

    XCTAssertEqual(
      nativeNodeVersionsNewestFirst(versions).map(\.lastPathComponent),
      ["v20.19.5", "v18.20.8", "v9.22.1"])
  }

  func testSubmitIsBlockedDuringModelOperation() {
    let driver = FakeConversationDriver()
    let store = NativeChatStore(workspace: "/tmp/work", driver: driver)
    store.reduce(.ready)
    store.reduce(.modelCatalog(testCatalog()))
    store.draft = "hello"

    store.refreshModels()
    store.submit()

    XCTAssertFalse(store.canSubmit)
    XCTAssertTrue(driver.submittedPrompts.isEmpty)
    XCTAssertEqual(store.draft, "hello")
  }
}

private final class FakeConversationDriver: ViviConversationDriving {
  var submitResult = ConversationOperationResult.accepted
  var refreshResult = ConversationOperationResult.accepted
  var switchResult = ConversationOperationResult.accepted
  var selections: [ModelSelection] = []
  var submittedPrompts: [String] = []
  private var receive: (@MainActor (ChatEvent) -> Void)?

  func start(
    receive: @escaping @MainActor (ChatEvent) -> Void
  ) -> ConversationOperationResult {
    self.receive = receive
    return .accepted
  }

  func submit(_ prompt: String) -> ConversationOperationResult {
    submittedPrompts.append(prompt)
    return submitResult
  }

  func refreshModels() -> ConversationOperationResult {
    refreshResult
  }

  func switchModel(_ selection: ModelSelection) -> ConversationOperationResult {
    selections.append(selection)
    return switchResult
  }

  func close(completion: @escaping @MainActor () -> Void) {
    Task { @MainActor in completion() }
  }
}

private func testCatalog() -> ModelCatalog {
  ModelCatalog(
    selected: ModelSelection(modelID: "copilot/gpt-5", reasoning: .off),
    models: [
      ModelInfo(
        id: "copilot/gpt-5",
        displayName: "GPT-5",
        maxContextWindowTokens: 128_000,
        maxOutputTokens: 16_000,
        supportsVision: true,
        reasoning: [.off, .high],
        advertisedDefaultReasoning: .high)
    ])
}
