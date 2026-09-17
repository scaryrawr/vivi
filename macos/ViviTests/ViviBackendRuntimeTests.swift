import ViviBackend
import XCTest

@testable import Vivi

@MainActor
final class ViviBackendRuntimeTests: XCTestCase {
  override func setUp() {
    super.setUp()
    CodePresentationCache.shared.removeAll()
  }

  func testReducerCreatesAssistantLazilyAfterReasoning() {
    let driver = FakeConversationDriver()
    let store = NativeChatStore(workspace: "/tmp/Vivi chat", driver: driver)

    store.reduce(.ready)
    store.reduce(.modelCatalog(testCatalog()))
    store.draft = "Write a haiku"
    store.submit()
    store.reduce(.assistantStarted)
    XCTAssertEqual(store.transcript.count, 1)
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

  func testAssistantHeaderWaitsForFirstStreamEventAndAppearsOnce() {
    let store = NativeChatStore(workspace: "/tmp/work", driver: FakeConversationDriver())

    store.reduce(.assistantStarted)
    store.reduce(.reasoningDelta(""))
    store.reduce(.assistantComplete(""))

    XCTAssertTrue(store.transcript.isEmpty)

    store.reduce(.reasoningDelta("thinking"))
    store.reduce(.reasoningComplete("thinking"))
    store.reduce(.assistantDelta("answer"))
    store.reduce(.assistantComplete("answer"))

    XCTAssertEqual(store.transcript.count, 3)
    guard case .assistantHeader = store.transcript[0],
      case .reasoning = store.transcript[1],
      case .assistant = store.transcript[2]
    else { return XCTFail("Expected one lazy header before streamed response content") }
  }

  func testToolStartRevealsAssistantHeader() {
    let store = NativeChatStore(workspace: "/tmp/work", driver: FakeConversationDriver())

    store.reduce(.assistantStarted)
    store.reduce(
      .toolStarted(
        ToolActivity(
          callID: "call-1",
          title: "Read file",
          detail: "README.md",
          input: #"{"path":"README.md"}"#,
          inputPresentation: .literal(#"{"path":"README.md"}"#),
          result: .running,
          output: nil,
          outputPresentation: nil)))

    XCTAssertEqual(store.transcript.count, 2)
    guard case .assistantHeader = store.transcript[0],
      case .tool = store.transcript[1]
    else { return XCTFail("Expected one lazy header before the first tool event") }
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
      inputPresentation: .literal(#"{"path":"README.md"}"#),
      result: .running,
      output: nil,
      outputPresentation: nil)

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

  func testLateReasoningCompletionReplacesStreamedReasoningBeforeAssistantResponse() {
    let store = NativeChatStore(workspace: "/tmp/work", driver: FakeConversationDriver())

    store.reduce(.assistantStarted)
    store.reduce(.reasoningComplete("before tool"))
    store.reduce(
      .toolStarted(
        ToolActivity(
          callID: "call-1",
          title: "Read file",
          detail: "README.md",
          input: #"{"path":"README.md"}"#,
          inputPresentation: .literal(#"{"path":"README.md"}"#),
          result: .running,
          output: nil,
          outputPresentation: nil)))
    store.reduce(.reasoningComplete("after tool"))
    store.reduce(.assistantComplete("answer"))
    store.reduce(.reasoningComplete("after tool"))

    XCTAssertEqual(store.transcript.count, 5)
    guard case .assistantHeader = store.transcript[0],
      case .reasoning(_, "before tool") = store.transcript[1],
      case .tool = store.transcript[2],
      case .reasoning(_, "after tool") = store.transcript[3],
      case .assistant(_, "answer") = store.transcript[4]
    else { return XCTFail("Expected completed reasoning to replace the streamed reasoning") }
  }

  func testLateReasoningCompletionAfterToolCreatesNewSegment() {
    let store = NativeChatStore(workspace: "/tmp/work", driver: FakeConversationDriver())

    store.reduce(.assistantStarted)
    store.reduce(.reasoningComplete("before tool"))
    store.reduce(
      .toolStarted(
        ToolActivity(
          callID: "call-1",
          title: "Read file",
          detail: "README.md",
          input: #"{"path":"README.md"}"#,
          inputPresentation: .literal(#"{"path":"README.md"}"#),
          result: .running,
          output: nil,
          outputPresentation: nil)))
    store.reduce(.assistantComplete("answer"))
    store.reduce(.reasoningComplete("after tool"))

    XCTAssertEqual(store.transcript.count, 5)
    guard case .assistantHeader = store.transcript[0],
      case .reasoning(_, "before tool") = store.transcript[1],
      case .tool = store.transcript[2],
      case .reasoning(_, "after tool") = store.transcript[3],
      case .assistant(_, "answer") = store.transcript[4]
    else { return XCTFail("Expected late reasoning after the tool and before the assistant") }
  }

  func testLateFirstReasoningInsertsBeforeAssistantResponse() {
    let store = NativeChatStore(workspace: "/tmp/work", driver: FakeConversationDriver())

    store.reduce(.assistantStarted)
    store.reduce(.assistantComplete("answer"))
    store.reduce(.reasoningComplete("late reasoning"))

    XCTAssertEqual(store.transcript.count, 3)
    guard case .assistantHeader = store.transcript[0],
      case .reasoning(_, "late reasoning") = store.transcript[1],
      case .assistant(_, "answer") = store.transcript[2]
    else { return XCTFail("Expected late reasoning before the assistant response") }
  }

  func testEmptyToolRequestCompletionDoesNotCreateAssistantRow() {
    let store = NativeChatStore(workspace: "/tmp/work", driver: FakeConversationDriver())
    let tool = ToolActivity(
      callID: "call-1",
      title: "Read file",
      detail: "README.md",
      input: #"{"path":"README.md"}"#,
      inputPresentation: .literal(#"{"path":"README.md"}"#),
      result: .running,
      output: nil,
      outputPresentation: nil)

    store.reduce(.assistantStarted)
    store.reduce(.assistantComplete(""))
    store.reduce(.toolStarted(tool))
    store.reduce(
      .toolFinished(
        callID: "call-1",
        result: .succeeded,
        output: Data("contents".utf8),
        presentation: .literal("contents")))
    store.reduce(.assistantDelta("done"))
    store.reduce(.assistantComplete("done"))

    XCTAssertEqual(store.transcript.count, 3)
    guard case .assistantHeader = store.transcript[0],
      case .tool(_, let finished) = store.transcript[1],
      case .assistant(_, "done") = store.transcript[2]
    else { return XCTFail("Expected header and tool followed by assistant without an empty row") }
    XCTAssertEqual(finished.output, Data("contents".utf8))
    XCTAssertEqual(finished.outputPresentation, .literal("contents"))
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
      input: #"{"command":"zig build test","timeout":300}"#,
      inputPresentation: .source(text: "zig build test", language: .bash, spans: []),
      result: .running,
      output: nil,
      outputPresentation: nil)
    store.reduce(.toolStarted(tool))
    let originalID = store.transcript[0].id

    store.reduce(
      .toolFinished(
        callID: "call-1",
        result: .succeeded,
        output: Data("passed".utf8),
        presentation: .markdown("**passed**")))

    XCTAssertEqual(store.transcript.count, 1)
    XCTAssertEqual(store.transcript[0].id, originalID)
    guard case .tool(_, let finished) = store.transcript[0] else {
      return XCTFail("Expected tool row")
    }
    XCTAssertEqual(finished.result, .succeeded)
    XCTAssertEqual(finished.output, Data("passed".utf8))
    XCTAssertEqual(finished.outputPresentation, .markdown("**passed**"))
  }

  func testBashInputLayoutKeepsCanonicalFieldsAndStylesCommand() {
    let presentation = ToolPresentation.source(
      text: "zig build test",
      language: .bash,
      spans: [SemanticSpan(byteRange: 0..<3, token: .function)])
    let input = #"{"command":"zig build test","timeout":300}"#

    XCTAssertEqual(
      toolInputLayout(
        input: input,
        presentation: presentation),
      .presentationWithCanonicalJSON(presentation, input))
  }

  func testBashInputLayoutPreservesExactNumericLexeme() {
    let presentation = ToolPresentation.source(
      text: "printf value",
      language: .bash,
      spans: [])
    let input =
      #"{"command":"printf value","ratio":0.10000000000000001,"count":9223372036854775808}"#

    XCTAssertEqual(
      toolInputLayout(input: input, presentation: presentation),
      .presentationWithCanonicalJSON(presentation, input))
  }

  func testLiteralInputLayoutDoesNotDuplicateCanonicalInput() {
    let input = #"{"path":"README.md"}"#

    XCTAssertEqual(
      toolInputLayout(input: input, presentation: .literal(input)),
      .presentation(.literal(input)))
  }

  func testToolInputVisibilityUsesCanonicalInput() {
    XCTAssertTrue(toolInputIsVisible(input: #"{"command":"\u001b"}"#))
    XCTAssertFalse(toolInputIsVisible(input: ""))
  }

  func testNonBashSourceInputKeepsExistingPresentation() {
    let presentation = ToolPresentation.source(
      text: "const value = 1;",
      language: .zig,
      spans: [])

    XCTAssertEqual(
      toolInputLayout(
        input: #"{"source":"const value = 1;","path":"main.zig"}"#,
        presentation: presentation),
      .presentation(presentation))
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

  func testMarkdownRendererReusesIdenticalFencePresentation() {
    let cache = CodePresentationCache(capacity: 2)
    var loads = 0
    let source = """
      ```zig
      const answer = 42;
      ```
      """

    func render() -> [MarkdownBlock] {
      markdownBlocks(
        source,
        codePresentationCache: cache
      ) { language, source in
        loads += 1
        return .source(text: source, language: language == "zig" ? .zig : .bash, spans: [])
      }
    }

    let first = render()
    let second = render()

    XCTAssertEqual(first, second)
    XCTAssertEqual(loads, 1)
    XCTAssertEqual(
      first.compactMap(\.codePresentation),
      [.source(text: "const answer = 42;\n", language: .zig, spans: [])])
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
    let callID = Array("call-1".utf8)
    let title = Array("Run command".utf8)
    let detail = Array("zig build test".utf8)
    let input = Array(#"{"command":"zig build test","timeout":300}"#.utf8)
    let presentation = Array("zig build test".utf8)
    let bytes = callID + title + detail + input + presentation
    var event = vivi_backend_event_t()
    event.kind = VIVI_BACKEND_EVENT_TOOL_STARTED
    event.content_kind = VIVI_BACKEND_CONTENT_TOOL
    event.byte_count = UInt32(bytes.count)
    event.tool_call_id = vivi_backend_span_t(offset: 0, length: UInt32(callID.count))
    event.tool_title = vivi_backend_span_t(
      offset: UInt32(callID.count),
      length: UInt32(title.count))
    event.tool_detail = vivi_backend_span_t(
      offset: UInt32(callID.count + title.count),
      length: UInt32(detail.count))
    event.tool_input = vivi_backend_span_t(
      offset: UInt32(callID.count + title.count + detail.count),
      length: UInt32(input.count))
    event.tool_input_presentation = vivi_backend_presentation_t(
      content: vivi_backend_span_t(
        offset: UInt32(callID.count + title.count + detail.count + input.count),
        length: UInt32(presentation.count)),
      kind: VIVI_BACKEND_PRESENTATION_SOURCE,
      language: VIVI_BACKEND_LANGUAGE_BASH,
      semantic_span_offset: 0,
      semantic_span_count: 0,
      reserved: 0)
    event.tool_result = VIVI_BACKEND_TOOL_RESULT_RUNNING

    XCTAssertEqual(
      try NativeEventDecoder.decode(event, bytes: bytes, models: []),
      .toolStarted(
        ToolActivity(
          callID: "call-1",
          title: "Run command",
          detail: "zig build test",
          input: #"{"command":"zig build test","timeout":300}"#,
          inputPresentation: .source(
            text: "zig build test",
            language: .bash,
            spans: []),
          result: .running,
          output: nil,
          outputPresentation: nil)))
  }

  func testMalformedToolInputDecodesAndCompletesAsFailedTool() throws {
    let callID = Array("call-1".utf8)
    let title = Array("Read file".utf8)
    let detail = Array("Invalid arguments".utf8)
    let input = Array(#"{"path":"#.utf8)
    let inputPresentation = Array(#"{"path":"#.utf8)
    let startBytes = callID + title + detail + input + inputPresentation
    var start = vivi_backend_event_t()
    start.kind = VIVI_BACKEND_EVENT_TOOL_STARTED
    start.content_kind = VIVI_BACKEND_CONTENT_TOOL
    start.byte_count = UInt32(startBytes.count)
    start.tool_call_id = vivi_backend_span_t(offset: 0, length: UInt32(callID.count))
    start.tool_title = vivi_backend_span_t(
      offset: UInt32(callID.count),
      length: UInt32(title.count))
    start.tool_detail = vivi_backend_span_t(
      offset: UInt32(callID.count + title.count),
      length: UInt32(detail.count))
    start.tool_input = vivi_backend_span_t(
      offset: UInt32(callID.count + title.count + detail.count),
      length: UInt32(input.count))
    start.tool_input_presentation = vivi_backend_presentation_t(
      content: vivi_backend_span_t(
        offset: UInt32(callID.count + title.count + detail.count + input.count),
        length: UInt32(inputPresentation.count)),
      kind: VIVI_BACKEND_PRESENTATION_LITERAL,
      language: VIVI_BACKEND_LANGUAGE_NONE,
      semantic_span_offset: 0,
      semantic_span_count: 0,
      reserved: 0)
    start.tool_result = VIVI_BACKEND_TOOL_RESULT_RUNNING

    let failure = Array("Invalid read arguments: SyntaxError.".utf8)
    let finishBytes = callID + failure + failure
    var finish = vivi_backend_event_t()
    finish.kind = VIVI_BACKEND_EVENT_TOOL_FINISHED
    finish.content_kind = VIVI_BACKEND_CONTENT_TOOL
    finish.byte_count = UInt32(finishBytes.count)
    finish.tool_call_id = vivi_backend_span_t(offset: 0, length: UInt32(callID.count))
    finish.content = vivi_backend_span_t(
      offset: UInt32(callID.count),
      length: UInt32(failure.count))
    finish.tool_output_presentation = vivi_backend_presentation_t(
      content: vivi_backend_span_t(
        offset: UInt32(callID.count + failure.count),
        length: UInt32(failure.count)),
      kind: VIVI_BACKEND_PRESENTATION_LITERAL,
      language: VIVI_BACKEND_LANGUAGE_NONE,
      semantic_span_offset: 0,
      semantic_span_count: 0,
      reserved: 0)
    finish.tool_result = VIVI_BACKEND_TOOL_RESULT_FAILED

    let store = NativeChatStore(workspace: "/tmp/work", driver: FakeConversationDriver())
    store.reduce(try NativeEventDecoder.decode(start, bytes: startBytes, models: []))
    store.reduce(try NativeEventDecoder.decode(finish, bytes: finishBytes, models: []))

    guard case .tool(_, let activity) = store.transcript.first else {
      return XCTFail("Expected failed tool row")
    }
    XCTAssertEqual(activity.input, #"{"path":"#)
    XCTAssertEqual(activity.inputPresentation, .literal(#"{"path":"#))
    XCTAssertEqual(activity.result, .failed)
    XCTAssertEqual(activity.output, Data(failure))
    XCTAssertEqual(activity.outputPresentation, .literal(String(decoding: failure, as: UTF8.self)))
    XCTAssertNotEqual(store.lifecycle, .closed)
  }

  func testDecoderCopiesUnicodeSourcePresentation() throws {
    let callID = Array("call-1".utf8)
    let output = Array("raw result".utf8)
    let source = Array("const café = true;\n".utf8)
    let bytes = callID + output + source
    var event = vivi_backend_event_t()
    event.kind = VIVI_BACKEND_EVENT_TOOL_FINISHED
    event.content_kind = VIVI_BACKEND_CONTENT_TOOL
    event.byte_count = UInt32(bytes.count)
    event.semantic_span_count = 2
    event.tool_call_id = vivi_backend_span_t(offset: 0, length: UInt32(callID.count))
    event.content = vivi_backend_span_t(
      offset: UInt32(callID.count),
      length: UInt32(output.count))
    event.tool_result = VIVI_BACKEND_TOOL_RESULT_SUCCEEDED
    event.tool_output_presentation = vivi_backend_presentation_t(
      content: vivi_backend_span_t(
        offset: UInt32(callID.count + output.count),
        length: UInt32(source.count)),
      kind: VIVI_BACKEND_PRESENTATION_SOURCE,
      language: VIVI_BACKEND_LANGUAGE_ZIG,
      semantic_span_offset: 0,
      semantic_span_count: 2,
      reserved: 0)
    let spans = [
      vivi_backend_semantic_span_t(
        bytes: vivi_backend_span_t(
          offset: UInt32(callID.count + output.count),
          length: 5),
        token: VIVI_BACKEND_TOKEN_KEYWORD,
        reserved: 0),
      vivi_backend_semantic_span_t(
        bytes: vivi_backend_span_t(
          offset: UInt32(callID.count + output.count + 14),
          length: 4),
        token: VIVI_BACKEND_TOKEN_CONSTANT,
        reserved: 0),
    ]

    XCTAssertEqual(
      try NativeEventDecoder.decode(event, bytes: bytes, models: [], semanticSpans: spans),
      .toolFinished(
        callID: "call-1",
        result: .succeeded,
        output: Data(output),
        presentation: .source(
          text: "const café = true;\n",
          language: .zig,
          spans: [
            .init(byteRange: 0..<5, token: .keyword),
            .init(byteRange: 14..<18, token: .constant),
          ])))
  }

  func testDecoderPreservesInvalidCanonicalToolInputJSON() throws {
    let callID = Array("call-1".utf8)
    let title = Array("Read file".utf8)
    let input = Array(#"{"path":"README.md""#.utf8)
    let bytes = callID + title + input
    var event = vivi_backend_event_t()
    event.kind = VIVI_BACKEND_EVENT_TOOL_STARTED
    event.content_kind = VIVI_BACKEND_CONTENT_TOOL
    event.byte_count = UInt32(bytes.count)
    event.tool_call_id = vivi_backend_span_t(offset: 0, length: UInt32(callID.count))
    event.tool_title = vivi_backend_span_t(
      offset: UInt32(callID.count),
      length: UInt32(title.count))
    event.tool_input = vivi_backend_span_t(
      offset: UInt32(callID.count + title.count),
      length: UInt32(input.count))
    event.tool_input_presentation = vivi_backend_presentation_t(
      content: event.tool_input,
      kind: VIVI_BACKEND_PRESENTATION_LITERAL,
      language: VIVI_BACKEND_LANGUAGE_NONE,
      semantic_span_offset: 0,
      semantic_span_count: 0,
      reserved: 0)
    event.tool_result = VIVI_BACKEND_TOOL_RESULT_RUNNING

    XCTAssertEqual(
      try NativeEventDecoder.decode(event, bytes: bytes, models: []),
      .toolStarted(
        ToolActivity(
          callID: "call-1",
          title: "Read file",
          detail: "",
          input: #"{"path":"README.md""#,
          inputPresentation: .literal(#"{"path":"README.md""#),
          result: .running,
          output: nil,
          outputPresentation: nil)))
  }

  func testDecoderRejectsInvalidUTF8CanonicalToolInput() {
    let callID = Array("call-1".utf8)
    let title = Array("Read file".utf8)
    let presentation = Array("{}".utf8)
    let bytes = callID + title + [UInt8(0xff)] + presentation
    var event = vivi_backend_event_t()
    event.kind = VIVI_BACKEND_EVENT_TOOL_STARTED
    event.content_kind = VIVI_BACKEND_CONTENT_TOOL
    event.byte_count = UInt32(bytes.count)
    event.tool_call_id = vivi_backend_span_t(offset: 0, length: UInt32(callID.count))
    event.tool_title = vivi_backend_span_t(
      offset: UInt32(callID.count),
      length: UInt32(title.count))
    event.tool_input = vivi_backend_span_t(
      offset: UInt32(callID.count + title.count),
      length: 1)
    event.tool_input_presentation = vivi_backend_presentation_t(
      content: vivi_backend_span_t(
        offset: UInt32(callID.count + title.count + 1),
        length: UInt32(presentation.count)),
      kind: VIVI_BACKEND_PRESENTATION_LITERAL,
      language: VIVI_BACKEND_LANGUAGE_NONE,
      semantic_span_offset: 0,
      semantic_span_count: 0,
      reserved: 0)
    event.tool_result = VIVI_BACKEND_TOOL_RESULT_RUNNING

    XCTAssertThrowsError(try NativeEventDecoder.decode(event, bytes: bytes, models: []))
  }

  func testDecoderRejectsOutOfBoundsCanonicalToolInput() {
    let bytes = Array(#"call-1Read file{"path":"README.md"}"#.utf8)
    var event = vivi_backend_event_t()
    event.kind = VIVI_BACKEND_EVENT_TOOL_STARTED
    event.content_kind = VIVI_BACKEND_CONTENT_TOOL
    event.byte_count = UInt32(bytes.count)
    event.tool_call_id = vivi_backend_span_t(offset: 0, length: 6)
    event.tool_title = vivi_backend_span_t(offset: 6, length: 9)
    event.tool_input = vivi_backend_span_t(offset: UInt32(bytes.count), length: 1)
    event.tool_input_presentation = vivi_backend_presentation_t(
      content: vivi_backend_span_t(offset: 15, length: 20),
      kind: VIVI_BACKEND_PRESENTATION_LITERAL,
      language: VIVI_BACKEND_LANGUAGE_NONE,
      semantic_span_offset: 0,
      semantic_span_count: 0,
      reserved: 0)
    event.tool_result = VIVI_BACKEND_TOOL_RESULT_RUNNING

    XCTAssertThrowsError(try NativeEventDecoder.decode(event, bytes: bytes, models: []))
  }

  func testDecoderRejectsPresentationSpanInsideUnicodeScalar() {
    let callID = Array("call-1".utf8)
    let source = Array("é".utf8)
    let bytes = callID + source
    var event = vivi_backend_event_t()
    event.kind = VIVI_BACKEND_EVENT_TOOL_FINISHED
    event.content_kind = VIVI_BACKEND_CONTENT_TOOL
    event.byte_count = UInt32(bytes.count)
    event.semantic_span_count = 1
    event.tool_call_id = vivi_backend_span_t(offset: 0, length: UInt32(callID.count))
    event.tool_result = VIVI_BACKEND_TOOL_RESULT_SUCCEEDED
    event.tool_output_presentation = vivi_backend_presentation_t(
      content: vivi_backend_span_t(offset: UInt32(callID.count), length: 2),
      kind: VIVI_BACKEND_PRESENTATION_SOURCE,
      language: VIVI_BACKEND_LANGUAGE_ZIG,
      semantic_span_offset: 0,
      semantic_span_count: 1,
      reserved: 0)
    let spans = [
      vivi_backend_semantic_span_t(
        bytes: vivi_backend_span_t(offset: UInt32(callID.count + 1), length: 1),
        token: VIVI_BACKEND_TOKEN_STRING,
        reserved: 0)
    ]

    XCTAssertThrowsError(
      try NativeEventDecoder.decode(event, bytes: bytes, models: [], semanticSpans: spans))
  }

  func testDecoderUsesSafePresentationWhenCanonicalToolResultIsInvalidUTF8() throws {
    let callID = Array("call-1".utf8)
    let safe = Array("\\xff".utf8)
    let bytes = [UInt8(0xff)] + callID + safe
    var event = vivi_backend_event_t()
    event.kind = VIVI_BACKEND_EVENT_TOOL_FINISHED
    event.content_kind = VIVI_BACKEND_CONTENT_TOOL
    event.byte_count = UInt32(bytes.count)
    event.content = vivi_backend_span_t(offset: 0, length: 1)
    event.tool_call_id = vivi_backend_span_t(offset: 1, length: UInt32(callID.count))
    event.tool_result = VIVI_BACKEND_TOOL_RESULT_SUCCEEDED
    event.tool_output_presentation = vivi_backend_presentation_t(
      content: vivi_backend_span_t(
        offset: UInt32(1 + callID.count),
        length: UInt32(safe.count)),
      kind: VIVI_BACKEND_PRESENTATION_LITERAL,
      language: VIVI_BACKEND_LANGUAGE_NONE,
      semantic_span_offset: 0,
      semantic_span_count: 0,
      reserved: 0)

    XCTAssertEqual(
      try NativeEventDecoder.decode(event, bytes: bytes, models: []),
      .toolFinished(
        callID: "call-1",
        result: .succeeded,
        output: Data([0xff]),
        presentation: .literal("\\xff")))
  }

  func testDecoderRejectsOutOfBoundsCanonicalToolOutput() {
    let bytes = Array("call-1safe".utf8)
    var event = vivi_backend_event_t()
    event.kind = VIVI_BACKEND_EVENT_TOOL_FINISHED
    event.content_kind = VIVI_BACKEND_CONTENT_TOOL
    event.byte_count = UInt32(bytes.count)
    event.content = vivi_backend_span_t(offset: UInt32(bytes.count), length: 1)
    event.tool_call_id = vivi_backend_span_t(offset: 0, length: 6)
    event.tool_result = VIVI_BACKEND_TOOL_RESULT_SUCCEEDED
    event.tool_output_presentation = vivi_backend_presentation_t(
      content: vivi_backend_span_t(offset: 6, length: 4),
      kind: VIVI_BACKEND_PRESENTATION_LITERAL,
      language: VIVI_BACKEND_LANGUAGE_NONE,
      semantic_span_offset: 0,
      semantic_span_count: 0,
      reserved: 0)

    XCTAssertThrowsError(try NativeEventDecoder.decode(event, bytes: bytes, models: []))
  }

  func testNativeCodePresentationHighlightsKnownAndLiteralsUnknownLanguages() throws {
    guard
      case .source(let text, let language, let spans) =
        try nativeCodePresentation(language: "python3", source: "return \"hi\"\n")
    else { return XCTFail("Expected source presentation") }
    XCTAssertEqual(text, "return \"hi\"\n")
    XCTAssertEqual(language, .python)
    XCTAssertFalse(spans.isEmpty)
    XCTAssertEqual(
      try nativeCodePresentation(language: "unknown", source: "\u{001B}[31mtext"),
      .literal("\\x1b[31mtext"))
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

  func testDecoderCopiesLocalAndBroaderSessionCatalogs() throws {
    for (nativeScope, expectedScope) in [
      (VIVI_BACKEND_SESSION_SCOPE_LOCAL, SessionCatalogScope.local),
      (VIVI_BACKEND_SESSION_SCOPE_BROADER, SessionCatalogScope.broader),
    ] {
      let fixture = sessionFixture(scope: nativeScope)
      var event = fixture.event
      event.skipped_invalid_shards =
        nativeScope == VIVI_BACKEND_SESSION_SCOPE_LOCAL ? 1 : 0

      guard
        case .sessionCatalog(let catalog) = try NativeEventDecoder.decode(
          event,
          bytes: fixture.bytes,
          models: [],
          sessions: fixture.sessions)
      else { return XCTFail("Expected session catalog") }

      XCTAssertEqual(catalog.scope, expectedScope)
      XCTAssertEqual(catalog.skippedInvalidShards, expectedScope == .local)
      XCTAssertEqual(catalog.sessions.map(\.key.slot), [7, 3])
      XCTAssertEqual(catalog.sessions.map(\.isCurrent), [true, false])
      XCTAssertEqual(catalog.sessions[1].title, nil)
      XCTAssertEqual(catalog.sessions[1].summary, "Earlier work")
    }
  }

  func testDecoderRejectsMalformedSessionMetadata() {
    let fixture = sessionFixture(scope: VIVI_BACKEND_SESSION_SCOPE_LOCAL)

    var badFlags = fixture.sessions
    badFlags[0].flags |= 1 << 8
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event, bytes: fixture.bytes, models: [], sessions: badFlags))

    var reserved = fixture.sessions
    reserved[0].reserved = 1
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event, bytes: fixture.bytes, models: [], sessions: reserved))

    var badSpan = fixture.sessions
    badSpan[0].working_directory = vivi_backend_span_t(
      offset: UInt32(fixture.bytes.count), length: 1)
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event, bytes: fixture.bytes, models: [], sessions: badSpan))

    var zeroGeneration = fixture.sessions
    zeroGeneration[0].key.generation = 0
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event, bytes: fixture.bytes, models: [], sessions: zeroGeneration))

    var mixedGeneration = fixture.sessions
    mixedGeneration[1].key.generation += 1
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event, bytes: fixture.bytes, models: [], sessions: mixedGeneration))

    var mixedScope = fixture.sessions
    mixedScope[1].key.scope = VIVI_BACKEND_SESSION_SCOPE_BROADER
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event, bytes: fixture.bytes, models: [], sessions: mixedScope))

    var badCount = fixture.event
    badCount.session_count += 1
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        badCount, bytes: fixture.bytes, models: [], sessions: fixture.sessions))

    var legacy = vivi_backend_event_t()
    legacy.kind = VIVI_BACKEND_EVENT_READY
    legacy.session_scope = VIVI_BACKEND_SESSION_SCOPE_LOCAL
    XCTAssertThrowsError(try NativeEventDecoder.decode(legacy, bytes: [], models: []))
  }

  func testDecoderCopiesResumeTranscriptExactlyIncludingEmptyText() throws {
    let fixture = resumeFixture()

    guard
      case .sessionResume(.resumed(let resumed)) = try NativeEventDecoder.decode(
        fixture.event,
        bytes: fixture.bytes,
        models: [],
        sessions: [fixture.session],
        transcriptItems: fixture.items)
    else { return XCTFail("Expected resumed session") }

    XCTAssertEqual(
      resumed.transcript,
      [.user("question"), .reasoning(""), .assistant("answer")])
    XCTAssertFalse(resumed.summary.isCurrent)
  }

  func testDecoderRejectsMalformedResumeRoleAndNeutralFailureMetadata() {
    let fixture = resumeFixture()
    var items = fixture.items
    items[0].role = vivi_backend_transcript_role_t(rawValue: 99)
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event,
        bytes: fixture.bytes,
        models: [],
        sessions: [fixture.session],
        transcriptItems: items))

    var failure = vivi_backend_event_t()
    failure.kind = VIVI_BACKEND_EVENT_SESSION_CATALOG_FAILURE
    failure.content_kind = VIVI_BACKEND_CONTENT_TEXT
    failure.skipped_invalid_shards = 1
    XCTAssertThrowsError(try NativeEventDecoder.decode(failure, bytes: [], models: []))
  }

  func testSessionRefreshClearsCatalogCorrelatesScopeAndForwardsRequests() {
    let driver = FakeConversationDriver()
    let store = NativeChatStore(workspace: "/work/current", driver: driver)
    let local = swiftSessionCatalog(scope: .local)
    store.reduce(.ready)
    store.reduce(.modelCatalog(testCatalog()))

    store.refreshSessions(.local)
    XCTAssertNil(store.sessionCatalog)
    XCTAssertEqual(store.sessionState, .refreshing(.local))
    store.reduce(.sessionCatalog(local))
    XCTAssertEqual(store.sessionCatalog, local)
    XCTAssertEqual(store.sessionState, .ready)

    store.refreshSessions(.all)
    XCTAssertNil(store.sessionCatalog)
    store.reduce(.sessionCatalog(local))
    XCTAssertNil(store.sessionCatalog)
    XCTAssertEqual(store.sessionState, .ready)
    XCTAssertEqual(driver.sessionRequests, [.local, .all])
  }

  func testResumeFailurePreservesPresentationDraftAndCatalog() {
    let driver = FakeConversationDriver()
    let store = NativeChatStore(workspace: "/work/current", driver: driver)
    let catalog = swiftSessionCatalog(scope: .local)
    store.reduce(.ready)
    store.reduce(.modelCatalog(testCatalog()))
    store.refreshSessions(.local)
    store.reduce(.sessionCatalog(catalog))
    store.reduce(.status("existing"))
    store.draft = "unsent"
    let before = store.activePresentation

    store.resumeSession(catalog.sessions[0].key)
    XCTAssertEqual(store.activePresentation, before)
    store.reduce(.sessionResume(.failed("Could not resume.")))

    XCTAssertEqual(store.workspace, before.workspace)
    XCTAssertEqual(store.sessionTitle, before.sessionTitle)
    XCTAssertEqual(store.confirmedSelection, before.confirmedSelection)
    XCTAssertEqual(store.draft, "unsent")
    XCTAssertEqual(store.sessionCatalog, catalog)
    XCTAssertEqual(store.transcript.dropLast(), before.transcript[...])
    XCTAssertEqual(store.transcript.last?.text, "Could not resume.")
  }

  func testSuccessfulResumeReplacesActiveAggregateOnceAndPreservesDraft() {
    let driver = FakeConversationDriver()
    let store = NativeChatStore(workspace: "/work/current", driver: driver)
    let catalog = swiftSessionCatalog(scope: .broader)
    store.reduce(.ready)
    store.reduce(.modelCatalog(testCatalog()))
    store.refreshSessions(.all)
    store.reduce(.sessionCatalog(catalog))
    store.reduce(.status("old transcript"))
    store.draft = "keep draft"
    let key = catalog.sessions[0].key
    var presentations: [ActiveConversationPresentation] = []
    let observation = store.$activePresentation.dropFirst().sink { presentations.append($0) }

    store.resumeSession(key)
    XCTAssertEqual(driver.resumeKeys, [key])
    XCTAssertEqual(store.transcript.last?.text, "old transcript")
    store.reduce(
      .sessionResume(
        .resumed(
          ResumedSession(
            summary: SessionSummary(
              key: key,
              workingDirectory: "/work/resumed",
              modelID: "copilot/retired",
              title: "Resumed title",
              summary: nil,
              lastUsedUnixMilliseconds: 10,
              reasoning: .medium,
              isCurrent: false),
            transcript: [.user(""), .reasoning("thought"), .assistant("answer")],
            cleanupFailed: true))))

    XCTAssertEqual(presentations.count, 1)
    XCTAssertEqual(store.workspace, "/work/resumed")
    XCTAssertEqual(store.sessionTitle, "Resumed title")
    XCTAssertEqual(
      store.confirmedSelection,
      ModelSelection(modelID: "copilot/retired", reasoning: .medium))
    XCTAssertEqual(store.modelChoices.first?.id, "copilot/retired")
    XCTAssertEqual(store.draft, "keep draft")
    XCTAssertNil(store.sessionCatalog)
    XCTAssertEqual(
      store.transcript.map(\.text), ["", "thought", "answer", "Previous session cleanup failed."])
    guard case .user = store.transcript[0],
      case .reasoning = store.transcript[1],
      case .assistant = store.transcript[2],
      case .status = store.transcript[3]
    else { return XCTFail("Expected snapshot order without an assistant header") }
    observation.cancel()
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

private func sessionFixture(
  scope: vivi_backend_session_scope_t
) -> (
  event: vivi_backend_event_t,
  bytes: [UInt8],
  sessions: [vivi_backend_session_summary_t]
) {
  let firstDirectory = Array("/work/current".utf8)
  let firstModel = Array("copilot/gpt-5".utf8)
  let firstTitle = Array("Current".utf8)
  let secondDirectory = Array("/work/earlier".utf8)
  let secondModel = Array("copilot/other".utf8)
  let secondSummary = Array("Earlier work".utf8)
  let bytes =
    firstDirectory + firstModel + firstTitle + secondDirectory + secondModel + secondSummary
  var offset = 0
  func take(_ value: [UInt8]) -> vivi_backend_span_t {
    defer { offset += value.count }
    return vivi_backend_span_t(offset: UInt32(offset), length: UInt32(value.count))
  }
  let firstDirectorySpan = take(firstDirectory)
  let firstModelSpan = take(firstModel)
  let firstTitleSpan = take(firstTitle)
  let secondDirectorySpan = take(secondDirectory)
  let secondModelSpan = take(secondModel)
  let secondSummarySpan = take(secondSummary)
  let generation: UInt64 = 42
  let sessions = [
    vivi_backend_session_summary_t(
      key: vivi_backend_resume_key_t(generation: generation, slot: 7, scope: scope),
      working_directory: firstDirectorySpan,
      model_id: firstModelSpan,
      title: firstTitleSpan,
      summary: vivi_backend_span_t(),
      last_used_unix_ms: 200,
      reasoning: VIVI_BACKEND_REASONING_HIGH,
      flags: UInt32(VIVI_BACKEND_SESSION_TITLE_PRESENT.rawValue)
        | UInt32(VIVI_BACKEND_SESSION_CURRENT.rawValue),
      reserved: 0),
    vivi_backend_session_summary_t(
      key: vivi_backend_resume_key_t(generation: generation, slot: 3, scope: scope),
      working_directory: secondDirectorySpan,
      model_id: secondModelSpan,
      title: vivi_backend_span_t(),
      summary: secondSummarySpan,
      last_used_unix_ms: 100,
      reasoning: VIVI_BACKEND_REASONING_OFF,
      flags: UInt32(VIVI_BACKEND_SESSION_SUMMARY_PRESENT.rawValue),
      reserved: 0),
  ]
  var event = vivi_backend_event_t()
  event.kind = VIVI_BACKEND_EVENT_SESSION_CATALOG
  event.content_kind = VIVI_BACKEND_CONTENT_SESSION_CATALOG
  event.byte_count = UInt32(bytes.count)
  event.session_count = UInt32(sessions.count)
  event.session_scope = scope
  event.selected_reasoning = VIVI_BACKEND_REASONING_NONE
  return (event, bytes, sessions)
}

private func resumeFixture() -> (
  event: vivi_backend_event_t,
  bytes: [UInt8],
  session: vivi_backend_session_summary_t,
  items: [vivi_backend_transcript_item_t]
) {
  let question = Array("question".utf8)
  let answer = Array("answer".utf8)
  let directory = Array("/work/resumed".utf8)
  let model = Array("copilot/retired".utf8)
  let title = Array("Resumed title".utf8)
  let bytes = question + answer + directory + model + title
  let questionSpan = vivi_backend_span_t(offset: 0, length: UInt32(question.count))
  let answerSpan = vivi_backend_span_t(
    offset: UInt32(question.count), length: UInt32(answer.count))
  let directorySpan = vivi_backend_span_t(
    offset: UInt32(question.count + answer.count), length: UInt32(directory.count))
  let modelSpan = vivi_backend_span_t(
    offset: UInt32(question.count + answer.count + directory.count),
    length: UInt32(model.count))
  let titleSpan = vivi_backend_span_t(
    offset: UInt32(question.count + answer.count + directory.count + model.count),
    length: UInt32(title.count))
  let session = vivi_backend_session_summary_t(
    key: vivi_backend_resume_key_t(
      generation: 42, slot: 7, scope: VIVI_BACKEND_SESSION_SCOPE_BROADER),
    working_directory: directorySpan,
    model_id: modelSpan,
    title: titleSpan,
    summary: vivi_backend_span_t(),
    last_used_unix_ms: 100,
    reasoning: VIVI_BACKEND_REASONING_MEDIUM,
    flags: UInt32(VIVI_BACKEND_SESSION_TITLE_PRESENT.rawValue),
    reserved: 0)
  let items = [
    vivi_backend_transcript_item_t(
      text: questionSpan, role: VIVI_BACKEND_TRANSCRIPT_USER, reserved: 0),
    vivi_backend_transcript_item_t(
      text: vivi_backend_span_t(), role: VIVI_BACKEND_TRANSCRIPT_REASONING, reserved: 0),
    vivi_backend_transcript_item_t(
      text: answerSpan, role: VIVI_BACKEND_TRANSCRIPT_ASSISTANT, reserved: 0),
  ]
  var event = vivi_backend_event_t()
  event.kind = VIVI_BACKEND_EVENT_SESSION_RESUME
  event.content_kind = VIVI_BACKEND_CONTENT_SESSION_RESUME
  event.byte_count = UInt32(bytes.count)
  event.session_count = 1
  event.transcript_item_count = UInt32(items.count)
  event.session_scope = VIVI_BACKEND_SESSION_SCOPE_BROADER
  event.session_resume_outcome = VIVI_BACKEND_SESSION_RESUME_RESUMED
  event.selected_reasoning = VIVI_BACKEND_REASONING_NONE
  return (event, bytes, session, items)
}

private func swiftSessionCatalog(scope: SessionCatalogScope) -> SessionCatalog {
  SessionCatalog(
    scope: scope,
    sessions: [
      SessionSummary(
        key: ResumeKey(generation: 42, slot: 7, scope: scope),
        workingDirectory: "/work/earlier",
        modelID: "copilot/other",
        title: "Earlier",
        summary: nil,
        lastUsedUnixMilliseconds: 100,
        reasoning: .medium,
        isCurrent: false)
    ],
    skippedInvalidShards: false)
}

private final class FakeConversationDriver: ViviConversationDriving {
  var submitResult = ConversationOperationResult.accepted
  var refreshResult = ConversationOperationResult.accepted
  var switchResult = ConversationOperationResult.accepted
  var refreshSessionsResult = ConversationOperationResult.accepted
  var resumeResult = ConversationOperationResult.accepted
  var selections: [ModelSelection] = []
  var sessionRequests: [SessionCatalogRequest] = []
  var resumeKeys: [ResumeKey] = []
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

  func refreshSessions(_ request: SessionCatalogRequest) -> ConversationOperationResult {
    sessionRequests.append(request)
    return refreshSessionsResult
  }

  func resumeSession(_ key: ResumeKey) -> ConversationOperationResult {
    resumeKeys.append(key)
    return resumeResult
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
