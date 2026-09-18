import AppKit
import Combine
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
  private let windows: ChatWindowManaging
  private var isTerminating = false

  override init() {
    self.windows = ChatWindowRegistry()
    super.init()
  }

  init(windows: ChatWindowManaging) {
    self.windows = windows
    super.init()
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      guard let request = nativeChatRequest(from: url) else { continue }
      windows.open(request: request)
    }
  }

  func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
    windows.reopenLast()
    return true
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows _: Bool
  ) -> Bool {
    windows.reopenLast()
    return false
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
func restoreWindow(_ controller: NSWindowController) {
  if controller.window?.isMiniaturized == true {
    controller.window?.deminiaturize(nil)
  }
  controller.showWindow(nil)
}

@MainActor
protocol ChatWindowManaging {
  var isEmpty: Bool { get }

  func open(request: NativeChatRequest)
  func reopenLast()
  func closeAll(completion: @escaping @MainActor () -> Void)
}

@MainActor
protocol ChatWindowControlling: AnyObject {
  var id: UUID { get }
  var isClosing: Bool { get }

  func restore()
  func closeForTermination(completion: @escaping @MainActor () -> Void)
}

@MainActor
final class ChatWindowRegistry {
  typealias ControllerFactory =
    @MainActor (
      UUID,
      String,
      @escaping @MainActor (UUID) -> Void
    ) -> any ChatWindowControlling

  private var controllers: [UUID: any ChatWindowControlling] = [:]
  private var lastRequest: NativeChatRequest
  private let makeController: ControllerFactory

  init(
    homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
    makeController: @escaping ControllerFactory = { id, workspace, onClosed in
      ChatWindowController(id: id, workspace: workspace, onClosed: onClosed)
    }
  ) {
    self.lastRequest = NativeChatRequest(workspace: homeDirectory)
    self.makeController = makeController
  }

  var isEmpty: Bool {
    controllers.isEmpty
  }

  func open(request: NativeChatRequest) {
    lastRequest = request
    let id = UUID()
    let controller = makeController(id, request.workspace) { [weak self] id in
      self?.controllers.removeValue(forKey: id)
    }
    controllers[id] = controller
    controller.restore()
    NSApp.activate(ignoringOtherApps: true)
  }

  func reopenLast() {
    let reusable = controllers.values.filter { !$0.isClosing }
    if !reusable.isEmpty {
      for controller in reusable {
        controller.restore()
      }
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    open(request: lastRequest)
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

extension ChatWindowRegistry: ChatWindowManaging {}

@MainActor
private final class ChatWindowController: NSWindowController, NSWindowDelegate {
  let id: UUID
  private let store: NativeChatStore
  private let onClosed: @MainActor (UUID) -> Void
  private var closeStarted = false
  private var titleObservation: AnyCancellable?

  var isClosing: Bool {
    closeStarted
  }

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
    titleObservation = store.$activePresentation
      .map(\.sessionTitle)
      .removeDuplicates()
      .sink { [weak window] title in
        window?.title = title
      }
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

  func restore() {
    restoreWindow(self)
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

extension ChatWindowController: ChatWindowControlling {}
