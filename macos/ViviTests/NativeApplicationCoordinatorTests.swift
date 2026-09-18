import AppKit
import XCTest

@testable import Vivi

@MainActor
final class NativeApplicationCoordinatorTests: XCTestCase {
  func testWorkspaceIdentityCanonicalizesLexicallyWithoutExistence() {
    XCTAssertEqual(
      WorkspaceIdentity(absolutePath: "/Volumes/missing/../code//vivi/./")?.canonicalPath,
      "/Volumes/code/vivi")
    XCTAssertEqual(WorkspaceIdentity(absolutePath: "/../../work")?.canonicalPath, "/work")
    XCTAssertEqual(WorkspaceIdentity(absolutePath: "/")?.canonicalPath, "/")
    XCTAssertNil(WorkspaceIdentity(absolutePath: "relative"))
    XCTAssertNil(WorkspaceIdentity(absolutePath: "/bad\0path"))
  }

  func testNativeChatRequestPreservesNarrowURLBoundary() {
    XCTAssertEqual(
      NativeChatRequest(
        url: URL(
          string: "vivi://chat?workspace=/tmp/Vivi%20chat&executable=/tmp/evil")!),
      NativeChatRequest(
        url: URL(string: "vivi://chat?workspace=/tmp/Vivi%20chat")!))
    XCTAssertNil(NativeChatRequest(url: URL(string: "vivi://other?workspace=/tmp/work")!))
    XCTAssertNil(NativeChatRequest(url: URL(string: "https://chat?workspace=/tmp/work")!))
    XCTAssertNil(NativeChatRequest(url: URL(string: "vivi://chat?workspace=relative")!))
  }

  func testEveryValidURLOccurrenceCreatesAndSelectsFreshConversation() {
    let harness = CoordinatorHarness()
    let duplicate = URL(string: "vivi://chat?workspace=/tmp/project/./")!

    harness.coordinator.open([
      duplicate,
      URL(string: "https://example.com")!,
      duplicate,
    ])

    XCTAssertEqual(harness.coordinator.conversations.records.count, 2)
    XCTAssertEqual(
      harness.coordinator.conversations.records.map(\.navigation.workspace.canonicalPath),
      ["/tmp/project", "/tmp/project"])
    XCTAssertEqual(
      harness.coordinator.conversations.launchWorkspaces.map(\.canonicalPath),
      ["/tmp/project"])
    XCTAssertNotEqual(
      harness.coordinator.conversations.records[0].id,
      harness.coordinator.conversations.records[1].id)
    XCTAssertEqual(
      harness.coordinator.conversations.selectedID,
      harness.coordinator.conversations.records[1].id)
    XCTAssertEqual(harness.windows.count, 1)
    XCTAssertEqual(harness.windows[0].showCount, 1)
    XCTAssertEqual(harness.drivers.count, 2)
  }

  func testChosenDirectoryCreatesAndSelectsFreshConversationEveryTime() async {
    let harness = CoordinatorHarness()
    let workspace = FileManager.default.temporaryDirectory

    harness.coordinator.requestNewConversation()
    XCTAssertEqual(harness.coordinator.presentation.workspaceChoice, .choosing)
    XCTAssertEqual(harness.choosers.count, 1)
    await Task.yield()
    harness.choosers[0].finish(workspace)
    await Task.yield()

    harness.coordinator.requestNewConversation()
    await Task.yield()
    harness.choosers[1].finish(workspace)
    await Task.yield()

    XCTAssertEqual(harness.coordinator.conversations.records.count, 2)
    XCTAssertEqual(Set(harness.coordinator.conversations.records.map(\.id)).count, 2)
    XCTAssertEqual(
      harness.coordinator.conversations.records.map(\.navigation.workspace.canonicalPath),
      [workspace.path, workspace.path])
    XCTAssertEqual(
      harness.coordinator.conversations.selectedID,
      harness.coordinator.conversations.records[1].id)
    XCTAssertEqual(harness.windows.count, 1)
    XCTAssertEqual(harness.windows[0].showCount, 2)
    XCTAssertEqual(harness.coordinator.presentation.workspaceChoice, .idle)
  }

  func testURLAndChooserUseDifferentWorkspacesWithSameApplicationConfiguration() async {
    let configuration = NativeApplicationConfiguration(
      settingsPath: "/application-state/settings.json")
    let harness = CoordinatorHarness(applicationConfiguration: configuration)
    let chosenWorkspace = FileManager.default.temporaryDirectory

    harness.coordinator.open([URL(string: "vivi://chat?workspace=/tmp/from-url")!])
    harness.coordinator.requestNewConversation()
    await Task.yield()
    harness.choosers[0].finish(chosenWorkspace)
    await Task.yield()

    XCTAssertEqual(
      harness.creationRequests.map(\.workspace.canonicalPath),
      ["/tmp/from-url", chosenWorkspace.path])
    XCTAssertEqual(
      harness.creationRequests.map(\.configuration),
      [configuration, configuration])
  }

