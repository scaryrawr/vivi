import AppKit
import Combine
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
  MainWindowControlling
{
  let identity: MainWindowIdentity

  private let activate: @MainActor () -> Void
  private let onClosed: @MainActor (MainWindowIdentity) -> Void
  private let toolbarView = MainWindowToolbarView()
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
        requestNewConversation: { [weak applicationCoordinator] in
          applicationCoordinator?.requestNewConversation()
        },
        dismissWorkspaceChoiceFailure: { [weak applicationCoordinator] in
          applicationCoordinator?.dismissWorkspaceChoiceFailure()
        }))
    // Realize SwiftUI's split-view toolbar before replacing it with the owned toolbar.
    window.contentViewController?.view.layoutSubtreeIfNeeded()
    installToolbar(in: window)
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

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.viviNavigation, .flexibleSpace]
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.viviNavigation, .flexibleSpace]
  }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    guard itemIdentifier == .viviNavigation else { return nil }
    let item = NSToolbarItem(itemIdentifier: itemIdentifier)
    item.label = "Window Navigation"
    item.paletteLabel = "Window Navigation"
    item.view = toolbarView
    return item
  }

  private func installToolbar(in window: NSWindow) {
    let toolbar = NSToolbar(identifier: "ViviMainToolbar")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    toolbar.autosavesConfiguration = false
    window.toolbar = toolbar
    window.toolbarStyle = .unified
    window.titleVisibility = .hidden
  }

  private func bindSelectedTitle(
    _ selectedID: ConversationID?,
    in conversations: ConversationCollection
  ) {
    titleObservation = nil
    guard let selectedID,
      let conversation = conversations.records.first(where: { $0.id == selectedID })
    else {
      toolbarView.presentation = MainWindowTitlePresentation(conversationTitle: nil)
      return
    }
    toolbarView.presentation = MainWindowTitlePresentation(
      conversationTitle: conversation.navigation.title)
    titleObservation = conversation.$navigation
      .map(\.title)
      .removeDuplicates()
      .sink { [weak toolbarView] title in
        toolbarView?.presentation = MainWindowTitlePresentation(conversationTitle: title)
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

extension NSToolbarItem.Identifier {
  static let viviNavigation = Self("ViviNavigation")
}

@MainActor
final class MainWindowToolbarView: NSView {
  let sidebarButton: NSButton
  private let appNameLabel = NSTextField(labelWithString: "")
  private let conversationTitleLabel = NSTextField(labelWithString: "")
  private let stackView: NSStackView

  var presentation = MainWindowTitlePresentation(conversationTitle: nil) {
    didSet {
      updatePresentation()
    }
  }

  override init(frame frameRect: NSRect) {
    sidebarButton = NSButton(
      image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)!,
      target: nil,
      action: #selector(NSSplitViewController.toggleSidebar(_:)))
    sidebarButton.isBordered = false
    sidebarButton.toolTip = "Toggle Sidebar"
    sidebarButton.setAccessibilityLabel("Toggle Sidebar")
    sidebarButton.identifier = NSUserInterfaceItemIdentifier("toggle-sidebar")

    appNameLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    appNameLabel.setContentHuggingPriority(.required, for: .horizontal)

    let separator = NSBox()
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

    stackView = NSStackView(
      views: [sidebarButton, appNameLabel, separator, conversationTitleLabel])
    stackView.orientation = .horizontal
    stackView.alignment = .centerY
    stackView.spacing = 8
    stackView.translatesAutoresizingMaskIntoConstraints = false

    super.init(frame: frameRect)
    addSubview(stackView)
    NSLayoutConstraint.activate([
      stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
      stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
      widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
      widthAnchor.constraint(lessThanOrEqualToConstant: 420),
    ])
    updatePresentation()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: 320, height: 28)
  }

  private func updatePresentation() {
    appNameLabel.stringValue = presentation.appName
    conversationTitleLabel.stringValue = presentation.conversationTitle
    stackView.setAccessibilityRole(.group)
    stackView.setAccessibilityLabel(presentation.accessibilityLabel)
    stackView.identifier = NSUserInterfaceItemIdentifier("window-title")
  }
}
