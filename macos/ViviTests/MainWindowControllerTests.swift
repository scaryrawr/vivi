import AppKit
import XCTest

@testable import Vivi

@MainActor
final class MainWindowControllerTests: XCTestCase {
  func testWindowTitleRemainsAppIdentityAcrossConversationChanges() {
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

    XCTAssertEqual(window.title, "Vivi")
    XCTAssertEqual(window.titleVisibility, .hidden)
    XCTAssertNil(window.toolbar)
    XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
    XCTAssertEqual(
      titlebarAccessory(in: window)?.presentation.conversationTitle, "second")
    firstDriver.send(.sessionTitle("First renamed"))
    XCTAssertEqual(window.title, "Vivi")
    XCTAssertEqual(
      titlebarAccessory(in: window)?.presentation.conversationTitle, "second")
    conversations.select(first.id)
    XCTAssertEqual(window.title, "Vivi")
    XCTAssertEqual(
      titlebarAccessory(in: window)?.presentation.conversationTitle,
      "First renamed")
    firstDriver.send(.sessionTitle("First final"))
    XCTAssertEqual(window.title, "Vivi")
    XCTAssertEqual(
      titlebarAccessory(in: window)?.presentation.conversationTitle,
      "First final")
    _ = controller
  }

  func testRealizedToolbarHasOneToggleAndNoVisibleNativeTitle() {
    let conversations = ConversationCollection()
    let window = NSWindow()
    let controller = MainWindowController(
      identity: .primary,
      applicationCoordinator: testApplicationCoordinator(conversations: conversations),
      window: window,
      activate: {},
      onClosed: { _ in })
    defer { window.orderOut(nil) }

    controller.showAndActivate()
    layoutTitlebar(in: window)

    assertVisibleTitlebarGeometry(in: window)
    titlebarAccessory(in: window)?.sidebarButton.performClick(nil)
    layoutTitlebar(in: window)

    XCTAssertEqual(window.title, "Vivi")
    XCTAssertEqual(window.titleVisibility, .hidden)
    XCTAssertNil(window.toolbar)
    XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
    XCTAssertEqual(titlebarAccessory(in: window)?.layoutAttribute, .left)
    assertVisibleTitlebarGeometry(in: window)
    XCTAssertFalse(
      titlebarAccessory(in: window)?.appNameLabel.isAccessibilityElement() ?? true)
    XCTAssertFalse(
      titlebarAccessory(in: window)?.conversationTitleLabel.isAccessibilityElement()
        ?? true)
    _ = controller
  }

  func testWindowToolbarTitleComposesAppIdentityAndConversationTitle() {
    let presentation = MainWindowTitlePresentation(conversationTitle: "Conversation title")

    XCTAssertEqual(presentation.appName, "Vivi")
    XCTAssertEqual(presentation.conversationTitle, "Conversation title")
    XCTAssertEqual(presentation.accessibilityLabel, "Vivi, Conversation title")
  }

  @MainActor
  private func titlebarAccessory(in window: NSWindow) -> MainWindowTitlebarAccessoryController? {
    window.titlebarAccessoryViewControllers.lazy
      .compactMap { $0 as? MainWindowTitlebarAccessoryController }
      .first
  }

  @MainActor
  private func layoutTitlebar(in window: NSWindow) {
    window.contentViewController?.view.layoutSubtreeIfNeeded()
    window.contentView?.superview?.layoutSubtreeIfNeeded()
    titlebarAccessory(in: window)?.view.layoutSubtreeIfNeeded()
  }