  func testWorkspaceChoiceCancellationChangesNoState() async {
    let harness = CoordinatorHarness()

    harness.coordinator.requestNewConversation()
    await Task.yield()
    harness.choosers[0].finish(nil)
    await Task.yield()

    XCTAssertTrue(harness.coordinator.conversations.records.isEmpty)
    XCTAssertTrue(harness.windows.isEmpty)
    XCTAssertEqual(harness.coordinator.presentation.workspaceChoice, .idle)
  }

  func testInvalidWorkspaceChoiceFailsWithoutCreatingConversation() async throws {
    let harness = CoordinatorHarness()
    let file = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString)
    try Data().write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    harness.coordinator.requestNewConversation()
    await Task.yield()
    harness.choosers[0].finish(file)
    await Task.yield()

    XCTAssertTrue(harness.coordinator.conversations.records.isEmpty)
    XCTAssertEqual(
      harness.coordinator.presentation.workspaceChoice,
      .failure("Choose an existing folder with an absolute path."))
    XCTAssertEqual(harness.windows.count, 1)
    harness.coordinator.dismissWorkspaceChoiceFailure()
    XCTAssertEqual(harness.coordinator.presentation.workspaceChoice, .idle)
  }

  func testNonFileAndMissingWorkspaceChoicesFailVisibly() async {
    let harness = CoordinatorHarness()
    let invalidChoices = [
      URL(string: "relative-workspace")!,
      FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory),
    ]

    for invalidChoice in invalidChoices {
      harness.coordinator.requestNewConversation()
      await Task.yield()
      harness.choosers.last?.finish(invalidChoice)
      await Task.yield()

      XCTAssertEqual(
        harness.coordinator.presentation.workspaceChoice,
        .failure("Choose an existing folder with an absolute path."))
      XCTAssertTrue(harness.coordinator.conversations.records.isEmpty)
      harness.coordinator.dismissWorkspaceChoiceFailure()
    }
  }

  func testWorkspaceChoiceIsSingleFlight() {
    let harness = CoordinatorHarness()

    harness.coordinator.requestNewConversation()
    harness.coordinator.requestNewConversation()

    XCTAssertEqual(harness.choosers.count, 1)
    XCTAssertEqual(harness.coordinator.presentation.workspaceChoice, .choosing)
  }

  func testTerminationCancelsWorkspaceChoiceAndRejectsLateResult() async {
    let harness = CoordinatorHarness()
    harness.coordinator.requestNewConversation()
    await Task.yield()

    let disposition = harness.coordinator.beginTermination {}
    harness.choosers[0].finish(FileManager.default.temporaryDirectory)
    await Task.yield()

    XCTAssertEqual(disposition, .terminateNow)
    XCTAssertEqual(harness.choosers[0].cancelCount, 1)
    XCTAssertTrue(harness.coordinator.conversations.records.isEmpty)
    XCTAssertEqual(harness.coordinator.presentation.workspaceChoice, .idle)
  }

  func testImmediateTerminationPreventsWorkspaceChooserFromStarting() async {
    let harness = CoordinatorHarness()
    harness.coordinator.requestNewConversation()

    let disposition = harness.coordinator.beginTermination {}
    await Task.yield()

    XCTAssertEqual(disposition, .terminateNow)
    XCTAssertEqual(harness.choosers[0].cancelCount, 1)
    XCTAssertEqual(harness.choosers[0].chooseCount, 0)
    XCTAssertTrue(harness.coordinator.conversations.records.isEmpty)
    XCTAssertEqual(harness.coordinator.presentation.workspaceChoice, .idle)
  }

  func testClosingPresentationKeepsConversationsAndReopenReusesStores() {
    let harness = CoordinatorHarness()
    harness.coordinator.open([URL(string: "vivi://chat?workspace=/tmp/project")!])
    let record = harness.coordinator.conversations.records[0]

    harness.windows[0].simulateUserClose()

    XCTAssertEqual(harness.drivers[0].closeCount, 0)
    harness.coordinator.presentMainWindow()
    XCTAssertEqual(harness.windows.count, 2)
    XCTAssertTrue(harness.coordinator.conversations.records[0] === record)
    XCTAssertEqual(harness.coordinator.conversations.selectedID, record.id)
  }

  func testProjectHistoryUsesSelectedLaunchConversationThenLatestFallback() {
    let harness = CoordinatorHarness()
    harness.coordinator.open([
      URL(string: "vivi://chat?workspace=/tmp/project")!,
      URL(string: "vivi://chat?workspace=/tmp/other")!,
      URL(string: "vivi://chat?workspace=/tmp/project")!,
    ])
    let conversations = harness.coordinator.conversations
    let project = WorkspaceIdentity(absolutePath: "/tmp/project")!
    let projectRecords = conversations.records(launchedFrom: project)

    XCTAssertEqual(projectRecords.count, 2)
    XCTAssertTrue(conversations.historyConversation(launchedFrom: project) === projectRecords[1])

    conversations.select(projectRecords[0].id)

    XCTAssertTrue(conversations.historyConversation(launchedFrom: project) === projectRecords[0])
  }

  func testCrossWorkspaceResumeKeepsConversationIdentitySelectionAndUpdatesDuplicates() {
    let harness = CoordinatorHarness()
    harness.coordinator.open([
      URL(string: "vivi://chat?workspace=/tmp/one")!,
      URL(string: "vivi://chat?workspace=/tmp/two")!,
    ])
    let conversations = harness.coordinator.conversations
    let record = conversations.records[0]
    conversations.select(record.id)
    harness.drivers[0].send(.ready)
    harness.drivers[0].send(.modelCatalog(coordinatorModelCatalog()))
    let key = ResumeKey(generation: 9, slot: 2)
    let summary = SessionSummary(
      key: key,
      workingDirectory: "/tmp/two",
      title: "Resumed conversation",
      isCurrent: false)

    record.store.refreshSessions()
    harness.drivers[0].send(
      .sessionCatalog(SessionCatalog(sessions: [summary])))
    record.store.resumeSession(key)
    harness.drivers[0].send(
      .sessionResume(
        .resumed(
          ResumedSession(
            summary: summary,
            transcript: [.assistant("restored")],
            cleanupFailed: false))))

    XCTAssertTrue(conversations.records[0] === record)
    XCTAssertEqual(conversations.selectedID, record.id)
    XCTAssertEqual(record.navigation.workspace.canonicalPath, "/tmp/two")
    XCTAssertEqual(record.launchWorkspace.canonicalPath, "/tmp/one")
    XCTAssertEqual(
      conversations.launchWorkspaces.map(\.canonicalPath),
      ["/tmp/one", "/tmp/two"])
    XCTAssertEqual(record.navigation.title, "Resumed conversation")
    XCTAssertEqual(conversations.duplicatePosition(for: record.id)?.ordinal, 1)
    XCTAssertEqual(conversations.duplicatePosition(for: conversations.records[1].id)?.ordinal, 2)
    XCTAssertEqual(
      conversations.records(launchedFrom: record.launchWorkspace).map(\.id),
      [record.id])
  }

  func testUntitledLaunchPresentsMainWindow() {
    let harness = CoordinatorHarness()
    let delegate = ViviAppDelegate(applicationCoordinator: harness.coordinator)

    XCTAssertTrue(delegate.applicationOpenUntitledFile(NSApplication.shared))

    XCTAssertEqual(harness.windows.count, 1)
    XCTAssertEqual(harness.windows[0].showCount, 1)
  }

  func testTerminationWaitsForEveryUniqueConversationAndDefersReply() async {
    let harness = CoordinatorHarness()
    harness.coordinator.open([
      URL(string: "vivi://chat?workspace=/tmp/one")!,
      URL(string: "vivi://chat?workspace=/tmp/two")!,
    ])
    var replied = false

    let disposition = harness.coordinator.beginTermination {
      replied = true
    }

    XCTAssertEqual(disposition, .terminateLater)
    XCTAssertEqual(harness.drivers.map(\.closeCount), [1, 1])
    XCTAssertEqual(harness.windows[0].terminationCloseCount, 1)
    harness.drivers[1].finishClose()
    XCTAssertFalse(replied)
    harness.drivers[0].finishClose()
    XCTAssertFalse(replied)
    await Task.yield()
    XCTAssertTrue(replied)
  }

  func testEmptyTerminationReturnsImmediately() {
    let harness = CoordinatorHarness()
    var replied = false

    let disposition = harness.coordinator.beginTermination {
      replied = true
    }

    XCTAssertEqual(disposition, .terminateNow)
    XCTAssertFalse(replied)
  }
}

