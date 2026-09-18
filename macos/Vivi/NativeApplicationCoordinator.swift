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

struct NativeApplicationConfiguration: Equatable, Sendable {
  let settingsPath: String

  static var live: NativeApplicationConfiguration {
    NativeApplicationConfiguration(
      settingsPath:
        FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".vivi/settings.json").path)
  }
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
  let launchWorkspace: WorkspaceIdentity
  let store: NativeChatStore
  @Published private(set) var navigation: ConversationNavigation

  private var navigationObservation: AnyCancellable?

  init(id: ConversationID, launchWorkspace: WorkspaceIdentity, store: NativeChatStore) {
    self.id = id
    self.launchWorkspace = launchWorkspace
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
  @Published private(set) var launchWorkspaces: [WorkspaceIdentity] = []

  private var recordObservations: [ConversationID: AnyCancellable] = [:]

  var selectedConversation: ConversationRecord? {
    guard let selectedID else { return nil }
    return records.first(where: { $0.id == selectedID })
  }

  func appendAndSelect(_ record: ConversationRecord) {
    precondition(!records.contains(where: { $0.id == record.id }))
    recordObservations[record.id] = record.$navigation
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in self?.objectWillChange.send() }
    if !launchWorkspaces.contains(record.launchWorkspace) {
      launchWorkspaces.append(record.launchWorkspace)
    }
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

  func records(launchedFrom workspace: WorkspaceIdentity) -> [ConversationRecord] {
    records.filter { $0.launchWorkspace == workspace }
  }

  func catalogConversation(launchedFrom workspace: WorkspaceIdentity) -> ConversationRecord? {
    records.first { $0.launchWorkspace == workspace }
  }

  func resume(_ key: ResumeKey, launchedFrom workspace: WorkspaceIdentity) {
    guard let conversation = catalogConversation(launchedFrom: workspace) else { return }
    select(conversation.id)
    conversation.store.resumeSession(key)
  }
}

enum WorkspaceChoicePresentation: Equatable {
  case idle
  case choosing
  case failure(String)

  var isChoosing: Bool {
    self == .choosing
  }
}

@MainActor
final class NativeApplicationPresentation: ObservableObject {
  @Published fileprivate(set) var workspaceChoice = WorkspaceChoicePresentation.idle
}

@MainActor
protocol MainWindowControlling: AnyObject {
  var identity: MainWindowIdentity { get }
  func showAndActivate()
  func closeForTermination()
}

@MainActor
final class NativeApplicationCoordinator {
  typealias ConversationFactory = (
    ConversationID,
    WorkspaceIdentity,
    NativeApplicationConfiguration
  ) -> ConversationRecord
  typealias WorkspaceChooserFactory = () -> any WorkspaceChoosing
  typealias WindowFactory = (
    MainWindowIdentity,
    NativeApplicationCoordinator,
    @escaping @MainActor (MainWindowIdentity) -> Void
  ) -> any MainWindowControlling

  enum State {
    case running
    case terminating
    case terminated
  }

  let conversations: ConversationCollection
  let presentation = NativeApplicationPresentation()

  private let applicationConfiguration: NativeApplicationConfiguration
  private let makeConversationID: () -> ConversationID
  private let makeConversation: ConversationFactory
  private let makeWorkspaceChooser: WorkspaceChooserFactory
  private let makeWindow: WindowFactory
  private var mainWindow: (any MainWindowControlling)?
  private var state = State.running
  private var activeWorkspaceChooser: (any WorkspaceChoosing)?
  private var workspaceChoiceTask: Task<Void, Never>?
  private var pendingTermination: Set<ConversationID> = []
  private var terminationReply: (@MainActor () -> Void)?

