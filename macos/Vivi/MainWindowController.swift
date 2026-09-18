import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, MainWindowControlling {
  let identity: MainWindowIdentity

  private let activate: @MainActor () -> Void
  private let onClosed: @MainActor (MainWindowIdentity) -> Void
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
    window.delegate = self
    window.setFrameAutosaveName("ViviMainWindow")
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
