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
    conversations: ConversationCollection,
    window: NSWindow = MainWindowController.makeWindow(),
    activate: @escaping @MainActor () -> Void = {
      NSApp.activate(ignoringOtherApps: true)
    },
    onClosed: @escaping @MainActor (MainWindowIdentity) -> Void
  ) {
    self.identity = identity
    self.conversations = conversations
    self.activate = activate
    self.onClosed = onClosed
    super.init(window: window)

    window.title = "Vivi"
    window.contentViewController = NSHostingController(
      rootView: MainWindowView(conversations: conversations))
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
    window?.title = conversation.navigation.title
    titleObservation = conversation.$navigation
      .map(\.title)
      .removeDuplicates()
      .sink { [weak window] title in
        window?.title = title
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
