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
      store: NativeChatStore(workspace: "/tmp/first", driver: firstDriver))
    let second = ConversationRecord(
      id: ConversationID(rawValue: UUID()),
      store: NativeChatStore(workspace: "/tmp/second", driver: secondDriver))
    let conversations = ConversationCollection()
    conversations.appendAndSelect(first)
    conversations.appendAndSelect(second)
    let window = NSWindow()
    let controller = MainWindowController(
      identity: .primary,
      conversations: conversations,
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
        store: NativeChatStore(workspace: "/tmp/project", driver: driver)))
    let window = NSWindow()
    var closedIdentity: MainWindowIdentity?
    let controller = MainWindowController(
      identity: .primary,
      conversations: conversations,
      window: window,
      activate: {},
      onClosed: { closedIdentity = $0 })

    controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

    XCTAssertEqual(closedIdentity, .primary)
    XCTAssertEqual(driver.closeCount, 0)
  }

  func testSidebarPresentationDisambiguatesDuplicates() {
    XCTAssertEqual(
      sidebarRowPresentation(
        title: "Vivi",
        workspace: "/tmp/vivi",
        duplicate: (ordinal: 2, total: 3)),
      SidebarRowPresentation(
        title: "Vivi",
        workspace: "/tmp/vivi",
        duplicateBadge: "2",
        accessibilityLabel: "Vivi, /tmp/vivi, conversation 2 of 3"))
  }

  func testSavedViviSessionHistoryGroupsWorkspacesAndFiltersCurrentSession() {
    let catalog = SessionCatalog(
      scope: .local,
      sessions: [
        historySummary(slot: 1, workspace: "/work/current", title: "Current", isCurrent: true),
        historySummary(slot: 2, workspace: "/work/other", title: "Earlier"),
        historySummary(slot: 3, workspace: "/work/current", title: nil),
        historySummary(slot: 4, workspace: "/work/other", title: "Oldest"),
      ],
      skippedInvalidShards: false)

    let groups = sessionHistoryPresentation(
      catalog: catalog,
      currentWorkspace: "/work/current",
      formatLastUsed: { "\($0) ms" })

    XCTAssertEqual(groups.map(\.id), ["/work/other", "/work/current"])
    XCTAssertEqual(groups.map(\.title), ["/work/other", "This Workspace"])
    XCTAssertEqual(groups[0].rows.map(\.title), ["Earlier", "Oldest"])
    XCTAssertEqual(groups[1].rows.map(\.title), ["current"])
    XCTAssertEqual(
      groups[0].rows[0].accessibilityLabel,
      "Earlier, /work/other, Summary 2, Last used 2 ms")
  }

  func testWorkspaceCopilotSessionHistoryPreservesBackendOrderWithoutGrouping() {
    let catalog = SessionCatalog(
      scope: .broader,
      sessions: [
        historySummary(slot: 7, workspace: "/work/current", title: "Recent"),
        historySummary(slot: 8, workspace: "/work/current", title: "Earlier"),
      ],
      skippedInvalidShards: false)

    let groups = sessionHistoryPresentation(
      catalog: catalog,
      currentWorkspace: "/work/current",
      formatLastUsed: { "\($0)" })

    XCTAssertEqual(groups.count, 1)
    XCTAssertNil(groups[0].title)
    XCTAssertEqual(groups[0].rows.map(\.title), ["Recent", "Earlier"])
    XCTAssertEqual(groups[0].rows.map(\.lastUsed), ["7", "8"])
  }
}

private func historySummary(
  slot: UInt32,
  workspace: String,
  title: String?,
  isCurrent: Bool = false
) -> SessionSummary {
  SessionSummary(
    key: ResumeKey(generation: 42, slot: slot, scope: .broader),
    workingDirectory: workspace,
    modelID: "copilot/test",
    title: title,
    summary: "Summary \(slot)",
    lastUsedUnixMilliseconds: Int64(slot),
    reasoning: .medium,
    isCurrent: isCurrent)
}