  @MainActor
  private func assertVisibleTitlebarGeometry(
    in window: NSWindow,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let accessory = titlebarAccessory(in: window) else {
      XCTFail("Missing realized Vivi titlebar accessory", file: file, line: line)
      return
    }
    let toggleFrame = accessory.view.convert(
      accessory.sidebarButton.bounds, from: accessory.sidebarButton)
    let appNameFrame = accessory.view.convert(
      accessory.appNameLabel.bounds, from: accessory.appNameLabel)
    let separatorFrame = accessory.view.convert(
      accessory.separator.bounds, from: accessory.separator)
    let titleFrame = accessory.view.convert(
      accessory.conversationTitleLabel.bounds,
      from: accessory.conversationTitleLabel)

    XCTAssertEqual(accessory.layoutAttribute, .left, file: file, line: line)
    XCTAssertFalse(accessory.sidebarButton.isHidden, file: file, line: line)
    XCTAssertFalse(accessory.appNameLabel.isHidden, file: file, line: line)
    XCTAssertFalse(accessory.separator.isHidden, file: file, line: line)
    XCTAssertFalse(accessory.conversationTitleLabel.isHidden, file: file, line: line)
    XCTAssertGreaterThan(toggleFrame.width, 0, file: file, line: line)
    XCTAssertGreaterThan(appNameFrame.width, 0, file: file, line: line)
    XCTAssertGreaterThan(separatorFrame.width, 0, file: file, line: line)
    XCTAssertGreaterThan(titleFrame.width, 0, file: file, line: line)
    XCTAssertLessThan(toggleFrame.maxX, appNameFrame.minX, file: file, line: line)
    XCTAssertLessThan(appNameFrame.maxX, separatorFrame.minX, file: file, line: line)
    XCTAssertLessThan(separatorFrame.maxX, titleFrame.minX, file: file, line: line)
    XCTAssertEqual(visibleSidebarToggleCount(in: window), 1, file: file, line: line)
    XCTAssertTrue(visibleNativeTitleLabels(in: window, excluding: accessory).isEmpty)
  }

  @MainActor
  private func visibleSidebarToggleCount(in window: NSWindow) -> Int {
    descendantViews(of: NSButton.self, below: window.contentView?.superview).count {
      !$0.isHidden
        && $0.frame.width > 0
        && $0.action == #selector(NSSplitViewController.toggleSidebar(_:))
    }
  }

  @MainActor
  private func visibleNativeTitleLabels(
    in window: NSWindow,
    excluding accessory: MainWindowTitlebarAccessoryController
  ) -> [NSTextField] {
    descendantViews(of: NSTextField.self, below: window.contentView?.superview).filter {
      $0 !== accessory.appNameLabel
        && $0 !== accessory.conversationTitleLabel
        && !$0.isHidden
        && $0.frame.width > 0
        && $0.stringValue == "Vivi"
    }
  }

  private func descendantViews<View: NSView>(
    of type: View.Type,
    below root: NSView?
  ) -> [View] {
    guard let root else { return [] }
    let matches = (root as? View).map { [$0] } ?? []
    return root.subviews.reduce(into: matches) { result, child in
      result.append(contentsOf: descendantViews(of: type, below: child))
    }
  }

  func testWindowToolbarTitlePreservesLongTitlesForViewTruncation() {
    let title = String(repeating: "Long conversation title ", count: 20)

    XCTAssertEqual(
      MainWindowTitlePresentation(conversationTitle: title).conversationTitle,
      title)
  }

  func testWindowToolbarTitleUsesUntitledFallback() {
    XCTAssertEqual(
      MainWindowTitlePresentation(conversationTitle: "").conversationTitle,
      "Untitled Session")
    XCTAssertEqual(
      MainWindowTitlePresentation(conversationTitle: nil).accessibilityLabel,
      "Vivi, Untitled Session")
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

  func testConversationTitleDoesNotRepeatProjectIdentity() {
    XCTAssertEqual(
      conversationSidebarTitle(title: "project", launchWorkspace: "/work/project"),
      "New conversation")
    XCTAssertEqual(
      conversationSidebarTitle(title: "Generated title", launchWorkspace: "/work/project"),
      "Generated title")
    XCTAssertEqual(
      conversationSidebarTitle(title: "", launchWorkspace: "/work/project"),
      "Untitled Session")
  }

  func testSavedSessionSelectionIsExclusiveToItsOwningConversation() {
    let firstID = ConversationID(rawValue: UUID())
    let secondID = ConversationID(rawValue: UUID())
    let saved = SidebarSelection.savedSession(firstID, ResumeKey(generation: 4, slot: 2))

    XCTAssertEqual(
      resolvedSidebarSelection(selectedConversationID: firstID, savedSelection: saved),
      saved)
    XCTAssertEqual(
      resolvedSidebarSelection(selectedConversationID: secondID, savedSelection: saved),
      .conversation(secondID))
  }

  func testProjectHeaderPresentsNamePathAndAccessibilityHierarchy() {
    let presentation = ProjectSidebarHeaderPresentation(
      workspace: WorkspaceIdentity(absolutePath: "/work/vivi")!)

    XCTAssertEqual(presentation.name, "vivi")
    XCTAssertEqual(presentation.path, "/work/vivi")
    XCTAssertEqual(presentation.accessibilityLabel, "vivi, /work/vivi, project")
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

    XCTAssertEqual(rows.map(\.title), ["Untitled Session"])
    XCTAssertEqual(
      rows[0].accessibilityLabel,
      "Untitled Session, /work/current, saved session")
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
