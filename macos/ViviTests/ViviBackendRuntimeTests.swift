import ViviBackend
import XCTest

@testable import Vivi

@MainActor
final class ViviBackendRuntimeTests: XCTestCase {
  func testReducerStreamsLiteralAssistantTextIntoOneRow() {
    let driver = FakeConversationDriver()
    let store = NativeChatStore(workspace: "/tmp/Vivi chat", driver: driver)

    store.reduce(.ready)
    store.draft = "Write a haiku"
    store.submit()
    store.reduce(.assistantStarted)
    store.reduce(.assistantDelta("old "))
    store.reduce(.assistantComplete("new answer"))
    store.reduce(.idle)

    XCTAssertEqual(store.lifecycle, .idle)
    XCTAssertEqual(
      store.transcript,
      [
        .user(id: store.transcript[0].id, text: "Write a haiku"),
        .assistant(id: store.transcript[1].id, text: "new answer"),
      ])
  }

  func testBusySubmitPreservesDraft() {
    let driver = FakeConversationDriver()
    driver.submitResult = .busy
    let store = NativeChatStore(
      workspace: "/tmp/work",
      driver: driver
    )

    store.reduce(.ready)
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

  func testReasoningAndSessionTitleStayDistinctFromAssistant() {
    let store = NativeChatStore(
      workspace: "/tmp/work",
      driver: FakeConversationDriver()
    )

    store.reduce(.sessionTitle("A useful title"))
    store.reduce(.assistantStarted)
    store.reduce(.reasoningDelta("thinking"))
    store.reduce(.reasoningComplete("finished thought"))
    store.reduce(.assistantComplete("answer"))

    XCTAssertEqual(store.sessionTitle, "A useful title")
    XCTAssertEqual(
      store.transcript,
      [
        .assistant(id: store.transcript[0].id, text: "answer"),
        .reasoning(id: store.transcript[1].id, text: "finished thought"),
      ])
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
  }
}

private final class FakeConversationDriver: ViviConversationDriving {
  var submitResult = ConversationOperationResult.accepted
  var refreshResult = ConversationOperationResult.accepted
  var switchResult = ConversationOperationResult.accepted
  var selections: [ModelSelection] = []
  private var receive: (@MainActor (ChatEvent) -> Void)?

  func start(
    receive: @escaping @MainActor (ChatEvent) -> Void
  ) -> ConversationOperationResult {
    self.receive = receive
    return .accepted
  }

  func submit(_: String) -> ConversationOperationResult {
    submitResult
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
