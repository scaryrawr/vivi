import AppKit
import SwiftUI

@main
struct ViviApp: App {
  @NSApplicationDelegateAdaptor(ViviAppDelegate.self) private var appDelegate

  var body: some Scene {
    Settings {
      EmptyView()
    }
  }
}

@MainActor
final class ViviAppDelegate: NSObject, NSApplicationDelegate {
  private let windows = ChatWindowRegistry()
  private var isTerminating = false

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      guard let request = nativeChatRequest(from: url) else { continue }
      windows.open(request: request)
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !windows.isEmpty else { return .terminateNow }
    guard !isTerminating else { return .terminateLater }
    isTerminating = true
    windows.closeAll {
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

struct NativeChatRequest: Equatable {
  let workspace: String
}

func nativeChatRequest(from url: URL) -> NativeChatRequest? {
  guard url.scheme == "vivi", url.host == "chat",
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
    let workspace = components.queryItems?.first(where: { $0.name == "workspace" })?.value,
    workspace.hasPrefix("/")
  else { return nil }
  return NativeChatRequest(workspace: workspace)
}

@MainActor
private final class ChatWindowRegistry {
  private var controllers: [UUID: ChatWindowController] = [:]

  var isEmpty: Bool {
    controllers.isEmpty
  }

  func open(request: NativeChatRequest) {
    let id = UUID()
    let controller = ChatWindowController(
      id: id,
      workspace: request.workspace,
      onClosed: { [weak self] id in
        self?.controllers.removeValue(forKey: id)
      })
    controllers[id] = controller
    controller.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func closeAll(completion: @escaping @MainActor () -> Void) {
    let active = Array(controllers.values)
    guard !active.isEmpty else {
      completion()
      return
    }
    let group = DispatchGroup()
    for controller in active {
      group.enter()
      controller.closeForTermination { [weak self] in
        self?.controllers.removeValue(forKey: controller.id)
        group.leave()
      }
    }
    group.notify(queue: .main) {
      completion()
    }
  }
}

@MainActor
private final class ChatWindowController: NSWindowController, NSWindowDelegate {
  let id: UUID
  private let store: NativeChatStore
  private let onClosed: @MainActor (UUID) -> Void
  private var closeStarted = false

  init(
    id: UUID,
    workspace: String,
    onClosed: @escaping @MainActor (UUID) -> Void
  ) {
    self.id = id
    self.store = NativeChatStore(
      workspace: workspace,
      driver: ViviConversationDriver(workspace: workspace)
    )
    self.onClosed = onClosed
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    super.init(window: window)
    window.title = workspace
    window.contentViewController = NSHostingController(rootView: ContentView(store: store))
    window.center()
    window.delegate = self
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  func windowWillClose(_ notification: Notification) {
    finishClose()
  }

  func closeForTermination(completion: @escaping @MainActor () -> Void) {
    window?.orderOut(nil)
    finishClose(completion: completion)
  }

  private func finishClose(completion: (@MainActor () -> Void)? = nil) {
    guard !closeStarted else {
      if let completion {
        store.close(completion: completion)
      }
      return
    }
    closeStarted = true
    store.close { [id, onClosed] in
      onClosed(id)
      completion?()
    }
  }
}
