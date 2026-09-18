import Foundation
import SwiftUI

struct SidebarRowPresentation: Equatable {
  let title: String
  let accessibilityLabel: String
}

func sidebarRowPresentation(
  title: String,
  projectName: String
) -> SidebarRowPresentation {
  let displayedTitle =
    title.nilIfEmpty.flatMap { $0 == projectName ? nil : $0 }
    ?? "New conversation"
  return SidebarRowPresentation(
    title: displayedTitle,
    accessibilityLabel: displayedTitle)
}

struct ProjectSidebarPresentation: Equatable {
  let name: String
  let visiblePath: String?
  let help: String
  let accessibilityLabel: String
  let accessibilityIdentifier: String
}

func projectSidebarPresentation(
  workspace: WorkspaceIdentity,
  allWorkspaces: [WorkspaceIdentity]
) -> ProjectSidebarPresentation {
  let name = projectName(for: workspace)
  let matchingNameCount = allWorkspaces.count { projectName(for: $0) == name }
  return ProjectSidebarPresentation(
    name: name,
    visiblePath: matchingNameCount > 1 ? workspace.canonicalPath : nil,
    help: workspace.canonicalPath,
    accessibilityLabel: "\(name), \(workspace.canonicalPath), project",
    accessibilityIdentifier: "project-\(workspace.canonicalPath)")
}

private func projectName(for workspace: WorkspaceIdentity) -> String {
  URL(fileURLWithPath: workspace.canonicalPath).lastPathComponent.nilIfEmpty ?? "/"
}

struct SidebarProjectRoster: Equatable, Identifiable {
  let workspace: WorkspaceIdentity
  let conversationIDs: [ConversationID]

  var id: WorkspaceIdentity { workspace }
}

func sidebarProjectRosters(
  records: [ConversationRecord],
  launchWorkspaces: [WorkspaceIdentity]
) -> [SidebarProjectRoster] {
  launchWorkspaces.map { workspace in
    SidebarProjectRoster(
      workspace: workspace,
      conversationIDs: records.compactMap { record in
        record.launchWorkspace == workspace ? record.id : nil
      })
  }
}

struct ProjectExpansionState: Equatable {
  private var collapsed: Set<WorkspaceIdentity> = []

  func isExpanded(_ workspace: WorkspaceIdentity) -> Bool {
    !collapsed.contains(workspace)
  }

  mutating func setExpanded(_ isExpanded: Bool, for workspace: WorkspaceIdentity) {
    if isExpanded {
      collapsed.remove(workspace)
    } else {
      collapsed.insert(workspace)
    }
  }

  mutating func toggle(_ workspace: WorkspaceIdentity) {
    setExpanded(!isExpanded(workspace), for: workspace)
  }
}

struct ProjectDisclosurePresentation: Equatable {
  let systemImage: String
  let accessibilityValue: String
}

func projectDisclosurePresentation(isExpanded: Bool) -> ProjectDisclosurePresentation {
  ProjectDisclosurePresentation(
    systemImage: isExpanded ? "chevron.down" : "chevron.right",
    accessibilityValue: isExpanded ? "Expanded" : "Collapsed")
}

struct SessionHistoryRowPresentation: Equatable, Identifiable {
  let key: ResumeKey
  let title: String
  let accessibilityLabel: String

  var id: ResumeKey { key }
}

enum ProjectSidebarRow: Equatable, Identifiable {
  enum ID: Hashable {
    case live(ConversationID)
    case saved(ResumeKey)
  }

  case live(ConversationID)
  case saved(SessionHistoryRowPresentation)

  var id: ID {
    switch self {
    case .live(let id):
      .live(id)
    case .saved(let presentation):
      .saved(presentation.key)
    }
  }
}

