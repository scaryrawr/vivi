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
  var drivers: [ControllableConversationDriver] = []
  var windows: [FakeMainWindow] = []

  lazy var coordinator: NativeApplicationCoordinator = {
    var nextID = 0
    return NativeApplicationCoordinator(
      makeConversationID: {
        nextID += 1
        return ConversationID(
          rawValue: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", nextID))")!)
      },
      makeConversation: { [weak self] id, workspace in
        let driver = ControllableConversationDriver()
        self?.drivers.append(driver)
        return ConversationRecord(
          id: id,
          store: NativeChatStore(workspace: workspace.canonicalPath, driver: driver))
      },
      makeWindow: { [weak self] identity, _, onClosed in
        let window = FakeMainWindow(identity: identity, onClosed: onClosed)
        self?.windows.append(window)
        return window
      })
  }()
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
