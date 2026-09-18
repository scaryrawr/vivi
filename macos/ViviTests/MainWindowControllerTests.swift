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
    XCTAssertEqual(window.toolbar?.items.map(\.itemIdentifier), [.viviNavigation, .flexibleSpace])
    XCTAssertEqual(realizedSidebarToggleCount(in: window.toolbar), 1)
    XCTAssertEqual(
      realizedToolbarView(in: window.toolbar)?.presentation.conversationTitle, "second")
    firstDriver.send(.sessionTitle("First renamed"))
    XCTAssertEqual(window.title, "Vivi")
    XCTAssertEqual(
      realizedToolbarView(in: window.toolbar)?.presentation.conversationTitle, "second")
    conversations.select(first.id)
    XCTAssertEqual(window.title, "Vivi")
    XCTAssertEqual(
      realizedToolbarView(in: window.toolbar)?.presentation.conversationTitle,
      "First renamed")
    firstDriver.send(.sessionTitle("First final"))
    XCTAssertEqual(window.title, "Vivi")
    XCTAssertEqual(
      realizedToolbarView(in: window.toolbar)?.presentation.conversationTitle,
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

    let initialToolbarIdentifiers = window.toolbar?.items.map(\.itemIdentifier)
    assertVisibleToolbarGeometry(in: window)
    sidebarToggleButton(in: window.toolbar)?.performClick(nil)
    layoutTitlebar(in: window)

    XCTAssertEqual(window.title, "Vivi")
    XCTAssertEqual(window.titleVisibility, .hidden)
    XCTAssertEqual(initialToolbarIdentifiers, [.viviNavigation, .flexibleSpace])
    XCTAssertEqual(window.toolbar?.items.map(\.itemIdentifier), initialToolbarIdentifiers)
    XCTAssertEqual(realizedSidebarToggleCount(in: window.toolbar), 1)
    assertVisibleToolbarGeometry(in: window)
    XCTAssertFalse(
      realizedToolbarView(in: window.toolbar)?.appNameLabel.isAccessibilityElement() ?? true)
    XCTAssertFalse(
      realizedToolbarView(in: window.toolbar)?.conversationTitleLabel.isAccessibilityElement()
        ?? true)
    XCTAssertFalse(
      window.toolbar?.items.contains(where: {
        $0.itemIdentifier == .toggleSidebar
      }) ?? true)
    _ = controller
  }

  func testWindowToolbarTitleComposesAppIdentityAndConversationTitle() {
    let presentation = MainWindowTitlePresentation(conversationTitle: "Conversation title")

    XCTAssertEqual(presentation.appName, "Vivi")
    XCTAssertEqual(presentation.conversationTitle, "Conversation title")
    XCTAssertEqual(presentation.accessibilityLabel, "Vivi, Conversation title")
  }

  @MainActor
  private func realizedSidebarToggleCount(in toolbar: NSToolbar?) -> Int {
    toolbar?.items.reduce(into: 0) { count, item in
      guard let view = item.view as? MainWindowToolbarView,
        view.sidebarButton.action == #selector(NSSplitViewController.toggleSidebar(_:))
      else {
        return
      }
      count += 1
    } ?? 0
  }

  @MainActor
  private func sidebarToggleButton(in toolbar: NSToolbar?) -> NSButton? {
    realizedToolbarView(in: toolbar)?.sidebarButton
  }

  @MainActor
  private func realizedToolbarView(in toolbar: NSToolbar?) -> MainWindowToolbarView? {
    toolbar?.items.lazy
      .compactMap { $0.view as? MainWindowToolbarView }
      .first
  }

  @MainActor
  private func layoutTitlebar(in window: NSWindow) {
    window.contentViewController?.view.layoutSubtreeIfNeeded()
    window.contentView?.superview?.layoutSubtreeIfNeeded()
    realizedToolbarView(in: window.toolbar)?.layoutSubtreeIfNeeded()
  }

  @MainActor
  private func assertVisibleToolbarGeometry(
    in window: NSWindow,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let toolbarView = realizedToolbarView(in: window.toolbar) else {
      XCTFail("Missing realized Vivi toolbar", file: file, line: line)
      return
    }
    let toggleFrame = toolbarView.convert(
      toolbarView.sidebarButton.bounds, from: toolbarView.sidebarButton)
    let appNameFrame = toolbarView.convert(
      toolbarView.appNameLabel.bounds, from: toolbarView.appNameLabel)
    let separatorFrame = toolbarView.convert(
      toolbarView.separator.bounds, from: toolbarView.separator)
    let titleFrame = toolbarView.convert(
      toolbarView.conversationTitleLabel.bounds,
      from: toolbarView.conversationTitleLabel)

    XCTAssertFalse(toolbarView.sidebarButton.isHidden, file: file, line: line)
    XCTAssertFalse(toolbarView.appNameLabel.isHidden, file: file, line: line)
    XCTAssertFalse(toolbarView.separator.isHidden, file: file, line: line)
    XCTAssertFalse(toolbarView.conversationTitleLabel.isHidden, file: file, line: line)
    XCTAssertGreaterThan(toggleFrame.width, 0, file: file, line: line)
    XCTAssertGreaterThan(appNameFrame.width, 0, file: file, line: line)
    XCTAssertGreaterThan(separatorFrame.width, 0, file: file, line: line)
    XCTAssertGreaterThan(titleFrame.width, 0, file: file, line: line)
    XCTAssertLessThan(toggleFrame.maxX, appNameFrame.minX, file: file, line: line)
    XCTAssertLessThan(appNameFrame.maxX, separatorFrame.minX, file: file, line: line)
    XCTAssertLessThan(separatorFrame.maxX, titleFrame.minX, file: file, line: line)
    XCTAssertEqual(visibleSidebarToggleCount(in: window), 1, file: file, line: line)
    XCTAssertTrue(visibleNativeTitleLabels(in: window, excluding: toolbarView).isEmpty)
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
    excluding toolbarView: MainWindowToolbarView
  ) -> [NSTextField] {
    descendantViews(of: NSTextField.self, below: window.contentView?.superview).filter {
      $0 !== toolbarView.appNameLabel
        && $0 !== toolbarView.conversationTitleLabel
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
