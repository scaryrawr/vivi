import Foundation
import SwiftUI

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

struct SessionHistoryRowPresentation: Equatable, Identifiable {
  let key: ResumeKey
  let title: String
  let lastUsed: String
  let accessibilityLabel: String

  var id: ResumeKey { key }
}

func projectSessionHistoryPresentation(
  catalog: SessionCatalog,
  projectWorkspace: String,
  formatLastUsed: (Int64) -> String
) -> [SessionHistoryRowPresentation] {
  catalog.sessions.compactMap { session in
    guard !session.isCurrent, session.workingDirectory == projectWorkspace else { return nil }
    let title =
      session.title?.nilIfEmpty
      ?? URL(fileURLWithPath: session.workingDirectory).lastPathComponent.nilIfEmpty
      ?? "Untitled Session"
    let lastUsed = formatLastUsed(session.lastUsedUnixMilliseconds)
    return SessionHistoryRowPresentation(
      key: session.key,
      title: title,
      lastUsed: lastUsed,
      accessibilityLabel: [
        title,
        session.workingDirectory,
        session.summary?.nilIfEmpty,
        "Last used \(lastUsed)",
      ]
      .compactMap { $0 }
      .joined(separator: ", "))
  }
}

struct MainWindowView: View {
  @ObservedObject var conversations: ConversationCollection

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
          Text("Run `vivi chat --native` from a workspace to start one.")
        }
        .accessibilityIdentifier("conversation-empty-state")
      }
    }
    .navigationSplitViewStyle(.balanced)
    .frame(minWidth: 760, minHeight: 500)
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
  let workspace: WorkspaceIdentity
  @State private var isExpanded = true

  private var records: [ConversationRecord] {
    conversations.records(launchedFrom: workspace)
  }

  private var historyConversation: ConversationRecord? {
    conversations.historyConversation(launchedFrom: workspace)
  }

  var body: some View {
    Section(isExpanded: $isExpanded) {
      ForEach(records) { conversation in
        ConversationSidebarRow(
          conversation: conversation,
          duplicate: conversations.duplicatePosition(for: conversation.id)
        )
        .tag(conversation.id)
      }
      if let historyConversation {
        ProjectSessionHistory(
          store: historyConversation.store,
          projectWorkspace: workspace.canonicalPath
        ) { key in
          conversations.select(historyConversation.id)
          historyConversation.store.resumeSession(key)
        }
        .id(historyConversation.id)
      }
    } header: {
      Label(projectName, systemImage: "folder")
        .help(workspace.canonicalPath)
        .accessibilityLabel("\(projectName), project")
        .accessibilityIdentifier("project-\(workspace.canonicalPath)")
    }
  }

  private var projectName: String {
    URL(fileURLWithPath: workspace.canonicalPath).lastPathComponent.nilIfEmpty ?? "/"
  }
}

private struct ProjectSessionHistory: View {
  @ObservedObject var store: NativeChatStore
  let projectWorkspace: String
  let resume: (ResumeKey) -> Void

  var body: some View {
    historyContent
      .accessibilityIdentifier("session-history-\(projectWorkspace)")
      .onAppear {
        guard shouldLoad else { return }
        store.refreshSessions(.local)
      }
      .onChange(of: store.sessionState) { previous, current in
        guard case .resuming = previous, current == .ready, store.sessionCatalog == nil else {
          return
        }
        store.refreshSessions(.local)
      }
  }

  @ViewBuilder
  private var historyContent: some View {
    switch store.sessionState {
    case .refreshing:
      Label("Loading sessions…", systemImage: "clock")
        .foregroundStyle(.secondary)
        .overlay(alignment: .trailing) {
          ProgressView()
            .controlSize(.small)
        }
        .accessibilityIdentifier("session-history-loading")
    case .ready, .resuming:
      if let failure = store.sessionCatalogFailure {
        VStack(alignment: .leading, spacing: 6) {
          Label(failure, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
          Button("Try Again") {
            store.refreshSessions(.local)
          }
          .disabled(isOperating)
        }
        .accessibilityIdentifier("session-history-failure")
      } else if let catalog = store.sessionCatalog {
        let rows = projectSessionHistoryPresentation(
          catalog: catalog,
          projectWorkspace: projectWorkspace,
          formatLastUsed: sessionHistoryLastUsed)
        if rows.isEmpty {
          emptyState
        } else {
          if catalog.skippedInvalidShards {
            Label("Some sessions couldn’t be read.", systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("session-history-partial-warning")
          }
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
        emptyState
      }
    }
  }

  private var emptyState: some View {
    Label("No saved sessions for this project.", systemImage: "clock")
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("session-history-empty")
  }

  private var shouldLoad: Bool {
    guard store.sessionCatalogFailure == nil else { return false }
    guard let catalog = store.sessionCatalog else { return true }
    return catalog.scope != .local
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
          Text(presentation.lastUsed)
            .font(.caption)
            .foregroundStyle(.secondary)
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

private func sessionHistoryLastUsed(_ unixMilliseconds: Int64) -> String {
  Date(timeIntervalSince1970: TimeInterval(unixMilliseconds) / 1_000)
    .formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
}

extension String {
  fileprivate var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
