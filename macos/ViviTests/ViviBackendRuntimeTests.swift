import ViviBackend
import XCTest

@testable import Vivi

@MainActor
final class ViviBackendRuntimeTests: XCTestCase {
  func testInvalidArgumentMappingMatchesControlRecoveryPolicy() {
    XCTAssertEqual(
      ViviConversationDriver.operationResult(VIVI_BACKEND_INVALID_ARGUMENT),
      .failed)
    XCTAssertEqual(
      ViviConversationDriver.userInputOperationResult(VIVI_BACKEND_INVALID_ARGUMENT),
      .rejected)
    XCTAssertEqual(
      ViviConversationDriver.userInputOperationResult(VIVI_BACKEND_BUSY),
      .busy)
    XCTAssertEqual(
      ViviConversationDriver.commandOperationResult(VIVI_BACKEND_INVALID_ARGUMENT),
      .rejected)
    XCTAssertEqual(
      ViviConversationDriver.commandOperationResult(VIVI_BACKEND_BUSY),
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

  func testAttachmentOnlySubmitClearsSelectionAfterAcceptance() async {
    let driver = FakeConversationDriver()
    let attachment = testAttachment(name: "diagram.png")
    let acquirer = FakeAttachmentAcquirer(pasted: attachment)
    let store = NativeChatStore(
      workspace: "/tmp/work",
      driver: driver,
      attachmentAcquirer: acquirer)

    store.reduce(.ready)
    store.reduce(.modelCatalog(testCatalog()))
    store.pasteAttachment()
    await store.waitForAttachmentAcquisition()
    XCTAssertTrue(store.canSubmit)

    store.submit()

    XCTAssertEqual(driver.submittedPrompts, [""])
    XCTAssertEqual(driver.submittedAttachments, [[attachment]])
    XCTAssertTrue(store.attachments.isEmpty)
    XCTAssertEqual(store.lifecycle, .responding)
    XCTAssertEqual(store.transcript.first?.text, "Attached diagram.png")
  }

  func testRejectedAttachmentSubmitPreservesDraftAndSelection() async {
    let driver = FakeConversationDriver()
    driver.submitResult = .rejected
    let attachment = testAttachment(name: "reference.png")
    let store = NativeChatStore(
      workspace: "/tmp/work",
      driver: driver,
      attachmentAcquirer: FakeAttachmentAcquirer(pasted: attachment))

    store.reduce(.ready)
    store.reduce(.modelCatalog(testCatalog()))
    store.draft = "Keep this"
    store.pasteAttachment()
    await store.waitForAttachmentAcquisition()
    store.submit()

    XCTAssertEqual(store.draft, "Keep this")
    XCTAssertEqual(store.attachments, [attachment])
    XCTAssertEqual(driver.submittedAttachments, [[attachment]])
    XCTAssertEqual(store.transcript.first?.text, "That response was not accepted. Try again.")
  }

  func testAttachmentAcquisitionFailurePreservesExistingSelection() async {
    let first = testAttachment(name: "first.png")
    let acquirer = FakeAttachmentAcquirer(pasted: first)
    let store = NativeChatStore(
      workspace: "/tmp/work",
      driver: FakeConversationDriver(),
      attachmentAcquirer: acquirer)

    store.reduce(.ready)
    store.reduce(.modelCatalog(testCatalog()))
    store.pasteAttachment()
    await store.waitForAttachmentAcquisition()
    acquirer.pasteError = ComposerAttachmentAcquisitionError.unsupported("notes.txt")
    store.pasteAttachment()
    await store.waitForAttachmentAcquisition()

    XCTAssertEqual(store.attachments, [first])
    XCTAssertEqual(
      store.attachmentError,
      "“notes.txt” is not a supported PNG, JPEG, GIF, or WebP image.")
  }

  func testAttachmentsRemainSelectedWhileAskUserBlocksSubmissionAndClearOnClose() async {
    let attachment = testAttachment(name: "context.png")
    let acquirer = FakeAttachmentAcquirer(pasted: attachment)
    let store = NativeChatStore(
      workspace: "/tmp/work",
      driver: FakeConversationDriver(),
      attachmentAcquirer: acquirer)

    store.reduce(.ready)
    store.reduce(.modelCatalog(testCatalog()))
    store.pasteAttachment()
    await store.waitForAttachmentAcquisition()
    store.reduce(
      .userInputRequested(
        UserInputRequest(
          id: "ask-attachment",
          question: "Continue?",
          choices: ["Yes"],
          allowsFreeform: false)))

    XCTAssertFalse(store.canSubmit)
    XCTAssertEqual(store.attachments, [attachment])

    store.close()

    XCTAssertTrue(store.attachments.isEmpty)
    XCTAssertEqual(acquirer.cancelCount, 1)
  }

  func testAttachmentAcquisitionBlocksSubmissionAndCannotAppendAfterLifecycleChanges() async {
    let acquirer = FakeAttachmentAcquirer(chosen: [testAttachment(name: "late.png")])
    acquirer.suspendChoose = true
    let driver = FakeConversationDriver()
    let store = NativeChatStore(
      workspace: "/tmp/work",
      driver: driver,
      attachmentAcquirer: acquirer)

    store.reduce(.ready)
    store.reduce(.modelCatalog(testCatalog()))
    store.draft = "Send without the pending image"
    store.chooseAttachments()

    XCTAssertTrue(store.isAcquiringAttachments)
    XCTAssertFalse(store.canSubmit)
    store.submit()
    store.refreshSessions()
    store.selectModel("copilot/gpt-5")
    XCTAssertTrue(driver.submittedPrompts.isEmpty)
    XCTAssertEqual(driver.sessionRefreshCount, 0)
    XCTAssertTrue(driver.selections.isEmpty)

    store.close()
    await store.waitForAttachmentAcquisition()
    XCTAssertTrue(store.attachments.isEmpty)
    XCTAssertFalse(store.isAcquiringAttachments)
  }

  func testAppKitAttachmentAcquirerCancelsRetainedBackgroundWork() async {
    let probe = AttachmentCancellationProbe()
    let acquirer = AppKitComposerAttachmentAcquirer { _ in
      probe.markStarted()
      while !Task.isCancelled {
        Thread.sleep(forTimeInterval: 0.001)
      }
      probe.markCancelled()
      throw CancellationError()
    }
    let task = Task {
      try await acquirer.snapshotFiles([URL(fileURLWithPath: "/unused.png")])
    }
    while !probe.started {
      await Task.yield()
    }

    acquirer.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancelled background acquisition")
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected cancellation error: \(error)")
    }
    XCTAssertTrue(probe.cancelled)
  }

  func testAppKitAttachmentSnapshotReadsOnceAndValidatesContent() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("photo.bin")
    try testPNGData().write(to: url)

    let attachment = try AppKitComposerAttachmentAcquirer.snapshot(url)
    try Data("changed".utf8).write(to: url)

    XCTAssertEqual(attachment.displayName, "photo.bin")
    XCTAssertEqual(attachment.media, .png)
    XCTAssertEqual(attachment.data, testPNGData())
    XCTAssertThrowsError(
      try AppKitComposerAttachmentAcquirer.snapshot(
        data: Data("not an image".utf8),
        displayName: "bad.png"))
  }

