import AppKit
import SwiftUI
import XCTest

@testable import Vivi

@MainActor
final class MainWindowControllerTests: XCTestCase {
  func testTitlebarHasOneNativeSidebarControlBeforeHosting() {
    let conversations = ConversationCollection()
    let window = TitlebarRecordingWindow()
    let applicationCoordinator = testApplicationCoordinator(conversations: conversations)
    let controller = MainWindowController(
      identity: .primary,
      applicationCoordinator: applicationCoordinator,
      window: window,
      activate: {},
      onClosed: { _ in })

    XCTAssertTrue(window.hadTitlebarAccessoryBeforeContentViewController)
    XCTAssertEqual(
      window.titlebarAccessoryViewControllers.compactMap { ($0.view as? NSButton)?.action },
      [#selector(NSSplitViewController.toggleSidebar(_:))])
    XCTAssertEqual(window.title, "Vivi")
    XCTAssertEqual(window.titleVisibility, .visible)
    XCTAssertTrue(window.contentViewController is NSHostingController<MainWindowView>)
    _ = controller
  }

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

    XCTAssertEqual(window.title, "Vivi | New conversation")
    firstDriver.send(.sessionTitle("First renamed"))
    XCTAssertEqual(window.title, "Vivi | New conversation")
    conversations.select(first.id)
    XCTAssertEqual(window.title, "Vivi | First renamed")
    firstDriver.send(.sessionTitle("First final"))
    XCTAssertEqual(window.title, "Vivi | First final")
    let resumedKey = ResumeKey(generation: 42, slot: 7)
    let resumedSummary = SessionSummary(
      key: resumedKey,
      workingDirectory: "/tmp/resumed",
      title: "resumed",
      isCurrent: false)
    let selectedModel = ModelSelection(modelID: "test", reasoning: .off)
    firstDriver.send(.ready)
    firstDriver.send(
      .modelCatalog(
        ModelCatalog(
          selected: selectedModel,
          models: [
            ModelInfo(
              id: selectedModel.modelID,
              displayName: "Test",
              maxContextWindowTokens: 0,
              maxOutputTokens: 0,
              supportsVision: false,
              reasoning: [.off],
              advertisedDefaultReasoning: .off)
          ])))
    first.store.refreshSessions()
    firstDriver.send(.sessionCatalog(SessionCatalog(sessions: [resumedSummary])))
    first.store.resumeSession(resumedKey)
    firstDriver.send(
      .sessionResume(
        .resumed(
          ResumedSession(
            summary: resumedSummary,
            transcript: [],
            cleanupFailed: false))))
    XCTAssertEqual(window.title, "Vivi | New conversation")
    _ = controller
  }

  func testRenderedTitlebarStaysSingleOwnerAcrossSidebarToggle() throws {
    let conversations = ConversationCollection()
    conversations.appendAndSelect(
      ConversationRecord(
        id: ConversationID(rawValue: UUID()),
        launchWorkspace: WorkspaceIdentity(absolutePath: "/tmp/project")!,
        store: NativeChatStore(
          workspace: "/tmp/project",
          driver: ControllableConversationDriver())))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    let applicationCoordinator = testApplicationCoordinator(conversations: conversations)
    let controller = MainWindowController(
      identity: .primary,
      applicationCoordinator: applicationCoordinator,
      window: window,
      activate: {},
      onClosed: { _ in })
    let hostingController = window.contentViewController

    controller.showAndActivate()
    window.contentView?.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    let splitView = try XCTUnwrap(
      window.contentView?.firstDescendant(ofType: NSSplitView.self))
    let sidebarButton = try XCTUnwrap(
      window.titlebarAccessoryViewControllers.compactMap { $0.view as? NSButton }.first)
    XCTAssertNotNil(sidebarButton.action)

    XCTAssertEqual(
      window.titlebarAccessoryViewControllers.compactMap { $0.view as? NSButton }.count,
      1)
    XCTAssertEqual(window.title, "Vivi | New conversation")
    XCTAssertTrue(window.contentViewController === hostingController)
    XCTAssertFalse(splitView.isSubviewCollapsed(splitView.arrangedSubviews[0]))

    XCTAssertTrue(sidebarButton.accessibilityPerformPress())
    window.contentView?.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))

    XCTAssertEqual(
      window.titlebarAccessoryViewControllers.compactMap { $0.view as? NSButton }.count,
      1)
    XCTAssertEqual(window.title, "Vivi | New conversation")
    XCTAssertTrue(window.contentViewController === hostingController)
    XCTAssertTrue(splitView.isSubviewCollapsed(splitView.arrangedSubviews[0]))
    controller.close()
  }

  func testRecreatedWindowRestoresSelectedTitleAndNativeTitlebar() {
    let driver = ControllableConversationDriver()
    let conversations = ConversationCollection()
    conversations.appendAndSelect(
      ConversationRecord(
        id: ConversationID(rawValue: UUID()),
        launchWorkspace: WorkspaceIdentity(absolutePath: "/tmp/project")!,
        store: NativeChatStore(workspace: "/tmp/project", driver: driver)))
    driver.send(.sessionTitle("Restored title"))
    let applicationCoordinator = testApplicationCoordinator(conversations: conversations)
    let firstWindow = NSWindow()
    var firstController: MainWindowController? = MainWindowController(
      identity: .primary,
      applicationCoordinator: applicationCoordinator,
      window: firstWindow,
      activate: {},
      onClosed: { _ in })

    XCTAssertEqual(firstWindow.title, "Vivi | Restored title")
    firstController?.close()
    firstController = nil

    let reopenedWindow = NSWindow()
    let reopenedController = MainWindowController(
      identity: .primary,
      applicationCoordinator: applicationCoordinator,
      window: reopenedWindow,
      activate: {},
      onClosed: { _ in })

    XCTAssertEqual(reopenedWindow.title, "Vivi | Restored title")
    XCTAssertEqual(
      reopenedWindow.titlebarAccessoryViewControllers.compactMap {
        ($0.view as? NSButton)?.action
      },
      [#selector(NSSplitViewController.toggleSidebar(_:))])
    _ = reopenedController
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
        accessibilityLabel: "app, /one/app, project"))
    XCTAssertEqual(
      projectSidebarPresentation(workspace: unique, allWorkspaces: [first, second, unique]),
      ProjectSidebarPresentation(
        name: "other",
        visiblePath: nil,
        accessibilityLabel: "other, /work/other, project"))
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

extension NSView {
  fileprivate func firstDescendant<View: NSView>(ofType type: View.Type) -> View? {
    if let view = self as? View {
      return view
    }
    return subviews.lazy.compactMap { $0.firstDescendant(ofType: type) }.first
  }
}

private final class TitlebarRecordingWindow: NSWindow {
  private(set) var hadTitlebarAccessoryBeforeContentViewController = false

  override var contentViewController: NSViewController? {
    didSet {
      if contentViewController != nil {
        hadTitlebarAccessoryBeforeContentViewController =
          titlebarAccessoryViewControllers.count == 1
      }
    }
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
