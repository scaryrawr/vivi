import ViviBackend
import XCTest

@testable import Vivi

@MainActor
final class ViviBackendRuntimeTests: XCTestCase {
  func testInvalidArgumentIsRejectedOnlyForUserInputResponses() {
    XCTAssertEqual(
      ViviConversationDriver.operationResult(VIVI_BACKEND_INVALID_ARGUMENT),
      .failed)
    XCTAssertEqual(
      ViviConversationDriver.userInputOperationResult(VIVI_BACKEND_INVALID_ARGUMENT),
      .rejected)
    XCTAssertEqual(
      ViviConversationDriver.userInputOperationResult(VIVI_BACKEND_BUSY),
      .busy)
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

  func testUserInputChoicePreservesToolChronologyAndBackendIdentity() {
    let driver = FakeConversationDriver()
    let store = NativeChatStore(workspace: "/tmp/work", driver: driver)
    let tool = ToolActivity(
      callID: "ask-1",
      title: "Ask user",
      detail: "",
      input: "",
      inputPresentation: .literal(""),
      result: .running,
      output: nil,
      outputPresentation: nil)
    let request = UserInputRequest(
      id: "user-input-7",
      question: "Choose a direction",
      choices: ["Focused", "Broad"],
      allowsFreeform: true)

    store.reduce(.assistantStarted)
    store.reduce(.toolStarted(tool))
    store.reduce(.userInputRequested(request))

    XCTAssertEqual(store.lifecycle, .awaitingInput)
    XCTAssertEqual(store.transcript.count, 3)
    guard case .assistantHeader = store.transcript[0],
      case .tool = store.transcript[1],
      case .userInput(_, let pending, nil) = store.transcript[2]
    else { return XCTFail("Expected the request after the active tool") }
    XCTAssertEqual(pending, request)

    store.submitUserInputChoice("Focused")

    XCTAssertEqual(driver.userInputResponses.count, 1)
    XCTAssertEqual(driver.userInputResponses[0].0, "user-input-7")
    XCTAssertEqual(driver.userInputResponses[0].1, .choice("Focused"))
    XCTAssertNil(store.activeUserInput)
    XCTAssertEqual(store.lifecycle, .responding)
    guard case .userInput(_, let completed, .choice("Focused")) = store.transcript[2] else {
      return XCTFail("Expected the accepted answer to complete the same transcript row")
    }
    XCTAssertEqual(completed, request)
  }

  func testRejectedFreeformAnswerRetainsRequestDraftAndAllowsRetry() {
    let driver = FakeConversationDriver()
    driver.userInputResult = .rejected
    let store = NativeChatStore(workspace: "/tmp/work", driver: driver)
    let request = UserInputRequest(
      id: "user-input-2",
      question: "What should change?",
      choices: ["Nothing"],
      allowsFreeform: true)

    store.reduce(.assistantStarted)
    store.reduce(.userInputRequested(request))
    store.revealFreeformInput()
    store.updateFreeformDraft("Keep my custom answer")
    store.submitUserInputFreeform()

    XCTAssertEqual(store.lifecycle, .awaitingInput)
    XCTAssertEqual(store.activeUserInput?.freeformDraft, "Keep my custom answer")
    XCTAssertEqual(
      store.activeUserInput?.state,
      .failed("That response was not accepted. Try again."))
    guard case .userInput(_, _, nil) = store.transcript.last else {
      return XCTFail("Rejected answers must not destructively complete the row")
    }

    driver.userInputResult = .accepted
    store.submitUserInputFreeform()

    XCTAssertEqual(driver.userInputResponses.count, 2)
    XCTAssertEqual(driver.userInputResponses[1].1, .freeform("Keep my custom answer"))
    XCTAssertNil(store.activeUserInput)
  }

  func testPendingUserInputBlocksPromptAndSessionResume() {
    let driver = FakeConversationDriver()
    let store = NativeChatStore(workspace: "/tmp/work", driver: driver)
    let catalog = swiftSessionCatalog()
    store.reduce(.ready)
    store.reduce(.modelCatalog(testCatalog()))
    store.refreshSessions()
    store.reduce(.sessionCatalog(catalog))
    store.draft = "Do not send this"
    store.reduce(
      .userInputRequested(
        UserInputRequest(
          id: "user-input-1",
          question: "Continue?",
          choices: ["Yes"],
          allowsFreeform: false)))

    store.submit()
    store.resumeSession(catalog.sessions[0].key)

    XCTAssertTrue(driver.submittedPrompts.isEmpty)
    XCTAssertTrue(driver.resumeKeys.isEmpty)
    XCTAssertEqual(store.draft, "Do not send this")
  }

  func testSeparateStoresNeverRouteInteractiveRequestIdentity() {
    let firstDriver = FakeConversationDriver()
    let secondDriver = FakeConversationDriver()
    let first = NativeChatStore(workspace: "/tmp/first", driver: firstDriver)
    let second = NativeChatStore(workspace: "/tmp/second", driver: secondDriver)
    first.reduce(.assistantStarted)
    second.reduce(.assistantStarted)
    first.reduce(
      .userInputRequested(
        UserInputRequest(
          id: "user-input-1",
          question: "First?",
          choices: ["A"],
          allowsFreeform: false)))
    second.reduce(
      .userInputRequested(
        UserInputRequest(
          id: "user-input-1",
          question: "Second?",
          choices: ["B"],
          allowsFreeform: false)))

    second.submitUserInputChoice("B")

    XCTAssertTrue(firstDriver.userInputResponses.isEmpty)
    XCTAssertEqual(secondDriver.userInputResponses.first?.1, .choice("B"))
    XCTAssertNotNil(first.activeUserInput)
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

  func testDecoderCopiesTypedUserInputRequest() throws {
    let requestID = Array("user-input-9".utf8)
    let question = Array("Choose a scope".utf8)
    let first = Array("Focused".utf8)
    let second = Array("Broad".utf8)
    let bytes = requestID + question + first + second
    var event = vivi_backend_event_t()
    event.kind = VIVI_BACKEND_EVENT_USER_INPUT_REQUEST
    event.content_kind = VIVI_BACKEND_CONTENT_USER_INPUT_REQUEST
    event.byte_count = UInt32(bytes.count)
    event.user_input_choice_count = 2
    event.user_input_request_id = vivi_backend_span_t(
      offset: 0,
      length: UInt32(requestID.count))
    event.user_input_question = vivi_backend_span_t(
      offset: UInt32(requestID.count),
      length: UInt32(question.count))
    event.allow_freeform = 1
    event.selected_reasoning = VIVI_BACKEND_REASONING_NONE
    let choices = [
      vivi_backend_user_input_choice_t(
        text: vivi_backend_span_t(
          offset: UInt32(requestID.count + question.count),
          length: UInt32(first.count)),
        reserved: 0),
      vivi_backend_user_input_choice_t(
        text: vivi_backend_span_t(
          offset: UInt32(requestID.count + question.count + first.count),
          length: UInt32(second.count)),
        reserved: 0),
    ]

    XCTAssertEqual(
      try NativeEventDecoder.decode(
        event,
        bytes: bytes,
        models: [],
        userInputChoices: choices),
      .userInputRequested(
        UserInputRequest(
          id: "user-input-9",
          question: "Choose a scope",
          choices: ["Focused", "Broad"],
          allowsFreeform: true)))
  }

  func testDecoderRejectsDuplicateAndMalformedUserInputChoices() {
    let bytes = Array("user-input-1QuestionChoice".utf8)
    var event = vivi_backend_event_t()
    event.kind = VIVI_BACKEND_EVENT_USER_INPUT_REQUEST
    event.content_kind = VIVI_BACKEND_CONTENT_USER_INPUT_REQUEST
    event.byte_count = UInt32(bytes.count)
    event.user_input_choice_count = 2
    event.user_input_request_id = vivi_backend_span_t(offset: 0, length: 12)
    event.user_input_question = vivi_backend_span_t(offset: 12, length: 8)
    event.selected_reasoning = VIVI_BACKEND_REASONING_NONE
    let choice = vivi_backend_user_input_choice_t(
      text: vivi_backend_span_t(offset: 20, length: 6),
      reserved: 0)

    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        event,
        bytes: bytes,
        models: [],
        userInputChoices: [choice, choice]))

    event.user_input_choice_count = 1
    event.allow_freeform = 2
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        event,
        bytes: bytes,
        models: [],
        userInputChoices: [choice]))
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

  func testDecoderAcceptsCanonicalSessionTitleAtScalarLimit() throws {
    let title = String(repeating: "é", count: Int(VIVI_BACKEND_SESSION_TITLE_MAX_CHARACTERS))
    XCTAssertEqual(
      try decodeSessionTitle(Array(title.utf8)),
      .sessionTitle(title))
  }

  func testDecoderRejectsMalformedOrOversizedSessionTitles() {
    XCTAssertThrowsError(try decodeSessionTitle([0xff]))
    XCTAssertThrowsError(try decodeSessionTitle([]))
    XCTAssertThrowsError(
      try decodeSessionTitle(
        Array(
          String(
            repeating: "a",
            count: Int(VIVI_BACKEND_SESSION_TITLE_MAX_CHARACTERS) + 1
          ).utf8)))
  }

  func testDecoderRejectsSessionTitleControlsAndBidiFormatting() {
    for title in [
      "First\nSecond",
      "First\u{007f}Second",
      "First\u{061c}Second",
      "First\u{200e}Second",
      "First\u{200f}Second",
      "First\u{202e}Second",
      "First\u{2066}Second\u{2069}",
    ] {
      XCTAssertThrowsError(try decodeSessionTitle(Array(title.utf8)), title)
    }
  }

  func testDecoderRejectsNoncanonicalSessionTitleWhitespace() {
    for title in [" Leading", "Trailing ", "Repeated  space", "Nonbreaking\u{00a0}space"] {
      XCTAssertThrowsError(try decodeSessionTitle(Array(title.utf8)), title)
    }
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

  private func decodeSessionTitle(_ bytes: [UInt8]) throws -> ChatEvent {
    var event = vivi_backend_event_t()
    event.kind = VIVI_BACKEND_EVENT_SESSION_TITLE
    event.content_kind = VIVI_BACKEND_CONTENT_TEXT
    event.byte_count = UInt32(bytes.count)
    event.content = vivi_backend_span_t(offset: 0, length: UInt32(bytes.count))
    return try NativeEventDecoder.decode(event, bytes: bytes, models: [])
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

  func testDecoderCopiesSessionCatalog() throws {
    let fixture = sessionFixture()
    guard
      case .sessionCatalog(let catalog) = try NativeEventDecoder.decode(
        fixture.event,
        bytes: fixture.bytes,
        models: [],
        sessions: fixture.sessions)
    else { return XCTFail("Expected session catalog") }

    XCTAssertEqual(catalog.sessions.map(\.key.slot), [7, 3])
    XCTAssertEqual(catalog.sessions.map(\.isCurrent), [true, false])
    XCTAssertEqual(catalog.sessions[1].title, nil)
  }

  func testDecoderRejectsMalformedSessionMetadata() {
    let fixture = sessionFixture()

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

    var reservedKey = fixture.sessions
    reservedKey[1].key.reserved = 1
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event, bytes: fixture.bytes, models: [], sessions: reservedKey))

    var badCount = fixture.event
    badCount.session_count += 1
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        badCount, bytes: fixture.bytes, models: [], sessions: fixture.sessions))

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

    var reserved = fixture.event
    reserved.event_reserved = 1
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        reserved,
        bytes: fixture.bytes,
        models: [],
        sessions: [fixture.session],
        transcriptItems: fixture.items))
  }

  func testSessionRefreshClearsCatalogAndForwardsRequest() {
    let driver = FakeConversationDriver()
    let store = NativeChatStore(workspace: "/work/current", driver: driver)
    let catalog = swiftSessionCatalog()
    store.reduce(.ready)
    store.reduce(.modelCatalog(testCatalog()))

    store.refreshSessions()
    XCTAssertNil(store.sessionCatalog)
    XCTAssertEqual(store.sessionState, .refreshing)
    store.reduce(.sessionCatalog(catalog))
    XCTAssertEqual(store.sessionCatalog, catalog)
    XCTAssertEqual(store.sessionState, .ready)
    XCTAssertNil(store.sessionCatalogFailure)
    XCTAssertEqual(driver.sessionRefreshCount, 1)
  }

  func testSessionCatalogFailureIsVisibleUntilRetryStarts() {
    let driver = FakeConversationDriver()
    let store = NativeChatStore(workspace: "/work/current", driver: driver)
    store.reduce(.ready)
    store.reduce(.modelCatalog(testCatalog()))

    store.refreshSessions()
    store.reduce(.sessionCatalogFailure("Could not load sessions."))

    XCTAssertEqual(store.sessionCatalogFailure, "Could not load sessions.")
    XCTAssertEqual(store.sessionState, .ready)

    store.refreshSessions()

    XCTAssertNil(store.sessionCatalogFailure)
    XCTAssertEqual(store.sessionState, .refreshing)
    XCTAssertEqual(driver.sessionRefreshCount, 2)
  }

  func testImmediateSessionRefreshFailureIsVisible() {
    let driver = FakeConversationDriver()
    driver.refreshSessionsResult = .failed
    let store = NativeChatStore(workspace: "/work/current", driver: driver)
    store.reduce(.ready)
    store.reduce(.modelCatalog(testCatalog()))

    store.refreshSessions()

    XCTAssertEqual(store.sessionCatalogFailure, "Could not refresh sessions.")
    XCTAssertNil(store.sessionCatalog)
    XCTAssertEqual(store.sessionState, .ready)
    XCTAssertEqual(driver.sessionRefreshCount, 1)
  }

  func testResumeRejectsStaleKeyAndDuplicateRequest() {
    let driver = FakeConversationDriver()
    let store = NativeChatStore(workspace: "/work/current", driver: driver)
    let catalog = swiftSessionCatalog()
    let key = catalog.sessions[0].key
    store.reduce(.ready)
    store.reduce(.modelCatalog(testCatalog()))
    store.refreshSessions()
    store.reduce(.sessionCatalog(catalog))

    store.resumeSession(
      ResumeKey(generation: key.generation - 1, slot: key.slot))
    store.resumeSession(key)
    store.resumeSession(key)

    XCTAssertEqual(driver.resumeKeys, [key])
    XCTAssertEqual(store.sessionState, .resuming(key))
  }

  func testResumeFailurePreservesPresentationDraftAndCatalog() {
    let driver = FakeConversationDriver()
    let store = NativeChatStore(workspace: "/work/current", driver: driver)
    let catalog = swiftSessionCatalog()
    store.reduce(.ready)
    store.reduce(.modelCatalog(testCatalog()))
    store.refreshSessions()
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
    let catalog = swiftSessionCatalog()
    store.reduce(.ready)
    store.reduce(.modelCatalog(testCatalog()))
    store.refreshSessions()
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
              title: "Resumed title",
              isCurrent: false),
            transcript: [.user(""), .reasoning("thought"), .assistant("answer")],
            cleanupFailed: true))))

    XCTAssertEqual(presentations.count, 1)
    XCTAssertEqual(store.workspace, "/work/resumed")
    XCTAssertEqual(store.sessionTitle, "Resumed title")
    XCTAssertEqual(
      store.confirmedSelection,
      ModelSelection(modelID: "copilot/gpt-5", reasoning: .off))
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

