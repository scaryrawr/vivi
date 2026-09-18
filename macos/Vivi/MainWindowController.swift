import AppKit
import Combine
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, MainWindowControlling {
  let identity: MainWindowIdentity

  private let conversations: ConversationCollection
  private let activate: @MainActor () -> Void
  private let onClosed: @MainActor (MainWindowIdentity) -> Void
  private var selectionObservation: AnyCancellable?
  private var titleObservation: AnyCancellable?
  private var closingForTermination = false

  init(
    identity: MainWindowIdentity,
    applicationCoordinator: NativeApplicationCoordinator,
    window: NSWindow = MainWindowController.makeWindow(),
    activate: @escaping @MainActor () -> Void = {
      NSApp.activate(ignoringOtherApps: true)
    },
    onClosed: @escaping @MainActor (MainWindowIdentity) -> Void
  ) {
    self.identity = identity
    conversations = applicationCoordinator.conversations
    self.activate = activate
    self.onClosed = onClosed
    super.init(window: window)

    Self.configureTitlebar(of: window)
    window.contentViewController = NSHostingController(
      rootView: MainWindowView(
        conversations: conversations,
        applicationPresentation: applicationCoordinator.presentation,
        requestNewConversation: { [weak applicationCoordinator] in
          applicationCoordinator?.requestNewConversation()
        },
        dismissWorkspaceChoiceFailure: { [weak applicationCoordinator] in
          applicationCoordinator?.dismissWorkspaceChoiceFailure()
        }))
    window.delegate = self
    window.setFrameAutosaveName("ViviMainWindow")
    selectionObservation = conversations.$selectedID
      .removeDuplicates()
      .sink { [weak self] selectedID in
        self?.bindSelectedTitle(selectedID)
      }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  func showAndActivate() {
    if window?.isMiniaturized == true {
      window?.deminiaturize(nil)
    }
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    activate()
  }

  func windowWillClose(_ notification: Notification) {
    guard !closingForTermination else { return }
    onClosed(identity)
  }

  func closeForTermination() {
    closingForTermination = true
    window?.orderOut(nil)
    close()
  }

  private func bindSelectedTitle(_ selectedID: ConversationID?) {
    titleObservation = nil
    guard let selectedID,
      let conversation = conversations.records.first(where: { $0.id == selectedID })
    else {
      window?.title = "Vivi"
      return
    }
    window?.title = Self.windowTitle(for: conversation)
    titleObservation = conversation.$navigation
      .map { [weak conversation] navigation in
        guard let conversation else { return "Vivi" }
        return Self.windowTitle(
          conversationTitle: navigation.title,
          workspace: conversation.launchWorkspace)
      }
      .removeDuplicates()
      .sink { [weak window] title in
        window?.title = title
      }
  }

  private static func configureTitlebar(of window: NSWindow) {
    let sidebarButton = SidebarToggleButton(
      image: NSImage(
        systemSymbolName: "sidebar.left",
        accessibilityDescription: "Toggle Sidebar")!,
      target: nil,
      action: #selector(NSSplitViewController.toggleSidebar(_:)))
    sidebarButton.bezelStyle = .toolbar
    sidebarButton.imagePosition = .imageOnly
    sidebarButton.toolTip = "Toggle Sidebar"
    sidebarButton.setAccessibilityLabel("Toggle Sidebar")
    sidebarButton.frame.size = NSSize(width: 36, height: 28)

    let accessory = NSTitlebarAccessoryViewController()
    accessory.layoutAttribute = .leading
    accessory.view = sidebarButton

    window.title = "Vivi"
    window.titleVisibility = .visible
    window.addTitlebarAccessoryViewController(accessory)
  }

  private static func windowTitle(for conversation: ConversationRecord) -> String {
    windowTitle(
      conversationTitle: conversation.navigation.title,
      workspace: conversation.launchWorkspace)
  }

  private static func windowTitle(
    conversationTitle: String,
    workspace: WorkspaceIdentity
  ) -> String {
    let lastPathComponent =
      URL(fileURLWithPath: workspace.canonicalPath)
      .lastPathComponent
    let projectName = lastPathComponent.isEmpty ? "/" : lastPathComponent
    let displayedTitle = sidebarRowPresentation(
      title: conversationTitle,
      projectName: projectName,
      duplicate: nil
    ).title
    return "Vivi | \(displayedTitle)"
  }

  private static func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.minSize = NSSize(width: 760, height: 500)
    window.tabbingMode = .disallowed
    window.center()
    return window
  }
}

@MainActor
private final class SidebarToggleButton: NSButton {
  override func accessibilityPerformPress() -> Bool {
    guard let action else { return false }
    return NSApp.sendAction(action, to: target, from: self)
  }
}
