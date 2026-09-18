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

func projectSessionHistoryPresentation(
  catalog: SessionCatalog,
  projectWorkspace: String
) -> [SessionHistoryRowPresentation] {
  catalog.sessions.compactMap { session in
    guard !session.isCurrent, session.workingDirectory == projectWorkspace else { return nil }
    let title =
      session.title?.nilIfEmpty
      ?? URL(fileURLWithPath: session.workingDirectory).lastPathComponent.nilIfEmpty
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

  var body: some View {
    NavigationSplitView {
      List(selection: selection) {
        ForEach(conversations.launchWorkspaces, id: \.self) { workspace in
          Section {
            ForEach(conversations.records(launchedFrom: workspace)) { conversation in
              ConversationSidebarRow(
                conversation: conversation,
                duplicate: conversations.duplicatePosition(for: conversation.id)
              )
              .padding(.leading, 12)
              .tag(conversation.id)
            }
            if let historyConversation = conversations.historyConversation(
              launchedFrom: workspace)
            {
              ProjectSessionHistory(
                store: historyConversation.store,
                projectWorkspace: workspace.canonicalPath
              ) { key in
                conversations.select(historyConversation.id)
                historyConversation.store.resumeSession(key)
              }
              .padding(.leading, 12)
              .id(historyConversation.id)
            }
          } header: {
            ProjectSidebarHeader(workspace: workspace)
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

private struct ProjectSidebarHeader: View {
  let workspace: WorkspaceIdentity

  private var presentation: ProjectSidebarHeaderPresentation {
    ProjectSidebarHeaderPresentation(workspace: workspace)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Label(presentation.name, systemImage: "folder")
        .fontWeight(.semibold)
      Text(presentation.path)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .help(presentation.path)
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isHeader)
    .accessibilityLabel(presentation.accessibilityLabel)
    .accessibilityIdentifier("project-\(presentation.path)")
  }
}

private struct ProjectSessionHistory: View {
  @ObservedObject var store: NativeChatStore
  let projectWorkspace: String
  let resume: (ResumeKey) -> Void
  @State private var isExpanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      historyContent
    } label: {
      Label("History", systemImage: "clock.arrow.circlepath")
        .foregroundStyle(.secondary)
    }
    .accessibilityIdentifier("session-history-\(projectWorkspace)")
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
      loadingState
    case .ready, .resuming:
      if let failure = store.sessionCatalogFailure {
        VStack(alignment: .leading, spacing: 6) {
          Label(failure, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
          Button("Try Again") {
            store.refreshSessions()
          }
          .disabled(isOperating)
        }
        .accessibilityIdentifier("session-history-failure")
      } else if let catalog = store.sessionCatalog {
        let rows = projectSessionHistoryPresentation(
          catalog: catalog,
          projectWorkspace: projectWorkspace)
        if rows.isEmpty {
          emptyState
        } else {
          ForEach(rows) { row in
            SessionHistoryRow(
              presentation: row,
              isResuming: resumingKey == row.key
            ) {
              resume(row.key)
            }
            .disabled(isOperating)
          }
        }
      } else {
        loadingState
      }
    }
  }

  private var loadingState: some View {
    Label("Loading sessions…", systemImage: "clock")
      .foregroundStyle(.secondary)
      .overlay(alignment: .trailing) {
        ProgressView()
          .controlSize(.small)
      }
      .accessibilityIdentifier("session-history-loading")
  }

  private var emptyState: some View {
    Label("No saved sessions for this project.", systemImage: "clock")
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("session-history-empty")
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
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: "clock")
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(presentation.title)
            .lineLimit(1)
        }
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
  let duplicate: (ordinal: Int, total: Int)?

  private var presentation: SidebarRowPresentation {
    sidebarRowPresentation(
      title: conversation.navigation.title,
      workspace: conversation.navigation.workspace.canonicalPath,
      duplicate: duplicate)
  }

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(presentation.title)
          .lineLimit(1)
        Text(presentation.workspace)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(presentation.workspace)
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