func projectSidebarRows(
  liveConversationIDs: [ConversationID],
  catalogOwnerID: ConversationID,
  catalog: SessionCatalog?,
  projectWorkspace: String,
  catalogAnchorSlot: UInt32?,
  pendingResumeKey: ResumeKey?
) -> [ProjectSidebarRow] {
  guard let catalog else {
    return liveConversationIDs.map(ProjectSidebarRow.live)
  }
  let sessions = catalog.sessions.filter { $0.workingDirectory == projectWorkspace }
  guard !sessions.isEmpty else {
    return liveConversationIDs.map(ProjectSidebarRow.live)
  }
  let effectiveCurrentKey =
    pendingResumeKey
    ?? sessions.first(where: \.isCurrent)?.key
  let anchorSlot =
    catalogAnchorSlot
    ?? sessions.first(where: \.isCurrent)?.key.slot
  guard let anchorSlot,
    sessions.contains(where: { $0.key.slot == anchorSlot })
  else {
    return liveConversationIDs.map(ProjectSidebarRow.live)
      + sessions.compactMap { session in
        session.key == effectiveCurrentKey
          ? nil
          : .saved(sessionHistoryRowPresentation(session))
      }
  }
  let additionalLiveRows =
    liveConversationIDs
    .filter { $0 != catalogOwnerID }
    .map(ProjectSidebarRow.live)
  var rows: [ProjectSidebarRow] = []

  for session in sessions {
    if session.key == effectiveCurrentKey {
      rows.append(.live(catalogOwnerID))
    } else {
      rows.append(.saved(sessionHistoryRowPresentation(session)))
    }
    if session.key.slot == anchorSlot {
      rows.append(contentsOf: additionalLiveRows)
    }
  }
  return rows
}

func projectSessionHistoryPresentation(
  catalog: SessionCatalog,
  projectWorkspace: String
) -> [SessionHistoryRowPresentation] {
  catalog.sessions.compactMap { session in
    guard !session.isCurrent, session.workingDirectory == projectWorkspace else { return nil }
    return sessionHistoryRowPresentation(session)
  }
}

private func sessionHistoryRowPresentation(
  _ session: SessionSummary
) -> SessionHistoryRowPresentation {
  let title =
    session.title?.nilIfEmpty
    ?? "Untitled session"
  return SessionHistoryRowPresentation(
    key: session.key,
    title: title,
    accessibilityLabel: "\(title), saved session")
}

struct MainWindowView: View {
  @ObservedObject var conversations: ConversationCollection
  @ObservedObject var applicationPresentation: NativeApplicationPresentation
  let requestNewConversation: () -> Void
  let dismissWorkspaceChoiceFailure: () -> Void
  @State private var projectExpansion = ProjectExpansionState()

  var body: some View {
    NavigationSplitView {
      List(selection: selection) {
        ForEach(
          sidebarProjectRosters(
            records: conversations.records,
            launchWorkspaces: conversations.launchWorkspaces)
        ) { roster in
          ProjectSidebarSection(
            conversations: conversations,
            workspace: roster.workspace,
            conversationIDs: roster.conversationIDs,
            isExpanded: projectExpansion.isExpanded(roster.workspace)
          ) {
            withAnimation {
              projectExpansion.toggle(roster.workspace)
            }
          }
        }
      }
      .listStyle(.sidebar)
      .safeAreaInset(edge: .bottom) {
        newConversationControl
      }
      .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
      .accessibilityIdentifier("conversation-sidebar")
    } detail: {
      if let conversation = conversations.selectedConversation {
        ContentView(store: conversation.store)
          .id(conversation.id.rawValue)
          .accessibilityIdentifier("conversation-detail-\(conversation.id.rawValue)")
      } else {
        ContentUnavailableView {
          Label("No Conversations", systemImage: "bubble.left.and.bubble.right")
        } description: {
          Text("Choose a workspace to start a conversation.")
        } actions: {
          Button("New Conversation", action: requestNewConversation)
            .buttonStyle(.borderedProminent)
            .disabled(applicationPresentation.workspaceChoice.isChoosing)
            .accessibilityIdentifier("new-conversation-empty-state")
        }
        .accessibilityIdentifier("conversation-empty-state")
      }
    }
    .navigationSplitViewStyle(.balanced)
    .frame(minWidth: 760, minHeight: 500)
    .alert(
      "Can’t Start Conversation",
      isPresented: workspaceChoiceFailureIsPresented
    ) {
      Button("OK", action: dismissWorkspaceChoiceFailure)
    } message: {
      Text(workspaceChoiceFailure ?? "")
    }
  }

