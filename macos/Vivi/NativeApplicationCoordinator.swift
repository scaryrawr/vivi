import AppKit
import Combine
import Foundation

struct WorkspaceIdentity: Hashable, Sendable {
  let canonicalPath: String

  init?(absolutePath: String) {
    guard absolutePath.first == "/", !absolutePath.utf8.contains(0) else { return nil }

    var components: [Substring] = []
    for component in absolutePath.split(separator: "/", omittingEmptySubsequences: true) {
      switch component {
      case ".":
        continue
      case "..":
        if !components.isEmpty {
          components.removeLast()
        }
      default:
        components.append(component)
      }
    }
    canonicalPath = components.isEmpty ? "/" : "/" + components.joined(separator: "/")
  }
}

struct ConversationID: Hashable, Sendable {
  let rawValue: UUID
}

enum MainWindowIdentity: Hashable, Sendable {
  case primary
}

struct NativeChatRequest: Equatable, Sendable {
  let workspace: WorkspaceIdentity

  init?(url: URL) {
    guard url.scheme == "vivi", url.host == "chat",
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let workspace = components.queryItems?.first(where: { $0.name == "workspace" })?.value,
      let identity = WorkspaceIdentity(absolutePath: workspace)
    else { return nil }
    self.workspace = identity
  }
}

struct ConversationNavigation: Equatable, Sendable {
  let workspace: WorkspaceIdentity
  let title: String

  init(workspacePath: String, title: String) {
    guard let workspace = WorkspaceIdentity(absolutePath: workspacePath) else {
      preconditionFailure("NativeChatStore workspace must remain an absolute path")
    }
    self.workspace = workspace
    self.title = title
  }
}

@MainActor
extension NativeChatStore {
  var conversationNavigation: ConversationNavigation {
    ConversationNavigation(workspacePath: workspace, title: sessionTitle)
  }

  var conversationNavigationPublisher: AnyPublisher<ConversationNavigation, Never> {
    $activePresentation
      .map { presentation in
        ConversationNavigation(
          workspacePath: presentation.workspace,
          title: presentation.sessionTitle)
      }
      .eraseToAnyPublisher()
  }
}

@MainActor
final class ConversationRecord: ObservableObject, Identifiable {
  let id: ConversationID
  let store: NativeChatStore
  @Published private(set) var navigation: ConversationNavigation

  private var navigationObservation: AnyCancellable?

  init(id: ConversationID, store: NativeChatStore) {
    self.id = id
    self.store = store
    navigation = store.conversationNavigation
    navigationObservation = store.conversationNavigationPublisher
      .removeDuplicates()
      .sink { [weak self] navigation in
        self?.navigation = navigation
      }
  }
}

@MainActor
final class ConversationCollection: ObservableObject {
  @Published private(set) var records: [ConversationRecord] = []
  @Published private(set) var selectedID: ConversationID?

  private var recordObservations: [ConversationID: AnyCancellable] = [:]

  var selectedConversation: ConversationRecord? {
    guard let selectedID else { return nil }
    return records.first(where: { $0.id == selectedID })
  }

  func appendAndSelect(_ record: ConversationRecord) {
    precondition(!records.contains(where: { $0.id == record.id }))
    recordObservations[record.id] = record.$navigation
      .map(\.workspace)
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in self?.objectWillChange.send() }
    records.append(record)
    selectedID = record.id
  }

  func select(_ id: ConversationID) {
    guard records.contains(where: { $0.id == id }) else { return }
    selectedID = id
  }

  func duplicatePosition(for id: ConversationID) -> (ordinal: Int, total: Int)? {
    guard let record = records.first(where: { $0.id == id }) else { return nil }
    let matches = records.filter {
      $0.navigation.workspace == record.navigation.workspace
    }
    guard matches.count > 1,
      let index = matches.firstIndex(where: { $0.id == id })
    else { return nil }
    return (index + 1, matches.count)
  }
}

@MainActor
protocol MainWindowControlling: AnyObject {
  var identity: MainWindowIdentity { get }
  func showAndActivate()
  func closeForTermination()
}

@MainActor
final class NativeApplicationCoordinator {
  typealias ConversationFactory = (ConversationID, WorkspaceIdentity) -> ConversationRecord
  typealias WindowFactory = (
    MainWindowIdentity,
    ConversationCollection,
    @escaping @MainActor (MainWindowIdentity) -> Void
  ) -> any MainWindowControlling

  enum State {
    case running
    case terminating
    case terminated
  }

  let conversations: ConversationCollection

  private let makeConversationID: () -> ConversationID
  private let makeConversation: ConversationFactory
  private let makeWindow: WindowFactory
  private var mainWindow: (any MainWindowControlling)?
  private var state = State.running
  private var pendingTermination: Set<ConversationID> = []
  private var terminationReply: (@MainActor () -> Void)?

  init(
    conversations: ConversationCollection = ConversationCollection(),
    makeConversationID: @escaping () -> ConversationID,
    makeConversation: @escaping ConversationFactory,
    makeWindow: @escaping WindowFactory
  ) {
    self.conversations = conversations
    self.makeConversationID = makeConversationID
    self.makeConversation = makeConversation
    self.makeWindow = makeWindow
  }

  static func live() -> NativeApplicationCoordinator {
    NativeApplicationCoordinator(
      makeConversationID: { ConversationID(rawValue: UUID()) },
      makeConversation: { id, workspace in
        let path = workspace.canonicalPath
        return ConversationRecord(
          id: id,
          store: NativeChatStore(
            workspace: path,
            driver: ViviConversationDriver(workspace: path)))
      },
      makeWindow: { identity, conversations, onClosed in
        MainWindowController(
          identity: identity,
          conversations: conversations,
          onClosed: onClosed)
      })
  }

  func open(_ urls: [URL]) {
    guard state == .running else { return }

    var openedConversation = false
    for url in urls {
      guard let request = NativeChatRequest(url: url) else { continue }
      let record = makeConversation(makeConversationID(), request.workspace)
      conversations.appendAndSelect(record)
      openedConversation = true
    }
    if openedConversation {
      presentMainWindow()
    }
  }

  func presentMainWindow() {
    guard state == .running else { return }
    if mainWindow == nil {
      mainWindow = makeWindow(.primary, conversations) { [weak self] identity in
        self?.presentationDidClose(identity)
      }
    }
    mainWindow?.showAndActivate()
  }

  func beginTermination(
    reply: @escaping @MainActor () -> Void
  ) -> NSApplication.TerminateReply {
    switch state {
    case .terminated:
      return .terminateNow
    case .terminating:
      return .terminateLater
    case .running:
      break
    }

    mainWindow?.closeForTermination()
    mainWindow = nil
    guard !conversations.records.isEmpty else {
      state = .terminated
      return .terminateNow
    }

    state = .terminating
    pendingTermination = Set(conversations.records.map(\.id))
    terminationReply = reply
    for record in conversations.records {
      let id = record.id
      record.store.close { [weak self] in
        self?.conversationDidClose(id)
      }
    }
    return .terminateLater
  }

  private func presentationDidClose(_ identity: MainWindowIdentity) {
    guard mainWindow?.identity == identity else { return }
    mainWindow = nil
  }

  private func conversationDidClose(_ id: ConversationID) {
    guard state == .terminating, pendingTermination.remove(id) != nil,
      pendingTermination.isEmpty, let reply = terminationReply
    else { return }

    terminationReply = nil
    state = .terminated
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        reply()
      }
    }
  }
}
