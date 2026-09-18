import Foundation
import SwiftUI

struct MainWindowTitlePresentation: Equatable {
  let appName: String
  let conversationTitle: String

  init(conversationTitle: String?) {
    appName = "Vivi"
    self.conversationTitle = conversationTitle?.nilIfEmpty ?? "Untitled Session"
  }

  var accessibilityLabel: String {
    "\(appName), \(conversationTitle)"
  }
}

struct SidebarRowPresentation: Equatable {
  let title: String
  let workspace: String
  let duplicateBadge: String?
  let accessibilityLabel: String
}

func sidebarRowPresentation(
  title: String,
  workspace: String,
  duplicate: (ordinal: Int, total: Int)?
) -> SidebarRowPresentation {
  let duplicateLabel = duplicate.map {
    "conversation \($0.ordinal) of \($0.total)"
  }
  return SidebarRowPresentation(
    title: title,
    workspace: workspace,
    duplicateBadge: duplicate.map { String($0.ordinal) },
    accessibilityLabel: [title, workspace, duplicateLabel]
      .compactMap { $0 }
      .joined(separator: ", "))
}

func projectAccessibilityLabel(name: String, path: String) -> String {
  "\(name), \(path), project"
}

func projectName(for workspace: WorkspaceIdentity) -> String {
  URL(fileURLWithPath: workspace.canonicalPath).lastPathComponent.nilIfEmpty ?? "/"
}

func conversationSidebarTitle(title: String, launchWorkspace: String) -> String {
  let title = title.nilIfEmpty ?? "Untitled Session"
  let projectName =
    URL(fileURLWithPath: launchWorkspace).lastPathComponent.nilIfEmpty
    ?? "/"
  return title == projectName ? "New conversation" : title
}

struct ProjectSidebarHeaderPresentation: Equatable {
  let name: String
  let path: String
  let accessibilityLabel: String

  init(workspace: WorkspaceIdentity) {
    path = workspace.canonicalPath
    name = URL(fileURLWithPath: path).lastPathComponent.nilIfEmpty ?? "/"
    accessibilityLabel = projectAccessibilityLabel(name: name, path: path)
  }
}

struct SessionHistoryRowPresentation: Equatable, Identifiable {
  let key: ResumeKey
  let title: String
  let accessibilityLabel: String

  var id: ResumeKey { key }
}

enum SidebarSelection: Hashable {
  case conversation(ConversationID)
  case savedSession(ConversationID, ResumeKey)
}

func resolvedSidebarSelection(
  selectedConversationID: ConversationID?,
  savedSelection: SidebarSelection?,
  visibleSavedSessionKeys: Set<ResumeKey>
) -> SidebarSelection? {
  if case .savedSession(let conversationID, let key) = savedSelection,
    selectedConversationID == conversationID,
    visibleSavedSessionKeys.contains(key)
  {
    return savedSelection
  }
  return selectedConversationID.map(SidebarSelection.conversation)
}

func projectSessionHistoryPresentation(
  catalog: SessionCatalog,
  projectWorkspace: String
) -> [SessionHistoryRowPresentation] {
  catalog.sessions.compactMap { session in
    guard !session.isCurrent, session.workingDirectory == projectWorkspace else { return nil }
    let title =
      session.title?.nilIfEmpty
      ?? "Untitled Session"
    return SessionHistoryRowPresentation(
      key: session.key,
      title: title,
      accessibilityLabel: "\(title), \(session.workingDirectory), saved session")
  }
}

struct MainWindowView: View {
  @ObservedObject var conversations: ConversationCollection
  @ObservedObject var applicationPresentation: NativeApplicationPresentation
  let requestNewConversation: () -> Void
  let dismissWorkspaceChoiceFailure: () -> Void
  @State private var sidebarSelection: SidebarSelection?