@MainActor
private final class CoordinatorHarness {
  struct CreationRequest {
    let workspace: WorkspaceIdentity
    let configuration: NativeApplicationConfiguration
  }

  let applicationConfiguration: NativeApplicationConfiguration
  var drivers: [ControllableConversationDriver] = []
  var choosers: [ControllableWorkspaceChooser] = []
  var windows: [FakeMainWindow] = []
  var creationRequests: [CreationRequest] = []

  init(applicationConfiguration: NativeApplicationConfiguration = .live) {
    self.applicationConfiguration = applicationConfiguration
  }

  lazy var coordinator: NativeApplicationCoordinator = {
    var nextID = 0
    return NativeApplicationCoordinator(
      applicationConfiguration: applicationConfiguration,
      makeConversationID: {
        nextID += 1
        return ConversationID(
          rawValue: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", nextID))")!)
      },
      makeConversation: { [weak self] id, workspace, configuration in
        self?.creationRequests.append(
          CreationRequest(workspace: workspace, configuration: configuration))
        let driver = ControllableConversationDriver()
        self?.drivers.append(driver)
        return ConversationRecord(
          id: id,
          launchWorkspace: workspace,
          store: NativeChatStore(workspace: workspace.canonicalPath, driver: driver))
      },
      makeWorkspaceChooser: { [weak self] in
        let chooser = ControllableWorkspaceChooser()
        self?.choosers.append(chooser)
        return chooser
      },
      makeWindow: { [weak self] identity, _, onClosed in
        let window = FakeMainWindow(identity: identity, onClosed: onClosed)
        self?.windows.append(window)
        return window
      })
  }()
}

