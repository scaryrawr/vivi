import AppKit
import XCTest

@testable import Vivi

@MainActor
final class MainWindowControllerTests: XCTestCase {
  func testSelectedStoreAloneDrivesWindowTitle() {
    let firstDriver = ControllableConversationDriver()
    let secondDriver = ControllableConversationDriver()
    let first = ConversationRecord(
      id: ConversationID(rawValue: UUID()),
      launchWorkspace: WorkspaceIdentity(absolutePath: "/tmp/first")!,
      store: NativeChatStore(workspace: "/tmp/first", driver: firstDriver))
    let second = ConversationRecord(
      id: ConversationID(rawValue: UUID()),
      launchWorkspace: WorkspaceIdentity(absolutePath: "/tmp/second")!,
      store: NativeChatStore(workspace: "/tmp/second", driver: secondDriver))
    let conversations = ConversationCollection()
    conversations.appendAndSelect(first)
    conversations.appendAndSelect(second)
    let window = NSWindow()
    let applicationCoordinator = testApplicationCoordinator(conversations: conversations)
    let controller = MainWindowController(
      identity: .primary,
      applicationCoordinator: applicationCoordinator,
      window: window,
      activate: {},
      onClosed: { _ in })

    XCTAssertEqual(window.title, "second")
    firstDriver.send(.sessionTitle("First renamed"))
    XCTAssertEqual(window.title, "second")
    conversations.select(first.id)
    XCTAssertEqual(window.title, "First renamed")
    firstDriver.send(.sessionTitle("First final"))
    XCTAssertEqual(window.title, "First final")
    _ = controller
  }

  func testNormalWindowCloseReleasesPresentationWithoutClosingStore() {
    let driver = ControllableConversationDriver()
    let conversations = ConversationCollection()
    conversations.appendAndSelect(
      ConversationRecord(
        id: ConversationID(rawValue: UUID()),
        launchWorkspace: WorkspaceIdentity(absolutePath: "/tmp/project")!,
        store: NativeChatStore(workspace: "/tmp/project", driver: driver)))
    let window = NSWindow()
    var closedIdentity: MainWindowIdentity?
    let applicationCoordinator = testApplicationCoordinator(conversations: conversations)
    let controller = MainWindowController(
      identity: .primary,
      applicationCoordinator: applicationCoordinator,
      window: window,
      activate: {},
      onClosed: { closedIdentity = $0 })

    controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

    XCTAssertEqual(closedIdentity, .primary)
    XCTAssertEqual(driver.closeCount, 0)
  }

  func testSidebarPresentationShowsTitlesWithoutRepeatingProjectPaths() {
    let first = ConversationRecord(
      id: ConversationID(rawValue: UUID()),
      launchWorkspace: WorkspaceIdentity(absolutePath: "/tmp/vivi")!,
      store: NativeChatStore(
        workspace: "/tmp/vivi",
        driver: ControllableConversationDriver()))
    let second = ConversationRecord(
      id: ConversationID(rawValue: UUID()),
      launchWorkspace: WorkspaceIdentity(absolutePath: "/tmp/vivi")!,
      store: NativeChatStore(
        workspace: "/tmp/vivi",
        driver: ControllableConversationDriver()))
    let other = ConversationRecord(
      id: ConversationID(rawValue: UUID()),
      launchWorkspace: WorkspaceIdentity(absolutePath: "/work/other")!,
      store: NativeChatStore(
        workspace: "/work/other",
        driver: ControllableConversationDriver()))

    let conversations = ConversationCollection()
    conversations.appendAndSelect(first)
    conversations.appendAndSelect(second)
    conversations.appendAndSelect(other)

    XCTAssertEqual(
      conversations.launchWorkspaces.map(\.canonicalPath),
      ["/tmp/vivi", "/work/other"])
    XCTAssertEqual(
      sidebarRowPresentation(
        title: second.navigation.title,
        projectName: "vivi",
        duplicate: conversations.duplicatePosition(for: second.id)),
      SidebarRowPresentation(
        title: "New conversation",
        duplicateBadge: "2",
        accessibilityLabel: "New conversation, conversation 2 of 2"))
    XCTAssertNil(conversations.duplicatePosition(for: other.id))
    XCTAssertEqual(
      sidebarRowPresentation(
        title: "resumed",
        projectName: "resumed",
        duplicate: nil
      ).title,
      "New conversation")
  }

