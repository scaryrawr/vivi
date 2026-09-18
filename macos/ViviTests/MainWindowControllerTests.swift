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

  func testSidebarPresentationAlwaysGroupsProjectsAndDisambiguatesDuplicates() {
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
        workspace: second.navigation.workspace.canonicalPath,
        duplicate: conversations.duplicatePosition(for: second.id)),
      SidebarRowPresentation(
        title: "vivi",
        workspace: "/tmp/vivi",
        duplicateBadge: "2",
        accessibilityLabel: "vivi, /tmp/vivi, conversation 2 of 2"))
    XCTAssertNil(conversations.duplicatePosition(for: other.id))
  }

  func testProjectAccessibilityLabelDisambiguatesMatchingNames() {
    XCTAssertEqual(
      projectAccessibilityLabel(name: "app", path: "/one/app"),
      "app, /one/app, project")
    XCTAssertNotEqual(
      projectAccessibilityLabel(name: "app", path: "/one/app"),
      projectAccessibilityLabel(name: "app", path: "/two/app"))
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

    XCTAssertEqual(rows.map(\.title), ["current"])
    XCTAssertEqual(
      rows[0].accessibilityLabel,
      "current, /work/current, saved session")
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
