import AppKit
import Combine
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, MainWindowControlling {
  let identity: MainWindowIdentity

  private let activate: @MainActor () -> Void
  private let onClosed: @MainActor (MainWindowIdentity) -> Void
  private let titlebarAccessory = MainWindowTitlebarAccessoryController()
  private let sidebarPresentation = MainWindowSidebarPresentation()
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
    let conversations = applicationCoordinator.conversations
    self.activate = activate
    self.onClosed = onClosed
    super.init(window: window)

    window.title = "Vivi"
    window.contentViewController = NSHostingController(
      rootView: MainWindowView(
        conversations: conversations,
        applicationPresentation: applicationCoordinator.presentation,
        sidebarPresentation: sidebarPresentation,
        requestNewConversation: { [weak applicationCoordinator] in
          applicationCoordinator?.requestNewConversation()
        },
        dismissWorkspaceChoiceFailure: { [weak applicationCoordinator] in
          applicationCoordinator?.dismissWorkspaceChoiceFailure()
        }))
    // Realize SwiftUI's split-view chrome before replacing it with the owned accessory.
    window.contentViewController?.view.layoutSubtreeIfNeeded()
    titlebarAccessory.sidebarButton.target = self
    titlebarAccessory.sidebarButton.action = #selector(toggleSidebar(_:))
    installTitlebarAccessory(in: window)
    window.delegate = self
    window.setFrameAutosaveName("ViviMainWindow")
    selectionObservation = conversations.$selectedID
      .removeDuplicates()
      .sink { [weak self] selectedID in
        self?.bindSelectedTitle(selectedID, in: conversations)
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
    if let window {
      window.contentViewController?.view.layoutSubtreeIfNeeded()
      installTitlebarAccessory(in: window)
      window.contentView?.superview?.layoutSubtreeIfNeeded()
    }
    window?.makeKeyAndOrderFront(nil)
    activate()
  }

  func windowWillClose(_ notification: Notification) {
    guard !closingForTermination else { return }
    onClosed(identity)
  }

  func windowDidUpdate(_ notification: Notification) {
    guard let window else { return }
    installTitlebarAccessory(in: window)
  }

  func closeForTermination() {
    closingForTermination = true
    window?.orderOut(nil)
    close()
  }

  @objc private func toggleSidebar(_ sender: Any?) {
    sidebarPresentation.toggle()
    DispatchQueue.main.async { [weak self] in
      guard let self, let window = self.window else { return }
      self.installTitlebarAccessory(in: window)
    }
  }

  private func installTitlebarAccessory(in window: NSWindow) {
    window.toolbar = nil
    window.titleVisibility = .hidden
    guard !window.titlebarAccessoryViewControllers.contains(where: { $0 === titlebarAccessory })
    else {
      return
    }
    window.addTitlebarAccessoryViewController(titlebarAccessory)
  }

  private func bindSelectedTitle(
    _ selectedID: ConversationID?,
    in conversations: ConversationCollection
  ) {
    titleObservation = nil
    guard let selectedID,
      let conversation = conversations.records.first(where: { $0.id == selectedID })
    else {
      titlebarAccessory.presentation = MainWindowTitlePresentation(conversationTitle: nil)
      return
    }
    titlebarAccessory.presentation = MainWindowTitlePresentation(
      conversationTitle: conversation.navigation.title)
    titleObservation = conversation.$navigation
      .map(\.title)
      .removeDuplicates()
      .sink { [weak titlebarAccessory] title in
        titlebarAccessory?.presentation = MainWindowTitlePresentation(conversationTitle: title)
      }
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
final class MainWindowTitlebarAccessoryController: NSTitlebarAccessoryViewController {
  let sidebarButton: NSButton
  let appNameLabel = NSTextField(labelWithString: "")
  let separator = NSBox()
  let conversationTitleLabel = NSTextField(labelWithString: "")
  private let stackView: NSStackView

  var presentation = MainWindowTitlePresentation(conversationTitle: nil) {
    didSet {
      updatePresentation()
    }
  }

  init() {
    sidebarButton = NSButton(
      image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)!,
      target: nil,
      action: nil)
    sidebarButton.isBordered = false
    sidebarButton.toolTip = "Toggle Sidebar"
    sidebarButton.setAccessibilityLabel("Toggle Sidebar")
    sidebarButton.identifier = NSUserInterfaceItemIdentifier("toggle-sidebar")

    appNameLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    appNameLabel.setContentHuggingPriority(.required, for: .horizontal)
    appNameLabel.setAccessibilityElement(false)

    separator.boxType = .separator
    separator.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      separator.widthAnchor.constraint(equalToConstant: 1),
      separator.heightAnchor.constraint(equalToConstant: 16),
    ])

    conversationTitleLabel.textColor = .secondaryLabelColor
    conversationTitleLabel.lineBreakMode = .byTruncatingTail
    conversationTitleLabel.maximumNumberOfLines = 1
    conversationTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    conversationTitleLabel.setAccessibilityElement(false)

    stackView = NSStackView(
      views: [sidebarButton, appNameLabel, separator, conversationTitleLabel])
    stackView.orientation = .horizontal
    stackView.alignment = .centerY
    stackView.spacing = 8
    stackView.translatesAutoresizingMaskIntoConstraints = false

    super.init(nibName: nil, bundle: nil)
    layoutAttribute = .left
    view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 32))
    preferredContentSize = NSSize(width: 320, height: 32)
    view.addSubview(stackView)
    NSLayoutConstraint.activate([
      stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      stackView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      view.widthAnchor.constraint(equalToConstant: 320),
    ])
    updatePresentation()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  private func updatePresentation() {
    appNameLabel.stringValue = presentation.appName
    conversationTitleLabel.stringValue = presentation.conversationTitle
    stackView.setAccessibilityRole(.group)
    stackView.setAccessibilityLabel(presentation.accessibilityLabel)
    stackView.identifier = NSUserInterfaceItemIdentifier("window-title")
  }
}