  var body: some View {
    NavigationSplitView {
      List(selection: selectionBinding) {
        ForEach(conversations.launchWorkspaces, id: \.self) { workspace in
          Section {
            ForEach(conversations.records(launchedFrom: workspace)) { conversation in
              ConversationSidebarRow(
                conversation: conversation,
                duplicate: conversations.duplicatePosition(for: conversation.id)
              )
              .padding(.leading, 12)
              .tag(SidebarSelection.conversation(conversation.id))
            }
            if let historyConversation = conversations.historyConversation(
              launchedFrom: workspace)
            {
              ProjectSavedSessionRows(
                store: historyConversation.store,
                projectWorkspace: workspace.canonicalPath,
                conversationID: historyConversation.id
              )
              .padding(.leading, 12)
            }
          } header: {
            ProjectSidebarHeader(
              workspace: workspace,
              showsPath: conversations.launchWorkspaces.filter {
                projectName(for: $0) == projectName(for: workspace)
              }.count > 1)
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

  private var selectionBinding: Binding<SidebarSelection?> {
    Binding(
      get: {
        resolvedSidebarSelection(
          selectedConversationID: conversations.selectedID,
          savedSelection: sidebarSelection,
          visibleSavedSessionKeys: visibleSavedSessionKeys)
      },
      set: { selection in
        guard let selection else { return }
        sidebarSelection = selection
        switch selection {
        case .conversation(let id):
          conversations.select(id)
        case .savedSession(let conversationID, let key):
          guard
            let conversation = conversations.records.first(where: { $0.id == conversationID })
          else {
            return
          }
          conversations.select(conversationID)
          conversation.store.resumeSession(key)
        }
      })
  }

  private var visibleSavedSessionKeys: Set<ResumeKey> {
    Set(
      conversations.launchWorkspaces.flatMap { workspace -> [ResumeKey] in
        guard let conversation = conversations.historyConversation(launchedFrom: workspace),
          let catalog = conversation.store.sessionCatalog
        else {
          return []
        }
        return projectSessionHistoryPresentation(
          catalog: catalog,
          projectWorkspace: workspace.canonicalPath
        ).map(\.key)
      })
  }
}

private struct ProjectSidebarHeader: View {
  let workspace: WorkspaceIdentity
  let showsPath: Bool

  private var presentation: ProjectSidebarHeaderPresentation {
    ProjectSidebarHeaderPresentation(workspace: workspace)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Label(presentation.name, systemImage: "folder")
        .font(.body)
        .fontWeight(.semibold)
      if showsPath {
        Text(presentation.path)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .padding(.top, 8)
    .padding(.bottom, 6)
    .help(presentation.path)
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isHeader)
    .accessibilityLabel(presentation.accessibilityLabel)
    .accessibilityIdentifier("project-\(presentation.path)")
  }
}

private struct ProjectSavedSessionRows: View {
  @ObservedObject var store: NativeChatStore
  let projectWorkspace: String
  let conversationID: ConversationID

  var body: some View {
    historyContent
      .onAppear {
        loadIfNeeded()
      }
      .onChange(of: store.lifecycle) {
        loadIfNeeded()
      }
      .onChange(of: store.modelState) {
        loadIfNeeded()
      }
      .onChange(of: store.sessionState) { previous, current in
        guard case .resuming = previous, current == .ready, store.sessionCatalog == nil else {
          return
        }
        store.refreshSessions()
      }
  }

  @ViewBuilder
  private var historyContent: some View {
    switch store.sessionState {
    case .refreshing:
      EmptyView()
    case .ready, .resuming:
      if let failure = store.sessionCatalogFailure {
        HStack(spacing: 8) {
          Label(failure, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
            .lineLimit(2)
          Spacer(minLength: 4)
          Button("Retry") {
            store.refreshSessions()
          }
          .disabled(isOperating)
        }
        .selectionDisabled()
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("session-history-failure")
      } else if let catalog = store.sessionCatalog {
        let rows = projectSessionHistoryPresentation(
          catalog: catalog,
          projectWorkspace: projectWorkspace)
        ForEach(rows) { row in
          SessionHistoryRow(
            presentation: row,
            isResuming: resumingKey == row.key
          )
          .disabled(isOperating)
          .tag(SidebarSelection.savedSession(conversationID, row.key))
        }
      } else {
        EmptyView()
      }
    }
  }

  private var shouldLoad: Bool {
    store.sessionCatalogFailure == nil && store.sessionCatalog == nil
  }

  private func loadIfNeeded() {
    guard shouldLoad else { return }
    store.refreshSessions()
  }

  private var isOperating: Bool {
    store.lifecycle != .idle || store.modelState != .ready || store.sessionState != .ready
  }

  private var resumingKey: ResumeKey? {
    guard case .resuming(let key) = store.sessionState else { return nil }
    return key
  }
}

private struct SessionHistoryRow: View {
  let presentation: SessionHistoryRowPresentation
  let isResuming: Bool

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(presentation.title)
          .lineLimit(1)
        Text("Saved session")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 4)
      if isResuming {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Resuming")
      }
    }
    .contentShape(Rectangle())
    .accessibilityLabel(presentation.accessibilityLabel)
    .accessibilityIdentifier(
      "session-history-row-\(presentation.key.generation)-\(presentation.key.slot)")
  }
}

private struct ConversationSidebarRow: View {
  @ObservedObject var conversation: ConversationRecord
  let duplicate: (ordinal: Int, total: Int)?

  private var presentation: SidebarRowPresentation {
    sidebarRowPresentation(
      title: conversationTitle,
      workspace: conversation.navigation.workspace.canonicalPath,
      duplicate: duplicate)
  }

  private var conversationTitle: String {
    conversationSidebarTitle(
      title: conversation.navigation.title,
      launchWorkspace: conversation.launchWorkspace.canonicalPath)
  }

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(presentation.title)
          .lineLimit(1)
      }
      Spacer(minLength: 4)
      if let badge = presentation.duplicateBadge {
        Text(badge)
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.secondary.opacity(0.12), in: Capsule())
          .accessibilityHidden(true)
      }
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