  func testAppKitAttachmentBoundedReadContinuesAfterShortChunks() async throws {
    let pipe = Pipe()
    let expected = testPNGData() + Data("remaining bytes".utf8)
    let writer = Task.detached {
      try pipe.fileHandleForWriting.write(contentsOf: expected.prefix(4))
      try await Task.sleep(for: .milliseconds(10))
      try pipe.fileHandleForWriting.write(contentsOf: expected.dropFirst(4))
      try pipe.fileHandleForWriting.close()
    }

    let actual = try AppKitComposerAttachmentAcquirer.readBounded(pipe.fileHandleForReading)
    try await writer.value

    XCTAssertEqual(actual, expected)
  }

  func testAppKitAttachmentRejectsExcessiveDecodedDimensions() throws {
    XCTAssertNoThrow(
      try AppKitComposerAttachmentAcquirer.validateDecodedDimensions(
        width: 4_096,
        height: 4_096))
    XCTAssertThrowsError(
      try AppKitComposerAttachmentAcquirer.validateDecodedDimensions(
        width: 4_097,
        height: 4_096)
    ) { error in
      XCTAssertEqual(
        error as? ComposerAttachmentAcquisitionError,
        .dimensionsTooLarge)
    }
  }

  func testSubmissionAttachmentBridgeKeepsMultipleDescriptorBuffersAlive() {
    let first = testAttachment(name: "first.png")
    let second = ComposerAttachment(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      displayName: "second.jpg",
      media: .jpeg,
      data: Data([0xFF, 0xD8, 0xFF, 0x00]))
    let attachments = [first, second]
    var descriptors: [vivi_backend_submission_attachment_t] = []

    let visited = ViviConversationDriver.withSubmissionAttachments(
      attachments[...],
      descriptors: &descriptors
    ) { buffer in
      XCTAssertEqual(buffer.count, 2)
      for (index, descriptor) in buffer.enumerated() {
        XCTAssertEqual(
          descriptor.struct_size,
          UInt32(MemoryLayout<vivi_backend_submission_attachment_t>.size))
        XCTAssertEqual(descriptor.media_type.rawValue, attachments[index].media.rawValue)
        XCTAssertEqual(
          String(
            decoding: UnsafeBufferPointer(
              start: descriptor.identity,
              count: Int(descriptor.identity_length)),
            as: UTF8.self),
          attachments[index].id.uuidString)
        XCTAssertEqual(
          String(
            decoding: UnsafeBufferPointer(
              start: descriptor.display_name,
              count: Int(descriptor.display_name_length)),
            as: UTF8.self),
          attachments[index].displayName)
        XCTAssertEqual(
          Data(bytes: descriptor.bytes!, count: Int(descriptor.byte_length)),
          attachments[index].data)
      }
      return true
    }

    XCTAssertTrue(visited)
    XCTAssertTrue(descriptors.isEmpty)
  }

