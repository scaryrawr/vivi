import Foundation
import SwiftUI

struct SidebarRowPresentation: Equatable {
  let title: String
  let duplicateBadge: String?
  let accessibilityLabel: String
}

func sidebarRowPresentation(
  title: String,
  projectName: String,
  duplicate: (ordinal: Int, total: Int)?
) -> SidebarRowPresentation {
  let displayedTitle =
    title.nilIfEmpty.flatMap { $0 == projectName ? nil : $0 }
    ?? "New conversation"
  let duplicateLabel = duplicate.map {
    "conversation \($0.ordinal) of \($0.total)"
  }
  return SidebarRowPresentation(
    title: displayedTitle,
    duplicateBadge: duplicate.map { String($0.ordinal) },
    accessibilityLabel: [displayedTitle, duplicateLabel]
      .compactMap { $0 }
      .joined(separator: ", "))
}

struct ProjectSidebarPresentation: Equatable {
  let name: String
  let visiblePath: String?
  let accessibilityLabel: String
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
    accessibilityLabel: "\(name), \(workspace.canonicalPath), project")
}

private func projectName(for workspace: WorkspaceIdentity) -> String {
  URL(fileURLWithPath: workspace.canonicalPath).lastPathComponent.nilIfEmpty ?? "/"
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
      ?? "Untitled session"
    return SessionHistoryRowPresentation(
      key: session.key,
      title: title,
      accessibilityLabel: "\(title), saved session")
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
          ProjectSidebarSection(
            conversations: conversations,
            workspace: workspace)
        }
      }
      .listStyle(.sidebar)
      .safeAreaInset(edge: .bottom) {
        newConversationControl
      }
      .toolbar(removing: .sidebarToggle)
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

  init(
    conversations: ConversationCollection,
    workspace: WorkspaceIdentity
  ) {
    self.conversations = conversations
    self.workspace = workspace
    guard let catalogConversation = conversations.catalogConversation(launchedFrom: workspace)
    else {
      preconditionFailure("Project sidebar sections require a live conversation")
    }
    _catalogStore = ObservedObject(wrappedValue: catalogConversation.store)
  }

  private var records: [ConversationRecord] {
    conversations.records(launchedFrom: workspace)
  }

  private var presentation: ProjectSidebarPresentation {
    projectSidebarPresentation(
      workspace: workspace,
      allWorkspaces: conversations.launchWorkspaces)
  }

  var body: some View {
    Section {
      ForEach(records) { conversation in
        ConversationSidebarRow(
          conversation: conversation,
          duplicate: conversations.duplicatePosition(for: conversation.id)
        )
        .tag(conversation.id)
      }
      switch catalogStore.sessionState {
      case .refreshing:
        loadingState
      case .ready, .resuming:
        if let failure = catalogStore.sessionCatalogFailure {
          failureRow(failure)
        } else if let catalog = catalogStore.sessionCatalog {
          ForEach(
            projectSessionHistoryPresentation(
              catalog: catalog,
              projectWorkspace: workspace.canonicalPath)
          ) { row in
            SessionHistoryRow(
              presentation: row,
              isResuming: resumingKey == row.key
            ) {
              conversations.resume(row.key, launchedFrom: workspace)
            }
            .disabled(isOperating)
          }
        } else {
          loadingState
        }
      }
    } header: {
      VStack(alignment: .leading, spacing: 2) {
        Label(presentation.name, systemImage: "folder")
          .fontWeight(.semibold)
        if let visiblePath = presentation.visiblePath {
          Text(visiblePath)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      .help(workspace.canonicalPath)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(presentation.accessibilityLabel)
      .accessibilityIdentifier("project-\(workspace.canonicalPath)")
    }
    .accessibilityIdentifier("session-history-\(workspace.canonicalPath)")
    .onAppear {
      loadIfNeeded()
    }
    .onChange(of: catalogStore.lifecycle) {
      loadIfNeeded()
    }
    .onChange(of: catalogStore.modelState) {
      loadIfNeeded()
    }
    .onChange(of: catalogStore.sessionState) { previous, current in
      guard case .resuming = previous, current == .ready,
        catalogStore.sessionCatalog == nil
      else {
        return
      }
      catalogStore.refreshSessions()
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
        catalogStore.refreshSessions()
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

  private var isOperating: Bool {
    catalogStore.lifecycle != .idle || catalogStore.modelState != .ready
      || catalogStore.sessionState != .ready
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
  let duplicate: (ordinal: Int, total: Int)?

  private var presentation: SidebarRowPresentation {
    sidebarRowPresentation(
      title: conversation.navigation.title,
      projectName: projectName(for: conversation.navigation.workspace),
      duplicate: duplicate)
  }

  var body: some View {
    HStack(spacing: 8) {
      Text(presentation.title)
        .lineLimit(1)
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