private func sessionFixture() -> (
  event: vivi_backend_event_t,
  bytes: [UInt8],
  sessions: [vivi_backend_session_summary_t]
) {
  let firstDirectory = Array("/work/current".utf8)
  let firstTitle = Array("Current".utf8)
  let secondDirectory = Array("/work/earlier".utf8)
  let bytes = firstDirectory + firstTitle + secondDirectory
  var offset = 0
  func take(_ value: [UInt8]) -> vivi_backend_span_t {
    defer { offset += value.count }
    return vivi_backend_span_t(offset: UInt32(offset), length: UInt32(value.count))
  }
  let firstDirectorySpan = take(firstDirectory)
  let firstTitleSpan = take(firstTitle)
  let secondDirectorySpan = take(secondDirectory)
  let generation: UInt64 = 42
  let sessions = [
    vivi_backend_session_summary_t(
      key: vivi_backend_resume_key_t(generation: generation, slot: 7, reserved: 0),
      working_directory: firstDirectorySpan,
      title: firstTitleSpan,
      flags: UInt32(VIVI_BACKEND_SESSION_TITLE_PRESENT.rawValue)
        | UInt32(VIVI_BACKEND_SESSION_CURRENT.rawValue),
      reserved: 0),
    vivi_backend_session_summary_t(
      key: vivi_backend_resume_key_t(generation: generation, slot: 3, reserved: 0),
      working_directory: secondDirectorySpan,
      title: vivi_backend_span_t(),
      flags: 0,
      reserved: 0),
  ]
  var event = vivi_backend_event_t()
  event.kind = VIVI_BACKEND_EVENT_SESSION_CATALOG
  event.content_kind = VIVI_BACKEND_CONTENT_SESSION_CATALOG
  event.byte_count = UInt32(bytes.count)
  event.session_count = UInt32(sessions.count)
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
  let title = Array("Resumed title".utf8)
  let bytes = question + answer + directory + title
  let questionSpan = vivi_backend_span_t(offset: 0, length: UInt32(question.count))
  let answerSpan = vivi_backend_span_t(
    offset: UInt32(question.count), length: UInt32(answer.count))
  let directorySpan = vivi_backend_span_t(
    offset: UInt32(question.count + answer.count), length: UInt32(directory.count))
  let titleSpan = vivi_backend_span_t(
    offset: UInt32(question.count + answer.count + directory.count),
    length: UInt32(title.count))
  let session = vivi_backend_session_summary_t(
    key: vivi_backend_resume_key_t(generation: 42, slot: 7, reserved: 0),
    working_directory: directorySpan,
    title: titleSpan,
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
  event.session_resume_outcome = VIVI_BACKEND_SESSION_RESUME_RESUMED
  event.selected_reasoning = VIVI_BACKEND_REASONING_NONE
  return (event, bytes, session, items)
}

private func swiftSessionCatalog() -> SessionCatalog {
  SessionCatalog(
    sessions: [
      SessionSummary(
        key: ResumeKey(generation: 42, slot: 7),
        workingDirectory: "/work/earlier",
        title: "Earlier",
        isCurrent: false)
    ])
}

private final class FakeConversationDriver: ViviConversationDriving {
  var submitResult = ConversationOperationResult.accepted
  var refreshResult = ConversationOperationResult.accepted
  var switchResult = ConversationOperationResult.accepted
  var refreshSessionsResult = ConversationOperationResult.accepted
  var resumeResult = ConversationOperationResult.accepted
  var userInputResult = ConversationOperationResult.accepted
  var selections: [ModelSelection] = []
  var sessionRefreshCount = 0
  var resumeKeys: [ResumeKey] = []
  var submittedPrompts: [String] = []
  var userInputResponses: [(String, UserInputAnswer)] = []
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

  func refreshSessions() -> ConversationOperationResult {
    sessionRefreshCount += 1
    return refreshSessionsResult
  }

  func resumeSession(_ key: ResumeKey) -> ConversationOperationResult {
    resumeKeys.append(key)
    return resumeResult
  }

  func respondToUserInput(
    requestID: String,
    answer: UserInputAnswer
  ) -> ConversationOperationResult {
    userInputResponses.append((requestID, answer))
    return userInputResult
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