  func testAppKitAttachmentSelectionEnforcesCountBeforeReadsAndAggregateWhileReading() throws {
    let missing = URL(fileURLWithPath: "/missing/image.png")
    XCTAssertThrowsError(
      try AppKitComposerAttachmentAcquirer.snapshots(
        Array(repeating: missing, count: composerAttachmentCountLimit + 1))
    ) { error in
      XCTAssertEqual(error as? ComposerAttachmentAcquisitionError, .tooMany)
    }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var oversizedAggregate = testPNGData()
    oversizedAggregate.append(
      Data(repeating: 0, count: composerAttachmentByteLimit / 2))
    let first = directory.appendingPathComponent("first.png")
    let second = directory.appendingPathComponent("second.png")
    try oversizedAggregate.write(to: first)
    try oversizedAggregate.write(to: second)

    XCTAssertThrowsError(
      try AppKitComposerAttachmentAcquirer.snapshots([first, second])
    ) { error in
      XCTAssertEqual(error as? ComposerAttachmentAcquisitionError, .totalTooLarge)
    }
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

    event.user_input_request_id = vivi_backend_span_t(
      offset: UInt32(bytes.count), length: 0)
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(event, bytes: bytes, models: [model]))
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

    let whitespaceBytes = Array("user-input-1Question \t\r\n".utf8)
    event.byte_count = UInt32(whitespaceBytes.count)
    event.allow_freeform = 0
    let whitespaceChoice = vivi_backend_user_input_choice_t(
      text: vivi_backend_span_t(offset: 20, length: 4),
      reserved: 0)
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        event,
        bytes: whitespaceBytes,
        models: [],
        userInputChoices: [whitespaceChoice]))
  }

  func testDecoderPreservesCanonicallyEquivalentByteDistinctChoices() throws {
    let requestID = Array("user-input-1".utf8)
    let question = Array("Choose".utf8)
    let composed = Array("\u{00E9}".utf8)
    let decomposed = Array("e\u{0301}".utf8)
    let bytes = requestID + question + composed + decomposed
    let choiceOffset = requestID.count + question.count
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
    event.selected_reasoning = VIVI_BACKEND_REASONING_NONE
    let choices = [
      vivi_backend_user_input_choice_t(
        text: vivi_backend_span_t(
          offset: UInt32(choiceOffset),
          length: UInt32(composed.count)),
        reserved: 0),
      vivi_backend_user_input_choice_t(
        text: vivi_backend_span_t(
          offset: UInt32(choiceOffset + composed.count),
          length: UInt32(decomposed.count)),
        reserved: 0),
    ]

    guard
      case .userInputRequested(let request) = try NativeEventDecoder.decode(
        event,
        bytes: bytes,
        models: [],
        userInputChoices: choices)
    else { return XCTFail("Expected a user-input request") }
    XCTAssertEqual(request.choices.map { Array($0.utf8) }, [composed, decomposed])
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
    let resumedCommands = swiftCommandCatalog(generation: 12)
    store.reduce(.commandCatalog(resumedCommands))
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
    XCTAssertEqual(store.commandCatalog, resumedCommands)
    XCTAssertEqual(store.commandCatalogState, .loaded)
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

  func testDecoderStrictlyDecodesTypedCommandCatalog() throws {
    let fixture = commandFixture()

    guard
      case .commandCatalog(let catalog) = try NativeEventDecoder.decode(
        fixture.event,
        bytes: fixture.bytes,
        models: [],
        commands: fixture.commands)
    else { return XCTFail("Expected command catalog") }

    XCTAssertEqual(
      catalog.commands.map(\.key),
      [
        CommandKey(generation: 9, slot: 1),
        CommandKey(generation: 9, slot: 2),
      ])
    XCTAssertEqual(catalog.commands[0].source, .vivi)
    XCTAssertEqual(catalog.commands[0].action, .openModelSelection)
    XCTAssertEqual(catalog.commands[1].argumentPolicy, .required)
    XCTAssertEqual(catalog.commands[1].hint, "topic")
  }

  func testDecoderRejectsMalformedCommandDescriptorsAndCounts() {
    let fixture = commandFixture()

    var reserved = fixture.commands
    reserved[0].reserved = 1
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event, bytes: fixture.bytes, models: [], commands: reserved))

    var mixedGeneration = fixture.commands
    mixedGeneration[1].key.generation += 1
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event, bytes: fixture.bytes, models: [], commands: mixedGeneration))

    var outOfRangeSource = fixture.commands
    outOfRangeSource[0].source = vivi_backend_command_source_t(rawValue: UInt32.max)
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event, bytes: fixture.bytes, models: [], commands: outOfRangeSource))

    var badSpan = fixture.commands
    badSpan[0].description = vivi_backend_span_t(
      offset: UInt32(fixture.bytes.count), length: 1)
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event, bytes: fixture.bytes, models: [], commands: badSpan))

    var noncanonicalEmptyHint = fixture.commands
    noncanonicalEmptyHint[1].hint = vivi_backend_span_t(
      offset: UInt32(fixture.bytes.count), length: 0)
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event,
        bytes: fixture.bytes,
        models: [],
        commands: noncanonicalEmptyHint))

    var badCount = fixture.event
    badCount.command_count += 1
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        badCount, bytes: fixture.bytes, models: [], commands: fixture.commands))
  }

  func testDecoderStrictlyDecodesCommandOutcomes() throws {
    let bytes = Array("Done".utf8)
    var event = vivi_backend_event_t()
    event.kind = VIVI_BACKEND_EVENT_COMMAND_COMPLETED
    event.content_kind = VIVI_BACKEND_CONTENT_COMMAND_EXECUTION
    event.byte_count = UInt32(bytes.count)
    event.content = vivi_backend_span_t(offset: 0, length: UInt32(bytes.count))
    event.command_key = vivi_backend_command_key_t(generation: 4, slot: 2, reserved: 0)
    event.selected_reasoning = VIVI_BACKEND_REASONING_NONE
    XCTAssertEqual(
      try NativeEventDecoder.decode(event, bytes: bytes, models: []),
      .commandCompleted(key: CommandKey(generation: 4, slot: 2), message: "Done"))

    event.tool_call_id = vivi_backend_span_t(offset: UInt32(bytes.count), length: 0)
    XCTAssertThrowsError(try NativeEventDecoder.decode(event, bytes: bytes, models: []))
    event.tool_call_id = vivi_backend_span_t()

    event.default_saved = 1
    XCTAssertThrowsError(try NativeEventDecoder.decode(event, bytes: bytes, models: []))
    event.default_saved = 0

    var catalogFailure = event
    catalogFailure.kind = VIVI_BACKEND_EVENT_COMMAND_CATALOG_FAILURE
    catalogFailure.content_kind = VIVI_BACKEND_CONTENT_TEXT
    catalogFailure.command_key = vivi_backend_command_key_t()
    catalogFailure.cleanup_failed = 1
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(catalogFailure, bytes: bytes, models: []))

    event.kind = VIVI_BACKEND_EVENT_COMMAND_FAILED
    event.command_key.reserved = 1
    XCTAssertThrowsError(try NativeEventDecoder.decode(event, bytes: bytes, models: []))
  }

  func testCommandFailureFallbackRetryAndGenerationReplacement() {
    let driver = FakeConversationDriver()
    let store = readyCommandStore(driver: driver)
    let original = swiftCommandCatalog(generation: 3)
    store.reduce(.commandCatalog(original))
    store.openCommandPalette(query: "deploy")
    let oldKey = store.selectedCommandKey

    store.reduce(.commandCatalogFailure("Discovery unavailable."))
    XCTAssertEqual(
      store.commandCatalogState,
      .failed(message: "Discovery unavailable.", hasFallback: true))
    XCTAssertEqual(store.filteredCommands.map(\.name), ["deploy"])
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 4)))

    store.retryCommands()
    XCTAssertEqual(store.commandCatalogState, .loading)
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 5)))

    XCTAssertNotEqual(store.selectedCommandKey, oldKey)
    XCTAssertEqual(store.selectedCommandKey?.generation, 5)
    XCTAssertEqual(driver.commandRefreshCount, 2)
  }

  func testOpeningLoadedCommandPaletteRefreshesWhileShowingFallback() {
    let driver = FakeConversationDriver()
    let store = readyCommandStore(driver: driver)
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 3)))

    store.openCommandPalette(query: "deploy")

    XCTAssertEqual(driver.commandRefreshCount, 1)
    XCTAssertEqual(store.commandCatalogState, .loading)
    XCTAssertEqual(store.filteredCommands.map(\.name), ["deploy"])
    XCTAssertEqual(store.commandDisabledReason, "Wait for command discovery to finish.")
    store.activateSelectedCommand()
    XCTAssertNil(store.commandArgumentSession)
  }

  func testCommandDiscoveryGatesComposerAndOtherBackendControls() {
    let driver = FakeConversationDriver()
    let store = readyCommandStore(driver: driver)
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 3)))
    store.draft = "keep"

    store.openCommandPalette()
    store.closeCommandPalette()
    store.refreshModels()
    store.refreshSessions()
    store.selectReasoning(.high)

    XCTAssertTrue(store.isBusy)
    XCTAssertFalse(store.canSubmit)
    XCTAssertFalse(store.canAcquireAttachments)
    XCTAssertEqual(store.modelState, .ready)
    XCTAssertEqual(store.sessionState, .ready)
    XCTAssertEqual(driver.modelRefreshCount, 0)
    XCTAssertEqual(driver.sessionRefreshCount, 0)
    XCTAssertTrue(driver.selections.isEmpty)
  }

  func testCommandCatalogFailureKeepsCachedRowsDisabledUntilFallbackArrives() {
    let store = readyCommandStore(driver: FakeConversationDriver())
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 3)))
    store.openCommandPalette(query: "deploy")

    store.reduce(.commandCatalogFailure("Discovery unavailable."))

    XCTAssertEqual(store.commandDisabledReason, "Wait for command discovery to finish.")
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 4)))
    XCTAssertNil(store.commandDisabledReason)
  }

  func testModelRefreshBlocksCachedCommandActivation() {
    let store = readyCommandStore(driver: FakeConversationDriver())
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 3)))

    store.refreshModels()
    store.openCommandPalette(query: "deploy")
    store.activateSelectedCommand()

    XCTAssertEqual(store.commandDisabledReason, "Wait for model controls to finish.")
    XCTAssertNil(store.commandArgumentSession)
  }

  func testCommandArgumentExecutionPreservesComposerDraftAndAttachments() async {
    let driver = FakeConversationDriver()
    let attachment = testAttachment(name: "context.png")
    let store = NativeChatStore(
      workspace: "/tmp/work",
      driver: driver,
      attachmentAcquirer: FakeAttachmentAcquirer(pasted: attachment))
    store.reduce(.ready)
    store.reduce(.modelCatalog(testCatalog()))
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 7)))
    store.draft = "ordinary prompt"
    store.pasteAttachment()
    await store.waitForAttachmentAcquisition()
    store.openCommandPalette(query: "deploy")
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 8)))
    store.activateSelectedCommand()
    store.updateCommandArgumentDraft("production")
    store.submitCommandArgument()

    XCTAssertEqual(
      driver.commandExecutions.first?.0,
      CommandKey(generation: 8, slot: 3))
    XCTAssertEqual(driver.commandExecutions.first?.1, "production")
    XCTAssertEqual(store.draft, "ordinary prompt")
    XCTAssertEqual(store.attachments, [attachment])
    XCTAssertEqual(store.commandExecution?.command.name, "deploy")
  }

  func testAttachmentAcquisitionBlocksCommandExecution() async {
    let acquirer = FakeAttachmentAcquirer(chosen: [testAttachment(name: "late.png")])
    acquirer.suspendChoose = true
    let driver = FakeConversationDriver()
    let store = NativeChatStore(
      workspace: "/tmp/work",
      driver: driver,
      attachmentAcquirer: acquirer)
    store.reduce(.ready)
    store.reduce(.modelCatalog(testCatalog()))
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 7)))
    store.chooseAttachments()
    store.openCommandPalette(query: "deploy")
    store.activateSelectedCommand()

    XCTAssertEqual(
      store.commandDisabledReason,
      "Wait for attachment selection to finish.")
    XCTAssertNil(store.commandArgumentSession)
    XCTAssertTrue(driver.commandExecutions.isEmpty)

    store.close()
    await store.waitForAttachmentAcquisition()
  }

  func testCommandExecutionGatesComposerAndAgentPromptClosesPalette() async {
    let driver = FakeConversationDriver()
    let attachment = testAttachment(name: "context.png")
    let store = NativeChatStore(
      workspace: "/tmp/work",
      driver: driver,
      attachmentAcquirer: FakeAttachmentAcquirer(pasted: attachment))
    store.reduce(.ready)
    store.reduce(.modelCatalog(testCatalog()))
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 7)))
    store.draft = "ordinary prompt"
    store.pasteAttachment()
    await store.waitForAttachmentAcquisition()
    store.openCommandPalette(query: "deploy")
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 8)))
    store.activateSelectedCommand()
    store.updateCommandArgumentDraft("production")
    store.submitCommandArgument()

    XCTAssertFalse(store.canSubmit)
    XCTAssertFalse(store.canAcquireAttachments)
    store.submit()
    XCTAssertTrue(driver.submittedPrompts.isEmpty)

    store.reduce(.assistantStarted)

    XCTAssertNil(store.commandExecution)
    XCTAssertNil(store.commandArgumentSession)
    XCTAssertFalse(store.isCommandPalettePresented)
    XCTAssertEqual(store.draft, "ordinary prompt")
    XCTAssertEqual(store.attachments, [attachment])
  }

  func testRunningArgumentCommandPreservesDraftWhenPaletteCloses() {
    let store = readyCommandStore(driver: FakeConversationDriver())
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 7)))
    store.openCommandPalette(query: "deploy")
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 8)))
    store.activateSelectedCommand()
    store.updateCommandArgumentDraft("keep this")
    store.submitCommandArgument()

    store.exitCommandArgumentMode()
    store.closeCommandPalette()

    XCTAssertEqual(store.commandArgumentSession?.draft, "keep this")
    XCTAssertNotNil(store.commandExecution)
    XCTAssertFalse(store.isCommandPalettePresented)
  }

  func testStaleCommandFailurePreservesArgumentAndRefreshes() {
    let driver = FakeConversationDriver()
    let store = readyCommandStore(driver: driver)
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 7)))
    store.openCommandPalette(query: "deploy")
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 8)))
    store.activateSelectedCommand()
    store.updateCommandArgumentDraft("keep this")
    store.submitCommandArgument()

    store.reduce(
      .commandFailed(
        key: CommandKey(generation: 8, slot: 3),
        message: "Stale command key."))

    XCTAssertEqual(store.commandArgumentSession?.draft, "keep this")
    XCTAssertTrue(store.isCommandPalettePresented)
    XCTAssertEqual(store.commandCatalogState, .loading)
    XCTAssertEqual(driver.commandRefreshCount, 2)

    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 9)))
    XCTAssertEqual(store.commandArgumentSession?.command.key.generation, 9)
    XCTAssertEqual(store.commandArgumentSession?.draft, "keep this")
  }

  func testCatalogReplacementClearsRemovedCommandArgumentSession() {
    let store = readyCommandStore(driver: FakeConversationDriver())
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 7)))
    store.openCommandPalette(query: "deploy")
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 8)))
    store.activateSelectedCommand()
    store.updateCommandArgumentDraft("obsolete")

    let replacement = CommandCatalog(
      commands: swiftCommandCatalog(generation: 9).commands.filter { $0.name != "deploy" })
    store.reduce(.commandCatalog(replacement))

    XCTAssertNil(store.commandArgumentSession)
  }

  func testCatalogReplacementClearsArgumentModeWhenPolicyBecomesNone() {
    let store = readyCommandStore(driver: FakeConversationDriver())
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 7)))
    store.openCommandPalette(query: "deploy")
    store.activateSelectedCommand()
    store.updateCommandArgumentDraft("obsolete")

    var commands = swiftCommandCatalog(generation: 8).commands
    commands[2] = CommandInfo(
      key: CommandKey(generation: 8, slot: 3),
      name: "deploy",
      displayName: "Deploy",
      description: "Deploy the default target",
      hint: nil,
      source: .extensionCommand,
      action: .execute,
      argumentPolicy: .none)
    store.reduce(.commandCatalog(CommandCatalog(commands: commands)))

    XCTAssertNil(store.commandArgumentSession)
  }

  func testRejectedCurrentCommandIsTreatedAsStaleAndRefreshes() {
    let driver = FakeConversationDriver()
    driver.executeCommandResult = .rejected
    let store = readyCommandStore(driver: driver)
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 7)))
    store.openCommandPalette(query: "deploy")
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 8)))
    store.activateSelectedCommand()
    store.updateCommandArgumentDraft("keep this")

    store.submitCommandArgument()

    XCTAssertEqual(store.commandArgumentSession?.draft, "keep this")
    XCTAssertTrue(store.isCommandPalettePresented)
    XCTAssertEqual(store.commandCatalogState, .loading)
    XCTAssertEqual(driver.commandRefreshCount, 2)
    XCTAssertEqual(store.transcript.last?.text, "Deploy: Command changed. Refreshing commands.")
  }

  func testCommandOutcomesAppendChronologicallyWithLabels() {
    let driver = FakeConversationDriver()
    let store = readyCommandStore(driver: driver)
    store.reduce(.status("before"))
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 2)))
    store.openCommandPalette(query: "deploy")
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 3)))
    store.activateSelectedCommand()
    store.updateCommandArgumentDraft("now")
    store.submitCommandArgument()
    store.reduce(
      .commandCompleted(
        key: CommandKey(generation: 3, slot: 3),
        message: "Started."))

    XCTAssertEqual(store.transcript.map(\.text), ["before", "Deploy: Started."])
    guard case .status = store.transcript.last else {
      return XCTFail("Expected successful command status")
    }
  }

  func testCompletedCommandSubcommandRestoresIdleLifecycle() {
    let driver = FakeConversationDriver()
    let store = readyCommandStore(driver: driver)
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 2)))
    store.openCommandPalette(query: "deploy")
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 3)))
    store.activateSelectedCommand()
    store.updateCommandArgumentDraft("now")
    store.submitCommandArgument()
    store.reduce(
      .userInputRequested(
        UserInputRequest(
          id: "command-choice",
          question: "Choose a target",
          choices: ["Production"],
          allowsFreeform: false)))
    store.submitUserInputChoice("Production")

    XCTAssertEqual(store.lifecycle, .responding)

    store.reduce(
      .commandCompleted(
        key: CommandKey(generation: 3, slot: 3),
        message: "Started."))

    XCTAssertEqual(store.lifecycle, .idle)
    XCTAssertTrue(store.canAcquireAttachments)
  }

  func testTypedCommandActionsReuseModelAndHistorySurfaces() {
    let store = readyCommandStore(driver: FakeConversationDriver())
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 5)))
    store.draft = "keep"

    store.openCommandPalette(query: "model")
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 6)))
    store.activateSelectedCommand()
    XCTAssertTrue(store.isModelPickerPresented)
    XCTAssertFalse(store.isCommandPalettePresented)
    XCTAssertEqual(store.draft, "keep")

    store.isModelPickerPresented = false
    store.openCommandPalette(query: "resume")
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 7)))
    store.activateSelectedCommand()
    XCTAssertEqual(store.historyPresentationGeneration, 1)
    XCTAssertFalse(store.isCommandPalettePresented)
  }

  func testDirectModelPickerDismissesCommandPalette() {
    let store = readyCommandStore(driver: FakeConversationDriver())
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 5)))
    store.openCommandPalette()
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 6)))

    store.toggleModelPicker()

    XCTAssertFalse(store.isCommandPalettePresented)
    XCTAssertTrue(store.isModelPickerPresented)
  }

  func testSlashOpenFilteringAndWrappedSelectionAreStoreOwned() {
    let store = readyCommandStore(driver: FakeConversationDriver())
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 5)))
    store.draft = "/dep"
    store.composerDraftChanged()

    XCTAssertTrue(store.isCommandPalettePresented)
    XCTAssertEqual(store.commandQuery, "dep")
    XCTAssertEqual(store.filteredCommands.map(\.name), ["deploy"])

    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 6)))
    store.activateSelectedCommand()
    XCTAssertEqual(store.draft, "")
    XCTAssertNotNil(store.commandArgumentSession)

    store.commandQuery = ""
    store.moveCommandSelection(0)
    let first = store.selectedCommandKey
    store.moveCommandSelection(-1)
    XCTAssertEqual(store.selectedCommandKey, store.filteredCommands.last?.key)
    store.moveCommandSelection(1)
    XCTAssertEqual(store.selectedCommandKey, first)
  }

  func testCommandExecutionIsGatedWithoutMutatingPrompt() {
    let driver = FakeConversationDriver()
    let store = readyCommandStore(driver: driver)
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 6)))
    store.draft = "keep"
    store.openCommandPalette(query: "deploy")
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 7)))
    store.activateSelectedCommand()
    store.updateCommandArgumentDraft("target")
    store.reduce(.assistantStarted)
    store.submitCommandArgument()

    XCTAssertTrue(driver.commandExecutions.isEmpty)
    XCTAssertEqual(store.commandDisabledReason, "Wait for Vivi to finish responding.")
    XCTAssertEqual(store.draft, "keep")
    XCTAssertEqual(store.commandArgumentSession?.draft, "target")
  }

  func testAskUserAndCloseClearCommandPresentationWithoutPromptMutation() {
    let store = readyCommandStore(driver: FakeConversationDriver())
    store.reduce(.commandCatalog(swiftCommandCatalog(generation: 1)))
    store.draft = "keep"
    store.openCommandPalette()
    store.reduce(
      .userInputRequested(
        UserInputRequest(
          id: "ask",
          question: "Continue?",
          choices: ["Yes"],
          allowsFreeform: false)))

    XCTAssertFalse(store.isCommandPalettePresented)
    XCTAssertFalse(store.canPresentCommandPalette)
    XCTAssertEqual(store.draft, "keep")

    store.close()
    XCTAssertNil(store.commandCatalog)
    XCTAssertNil(store.commandExecution)
  }
}