@MainActor
private final class ControllableWorkspaceChooser: WorkspaceChoosing {
  private var continuation: CheckedContinuation<URL?, Never>?
  private var hasPendingResult = false
  private var pendingResult: URL?
  private(set) var cancelCount = 0
  private(set) var chooseCount = 0

  func chooseWorkspace() async -> URL? {
    chooseCount += 1
    if hasPendingResult {
      hasPendingResult = false
      let result = pendingResult
      pendingResult = nil
      return result
    }
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func cancel() {
    cancelCount += 1
    finish(nil)
  }

  func finish(_ url: URL?) {
    guard let continuation else {
      hasPendingResult = true
      pendingResult = url
      return
    }
    self.continuation = nil
    continuation.resume(returning: url)
  }
}

@MainActor
private final class FakeMainWindow: MainWindowControlling {
  let identity: MainWindowIdentity
  var showCount = 0
  var terminationCloseCount = 0

  private let onClosed: @MainActor (MainWindowIdentity) -> Void

  init(
    identity: MainWindowIdentity,
    onClosed: @escaping @MainActor (MainWindowIdentity) -> Void
  ) {
    self.identity = identity
    self.onClosed = onClosed
  }

  func showAndActivate() {
    showCount += 1
  }

  func closeForTermination() {
    terminationCloseCount += 1
  }

  func simulateUserClose() {
    onClosed(identity)
  }
}

final class ControllableConversationDriver: ViviConversationDriving {
  private(set) var closeCount = 0
  private(set) var sessionRefreshCount = 0
  private(set) var resumeKeys: [ResumeKey] = []
  private var receive: (@MainActor (ChatEvent) -> Void)?
  private var closeCompletions: [@MainActor () -> Void] = []

  func start(
    receive: @escaping @MainActor (ChatEvent) -> Void
  ) -> ConversationOperationResult {
    self.receive = receive
    return .accepted
  }

  func submit(_ prompt: String) -> ConversationOperationResult {
    .accepted
  }

  func refreshModels() -> ConversationOperationResult {
    .accepted
  }

  func switchModel(_ selection: ModelSelection) -> ConversationOperationResult {
    .accepted
  }

  func refreshSessions() -> ConversationOperationResult {
    sessionRefreshCount += 1
    return .accepted
  }

  func resumeSession(_ key: ResumeKey) -> ConversationOperationResult {
    resumeKeys.append(key)
    return .accepted
  }

  func respondToUserInput(
    requestID: String,
    answer: UserInputAnswer
  ) -> ConversationOperationResult {
    .accepted
  }

  func close(completion: @escaping @MainActor () -> Void) {
    closeCount += 1
    closeCompletions.append(completion)
  }

  @MainActor
  func send(_ event: ChatEvent) {
    receive?(event)
  }

  @MainActor
  func finishClose() {
    let completions = closeCompletions
    closeCompletions.removeAll()
    for completion in completions {
      completion()
    }
  }

}

private func coordinatorModelCatalog() -> ModelCatalog {
  ModelCatalog(
    selected: ModelSelection(modelID: "copilot/test", reasoning: .medium),
    models: [
      ModelInfo(
        id: "copilot/test",
        displayName: "Test",
        maxContextWindowTokens: 1,
        maxOutputTokens: 1,
        supportsVision: false,
        reasoning: [.medium],
        advertisedDefaultReasoning: .medium)
    ])
}
