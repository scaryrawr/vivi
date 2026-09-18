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
}