@MainActor
private func readyCommandStore(driver: FakeConversationDriver) -> NativeChatStore {
  let store = NativeChatStore(workspace: "/tmp/work", driver: driver)
  store.reduce(.ready)
  store.reduce(.modelCatalog(testCatalog()))
  return store
}

private func swiftCommandCatalog(generation: UInt64) -> CommandCatalog {
  CommandCatalog(commands: [
    CommandInfo(
      key: CommandKey(generation: generation, slot: 1),
      name: "model",
      displayName: "model",
      description: "Choose a model",
      hint: nil,
      source: .vivi,
      action: .openModelSelection,
      argumentPolicy: .none),
    CommandInfo(
      key: CommandKey(generation: generation, slot: 2),
      name: "resume",
      displayName: "resume",
      description: "Resume a session",
      hint: nil,
      source: .vivi,
      action: .openSessionHistory,
      argumentPolicy: .none),
    CommandInfo(
      key: CommandKey(generation: generation, slot: 3),
      name: "deploy",
      displayName: "Deploy",
      description: "Deploy a target",
      hint: "target",
      source: .extensionCommand,
      action: .execute,
      argumentPolicy: .required),
  ])
}

private func commandFixture() -> (
  event: vivi_backend_event_t,
  bytes: [UInt8],
  commands: [vivi_backend_command_t]
) {
  let values = [
    Array("model".utf8),
    Array("model".utf8),
    Array("Choose a model".utf8),
    Array("deploy".utf8),
    Array("Deploy".utf8),
    Array("Deploy a target".utf8),
    Array("topic".utf8),
  ]
  let bytes = values.flatMap { $0 }
  var offset = 0
  func take(_ value: [UInt8]) -> vivi_backend_span_t {
    defer { offset += value.count }
    return vivi_backend_span_t(offset: UInt32(offset), length: UInt32(value.count))
  }
  let spans = values.map(take)
  let commands = [
    vivi_backend_command_t(
      struct_size: UInt32(MemoryLayout<vivi_backend_command_t>.size),
      key: vivi_backend_command_key_t(generation: 9, slot: 1, reserved: 0),
      name: spans[0],
      display_name: spans[1],
      description: spans[2],
      hint: vivi_backend_span_t(),
      source: VIVI_BACKEND_COMMAND_SOURCE_VIVI,
      action: VIVI_BACKEND_COMMAND_ACTION_OPEN_MODEL_SELECTION,
      argument_policy: VIVI_BACKEND_COMMAND_ARGUMENT_NONE,
      reserved: 0),
    vivi_backend_command_t(
      struct_size: UInt32(MemoryLayout<vivi_backend_command_t>.size),
      key: vivi_backend_command_key_t(generation: 9, slot: 2, reserved: 0),
      name: spans[3],
      display_name: spans[4],
      description: spans[5],
      hint: spans[6],
      source: VIVI_BACKEND_COMMAND_SOURCE_EXTENSION,
      action: VIVI_BACKEND_COMMAND_ACTION_EXECUTE,
      argument_policy: VIVI_BACKEND_COMMAND_ARGUMENT_REQUIRED,
      reserved: 0),
  ]
  var event = vivi_backend_event_t()
  event.kind = VIVI_BACKEND_EVENT_COMMAND_CATALOG
  event.content_kind = VIVI_BACKEND_CONTENT_COMMAND_CATALOG
  event.byte_count = UInt32(bytes.count)
  event.command_count = UInt32(commands.count)
  event.selected_reasoning = VIVI_BACKEND_REASONING_NONE
  return (event, bytes, commands)
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
  var refreshCommandsResult = ConversationOperationResult.accepted
  var executeCommandResult = ConversationOperationResult.accepted
  var refreshResult = ConversationOperationResult.accepted
  var switchResult = ConversationOperationResult.accepted
  var refreshSessionsResult = ConversationOperationResult.accepted
  var resumeResult = ConversationOperationResult.accepted
  var userInputResult = ConversationOperationResult.accepted
  var selections: [ModelSelection] = []
  var sessionRefreshCount = 0
  var resumeKeys: [ResumeKey] = []
  var submittedPrompts: [String] = []
  var submittedAttachments: [[ComposerAttachment]] = []
  var commandRefreshCount = 0
  var modelRefreshCount = 0
  var commandExecutions: [(CommandKey, String)] = []
  var userInputResponses: [(String, UserInputAnswer)] = []
  private var receive: (@MainActor (ChatEvent) -> Void)?

  func start(
    receive: @escaping @MainActor (ChatEvent) -> Void
  ) -> ConversationOperationResult {
    self.receive = receive
    return .accepted
  }

  func submit(
    _ prompt: String,
    attachments: [ComposerAttachment]
  ) -> ConversationOperationResult {
    submittedPrompts.append(prompt)
    submittedAttachments.append(attachments)
    return submitResult
  }

  func refreshCommands() -> ConversationOperationResult {
    commandRefreshCount += 1
    return refreshCommandsResult
  }

  func executeCommand(_ key: CommandKey, arguments: String) -> ConversationOperationResult {
    commandExecutions.append((key, arguments))
    return executeCommandResult
  }

  func refreshModels() -> ConversationOperationResult {
    modelRefreshCount += 1
    return refreshResult
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

@MainActor
private final class FakeAttachmentAcquirer: ComposerAttachmentAcquiring {
  var chosen: [ComposerAttachment]
  var pasted: ComposerAttachment
  var chooseError: Error?
  var pasteError: Error?
  var suspendChoose = false
  private var chooseContinuation: CheckedContinuation<[ComposerAttachment], Error>?
  private(set) var cancelCount = 0

  init(
    chosen: [ComposerAttachment] = [],
    pasted: ComposerAttachment = testAttachment()
  ) {
    self.chosen = chosen
    self.pasted = pasted
  }

  func chooseImages() async throws -> [ComposerAttachment] {
    if let chooseError { throw chooseError }
    if suspendChoose {
      return try await withCheckedThrowingContinuation { continuation in
        chooseContinuation = continuation
      }
    }
    return chosen
  }

  func pasteImage() async throws -> ComposerAttachment {
    if let pasteError { throw pasteError }
    return pasted
  }

  func cancel() {
    cancelCount += 1
    chooseContinuation?.resume(throwing: CancellationError())
    chooseContinuation = nil
  }
}

private final class AttachmentCancellationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var didStart = false
  private var didCancel = false

  var started: Bool {
    lock.withLock { didStart }
  }

  var cancelled: Bool {
    lock.withLock { didCancel }
  }

  func markStarted() {
    lock.withLock { didStart = true }
  }

  func markCancelled() {
    lock.withLock { didCancel = true }
  }
}

private func testPNGData() -> Data {
  Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
}

private func testAttachment(name: String = "image.png") -> ComposerAttachment {
  ComposerAttachment(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
    displayName: name,
    media: .png,
    data: testPNGData())
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