  func testProjectPresentationOnlyShowsPathsForMatchingNames() {
    let first = WorkspaceIdentity(absolutePath: "/one/app")!
    let second = WorkspaceIdentity(absolutePath: "/two/app")!
    let unique = WorkspaceIdentity(absolutePath: "/work/other")!

    XCTAssertEqual(
      projectSidebarPresentation(workspace: first, allWorkspaces: [first, second, unique]),
      ProjectSidebarPresentation(
        name: "app",
        visiblePath: "/one/app",
        help: "/one/app",
        accessibilityLabel: "app, /one/app, project",
        accessibilityIdentifier: "project-/one/app"))
    XCTAssertEqual(
      projectSidebarPresentation(workspace: unique, allWorkspaces: [first, second, unique]),
      ProjectSidebarPresentation(
        name: "other",
        visiblePath: nil,
        help: "/work/other",
        accessibilityLabel: "other, /work/other, project",
        accessibilityIdentifier: "project-/work/other"))
  }

  func testProjectExpansionDefaultsOpenAndPersistsIndependentlyOfSelection() {
    let first = WorkspaceIdentity(absolutePath: "/one/app")!
    let second = WorkspaceIdentity(absolutePath: "/two/app")!
    var expansion = ProjectExpansionState()

    XCTAssertTrue(expansion.isExpanded(first))
    XCTAssertTrue(expansion.isExpanded(second))

    expansion.setExpanded(false, for: first)

    XCTAssertFalse(expansion.isExpanded(first))
    XCTAssertTrue(expansion.isExpanded(second))

    let conversations = ConversationCollection()
    let record = ConversationRecord(
      id: ConversationID(rawValue: UUID()),
      launchWorkspace: first,
      store: NativeChatStore(
        workspace: first.canonicalPath,
        driver: ControllableConversationDriver()))
    conversations.appendAndSelect(record)
    conversations.select(record.id)

    XCTAssertFalse(expansion.isExpanded(first))
    XCTAssertEqual(conversations.selectedConversation?.id, record.id)

    expansion.setExpanded(true, for: first)

    XCTAssertTrue(expansion.isExpanded(first))
  }

  func testProjectSessionHistoryFiltersWorkspaceAndCurrentSession() {
    let catalog = SessionCatalog(
      sessions: [
        historySummary(slot: 1, workspace: "/work/current", title: "Current", isCurrent: true),
        historySummary(slot: 2, workspace: "/work/other", title: "Earlier"),
        historySummary(slot: 3, workspace: "/work/current", title: nil),
        historySummary(slot: 4, workspace: "/work/other", title: "Oldest"),
      ])

    let rows = projectSessionHistoryPresentation(
      catalog: catalog,
      projectWorkspace: "/work/current")

    XCTAssertEqual(rows.map(\.title), ["Untitled session"])
    XCTAssertEqual(
      rows[0].accessibilityLabel,
      "Untitled session, saved session")
  }

  func testProjectSessionHistoryPreservesBackendOrder() {
    let catalog = SessionCatalog(
      sessions: [
        historySummary(slot: 7, workspace: "/work/current", title: "Recent"),
        historySummary(slot: 8, workspace: "/work/current", title: "Earlier"),
      ])

    let rows = projectSessionHistoryPresentation(
      catalog: catalog,
      projectWorkspace: "/work/current")

    XCTAssertEqual(rows.map(\.title), ["Recent", "Earlier"])
  }
}

@MainActor
private func testApplicationCoordinator(
  conversations: ConversationCollection
) -> NativeApplicationCoordinator {
  NativeApplicationCoordinator(
    conversations: conversations,
    makeConversationID: { ConversationID(rawValue: UUID()) },
    makeConversation: { id, workspace, _ in
      ConversationRecord(
        id: id,
        launchWorkspace: workspace,
        store: NativeChatStore(
          workspace: workspace.canonicalPath,
          driver: ControllableConversationDriver()))
    },
    makeWindow: { _, _, _ in
      preconditionFailure("Test does not present a window")
    })
}

private func historySummary(
  slot: UInt32,
  workspace: String,
  title: String?,
  isCurrent: Bool = false
) -> SessionSummary {
  SessionSummary(
    key: ResumeKey(generation: 42, slot: slot),
    workingDirectory: workspace,
    title: title,
    isCurrent: isCurrent)
}