  private var newConversationControl: some View {
    Button(action: requestNewConversation) {
      HStack(spacing: 8) {
        Label("New Conversation", systemImage: "plus")
        Spacer()
        if applicationPresentation.workspaceChoice.isChoosing {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Choosing workspace")
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(applicationPresentation.workspaceChoice.isChoosing)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(.bar)
    .accessibilityIdentifier("new-conversation-sidebar")
  }

  private var workspaceChoiceFailure: String? {
    guard case .failure(let message) = applicationPresentation.workspaceChoice else {
      return nil
    }
    return message
  }

  private var workspaceChoiceFailureIsPresented: Binding<Bool> {
    Binding(
      get: { workspaceChoiceFailure != nil },
      set: { isPresented in
        if !isPresented {
          dismissWorkspaceChoiceFailure()
        }
      })
  }

  private var selection: Binding<ConversationID?> {
    Binding(
      get: { conversations.selectedID },
      set: { id in
        if let id {
          conversations.select(id)
        }
      })
  }

}

private struct ProjectSidebarSection: View {
  @ObservedObject var conversations: ConversationCollection
  @ObservedObject private var catalogStore: NativeChatStore
  let workspace: WorkspaceIdentity
  let conversationIDs: [ConversationID]
  let isExpanded: Bool
  let toggleExpansion: () -> Void
  @State private var catalogAnchorSlot: UInt32?

  init(
    conversations: ConversationCollection,
    workspace: WorkspaceIdentity,
    conversationIDs: [ConversationID],
    isExpanded: Bool,
    toggleExpansion: @escaping () -> Void
  ) {
    self.conversations = conversations
    self.workspace = workspace
    self.conversationIDs = conversationIDs
    self.isExpanded = isExpanded
    self.toggleExpansion = toggleExpansion
    guard let catalogConversation = conversations.catalogConversation(launchedFrom: workspace)
    else {
      preconditionFailure("Project sidebar sections require a live conversation")
    }
    _catalogStore = ObservedObject(wrappedValue: catalogConversation.store)
  }

  private var catalogOwnerID: ConversationID {
    guard let id = conversationIDs.first else {
      preconditionFailure("Project sidebar sections require a live conversation")
    }
    return id
  }

  private var sidebarRows: [ProjectSidebarRow] {
    projectSidebarRows(
      liveConversationIDs: conversationIDs,
      catalogOwnerID: catalogOwnerID,
      catalog: catalogStore.sessionCatalog,
      projectWorkspace: workspace.canonicalPath,
      catalogAnchorSlot: catalogAnchorSlot,
      pendingResumeKey: resumingKey)
  }

  private var presentation: ProjectSidebarPresentation {
    projectSidebarPresentation(
      workspace: workspace,
      allWorkspaces: conversations.launchWorkspaces)
  }

  private var disclosure: ProjectDisclosurePresentation {
    projectDisclosurePresentation(isExpanded: isExpanded)
  }

  var body: some View {
    Section {
      if isExpanded {
        ForEach(sidebarRows) { row in
          switch row {
          case .live(let id):
            if let conversation = conversations.conversation(id) {
              ConversationSidebarRow(conversation: conversation)
                .tag(id)
                .padding(.leading, 16)
            }
          case .saved(let presentation):
            SessionHistoryRow(
              presentation: presentation,
              isResuming: resumingKey == presentation.key
            ) {
              conversations.resume(presentation.key, launchedFrom: workspace)
            }
            .disabled(isOperating)
            .padding(.leading, 16)
          }
        }
        if let failure = catalogStore.sessionCatalogFailure {
          failureRow(failure)
        } else if catalogStore.sessionCatalog == nil {
          switch catalogStore.sessionState {
          case .refreshing:
            loadingState
          case .ready, .resuming:
            if catalogStore.sessionState == .ready {
              loadingState
            }
          }
        }
      }
    } header: {
      Button(action: toggleExpansion) {
        HStack(spacing: 7) {
          Image(systemName: disclosure.systemImage)
            .font(.caption2.weight(.semibold))
            .frame(width: 10)
          VStack(alignment: .leading, spacing: 2) {
            Label(presentation.name, systemImage: "folder")
              .font(.body)
              .fontWeight(.semibold)
            if let visiblePath = presentation.visiblePath {
              Text(visiblePath)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
          }
          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .textCase(nil)
      .help(presentation.help)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(presentation.accessibilityLabel)
      .accessibilityValue(disclosure.accessibilityValue)
      .accessibilityIdentifier(presentation.accessibilityIdentifier)
    }
    .accessibilityIdentifier("session-history-\(workspace.canonicalPath)")
    .onAppear {
      captureCatalogAnchor()
      loadIfNeeded()
    }
    .onChange(of: catalogStore.sessionCatalog) {
      captureCatalogAnchor()
    }
    .onChange(of: catalogStore.lifecycle) {
      loadIfNeeded()
    }
    .onChange(of: catalogStore.modelState) {
      loadIfNeeded()
    }
  }

  private var loadingState: some View {
    HStack(spacing: 6) {
      ProgressView()
        .controlSize(.small)
      Text("Loading sessions…")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .accessibilityIdentifier("session-history-loading")
  }

  private func failureRow(_ failure: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "exclamationmark.triangle")
        .foregroundStyle(.secondary)
      Text(failure)
        .lineLimit(1)
      Spacer(minLength: 4)
      Button {
        catalogStore.refreshSessions(
          preservingCatalog: catalogStore.sessionCatalog != nil)
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.borderless)
      .help("Try Again")
      .accessibilityLabel("Try Again")
      .disabled(isOperating)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .accessibilityIdentifier("session-history-failure")
  }

  private var shouldLoad: Bool {
    catalogStore.sessionCatalogFailure == nil && catalogStore.sessionCatalog == nil
  }

  private func loadIfNeeded() {
    guard shouldLoad else { return }
    catalogStore.refreshSessions()
  }

  private func captureCatalogAnchor() {
    guard catalogAnchorSlot == nil,
      let current = catalogStore.sessionCatalog?.sessions.first(where: {
        $0.isCurrent && $0.workingDirectory == workspace.canonicalPath
      })
    else {
      return
    }
    catalogAnchorSlot = current.key.slot
  }

  private var isOperating: Bool {
    catalogStore.lifecycle != .idle || catalogStore.modelState != .ready
      || catalogStore.sessionState != .ready || catalogStore.sessionCatalogFailure != nil
  }

  private var resumingKey: ResumeKey? {
    guard case .resuming(let key) = catalogStore.sessionState else { return nil }
    return key
  }
}

private struct SessionHistoryRow: View {
  let presentation: SessionHistoryRowPresentation
  let isResuming: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Text(presentation.title)
          .lineLimit(1)
        Spacer(minLength: 4)
        if isResuming {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Resuming")
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(presentation.accessibilityLabel)
    .accessibilityIdentifier(
      "session-history-row-\(presentation.key.generation)-\(presentation.key.slot)")
  }
}

private struct ConversationSidebarRow: View {
  @ObservedObject var conversation: ConversationRecord

  private var presentation: SidebarRowPresentation {
    sidebarRowPresentation(
      title: conversation.navigation.title,
      projectName: projectName(for: conversation.navigation.workspace))
  }

  var body: some View {
    HStack(spacing: 8) {
      Text(presentation.title)
        .lineLimit(1)
    }

    .accessibilityElement(children: .ignore)
    .accessibilityLabel(presentation.accessibilityLabel)
    .accessibilityIdentifier("conversation-row-\(conversation.id.rawValue)")
  }
}

extension String {
  fileprivate var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