  init(
    conversations: ConversationCollection = ConversationCollection(),
    applicationConfiguration: NativeApplicationConfiguration = .live,
    makeConversationID: @escaping () -> ConversationID,
    makeConversation: @escaping ConversationFactory,
    makeWorkspaceChooser: @escaping WorkspaceChooserFactory = {
      AppKitWorkspaceChooser()
    },
    makeWindow: @escaping WindowFactory
  ) {
    self.conversations = conversations
    self.applicationConfiguration = applicationConfiguration
    self.makeConversationID = makeConversationID
    self.makeConversation = makeConversation
    self.makeWorkspaceChooser = makeWorkspaceChooser
    self.makeWindow = makeWindow
  }

  static func live() -> NativeApplicationCoordinator {
    NativeApplicationCoordinator(
      applicationConfiguration: .live,
      makeConversationID: { ConversationID(rawValue: UUID()) },
      makeConversation: { id, workspace, configuration in
        let path = workspace.canonicalPath
        return ConversationRecord(
          id: id,
          launchWorkspace: workspace,
          store: NativeChatStore(
            workspace: path,
            driver: ViviConversationDriver(
              workspace: path,
              applicationConfiguration: configuration)))
      },
      makeWindow: { identity, coordinator, onClosed in
        MainWindowController(
          identity: identity,
          applicationCoordinator: coordinator,
          onClosed: onClosed)
      })
  }

  func open(_ urls: [URL]) {
    guard state == .running else { return }

    var openedConversation = false
    for url in urls {
      guard let request = NativeChatRequest(url: url) else { continue }
      openedConversation = createConversation(in: request.workspace) != nil || openedConversation
    }
    if openedConversation {
      presentMainWindow()
    }
  }

  func requestNewConversation() {
    guard state == .running, activeWorkspaceChooser == nil else { return }

    let chooser = makeWorkspaceChooser()
    activeWorkspaceChooser = chooser
    presentation.workspaceChoice = .choosing
    workspaceChoiceTask = Task { [weak self] in
      guard !Task.isCancelled else { return }
      let selectedURL = await chooser.chooseWorkspace()
      self?.workspaceChoiceDidFinish(selectedURL, chooser: chooser)
    }
  }

  func dismissWorkspaceChoiceFailure() {
    guard case .failure = presentation.workspaceChoice else { return }
    presentation.workspaceChoice = .idle
  }

  @discardableResult
  func createConversation(in workspace: WorkspaceIdentity) -> ConversationRecord? {
    guard state == .running else { return nil }
    let record = makeConversation(makeConversationID(), workspace, applicationConfiguration)
    conversations.appendAndSelect(record)
    return record
  }

  func presentMainWindow() {
    guard state == .running else { return }
    if mainWindow == nil {
      mainWindow = makeWindow(.primary, self) { [weak self] identity in
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

    state = .terminating
    activeWorkspaceChooser?.cancel()
    activeWorkspaceChooser = nil
    workspaceChoiceTask?.cancel()
    workspaceChoiceTask = nil
    presentation.workspaceChoice = .idle
    mainWindow?.closeForTermination()
    mainWindow = nil
    guard !conversations.records.isEmpty else {
      state = .terminated
      return .terminateNow
    }

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

  private func workspaceChoiceDidFinish(
    _ selectedURL: URL?,
    chooser: any WorkspaceChoosing
  ) {
    guard state == .running, activeWorkspaceChooser === chooser else { return }
    activeWorkspaceChooser = nil
    workspaceChoiceTask = nil

    guard let selectedURL else {
      presentation.workspaceChoice = .idle
      return
    }
    guard let workspace = validatedWorkspace(from: selectedURL) else {
      presentation.workspaceChoice = .failure(
        "Choose an existing folder with an absolute path.")
      presentMainWindow()
      return
    }

    presentation.workspaceChoice = .idle
    guard createConversation(in: workspace) != nil else { return }
    presentMainWindow()
  }

  private func validatedWorkspace(from url: URL) -> WorkspaceIdentity? {
    guard url.isFileURL, url.path.first == "/",
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
      values.isDirectory == true
    else { return nil }
    return WorkspaceIdentity(absolutePath: url.path)
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
