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

struct SessionHistoryGroupPresentation: Equatable, Identifiable {
  let id: String
  let title: String?
  let rows: [SessionHistoryRowPresentation]
}

func sessionHistoryPresentation(
  catalog: SessionCatalog,
  currentWorkspace: String,
  formatLastUsed: (Int64) -> String
) -> [SessionHistoryGroupPresentation] {
  let sessions = catalog.sessions.filter { !$0.isCurrent }

  func row(for session: SessionSummary) -> SessionHistoryRowPresentation {
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

  guard catalog.scope == .local else {
    return [
      SessionHistoryGroupPresentation(
        id: "local",
        title: nil,
        rows: sessions.map(row(for:)))
    ]
  }

  var workspaceOrder: [String] = []
  var sessionsByWorkspace: [String: [SessionSummary]] = [:]
  for session in sessions {
    if sessionsByWorkspace[session.workingDirectory] == nil {
      workspaceOrder.append(session.workingDirectory)
    }
    sessionsByWorkspace[session.workingDirectory, default: []].append(session)
  }
  return workspaceOrder.map { workspace in
    SessionHistoryGroupPresentation(
      id: workspace,
      title: workspace == currentWorkspace ? "This Workspace" : workspace,
      rows: sessionsByWorkspace[workspace, default: []].map(row(for:)))
  }
}

struct MainWindowView: View {
  @ObservedObject var conversations: ConversationCollection

  var body: some View {
    NavigationSplitView {
      List(selection: selection) {
        Section("Conversations") {
          ForEach(conversations.records) { conversation in
            ConversationSidebarRow(
              conversation: conversation,
              duplicate: conversations.duplicatePosition(for: conversation.id)
            )
            .tag(conversation.id)
          }
        }
        if let conversation = conversations.selectedConversation {
          SessionHistorySection(store: conversation.store)
            .id(conversation.id)
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

private struct SessionHistorySection: View {
  @ObservedObject var store: NativeChatStore
  @State private var isExpanded = false
  @State private var request: SessionCatalogRequest

  init(store: NativeChatStore) {
    self.store = store
    _request = State(
      initialValue: store.sessionCatalog?.scope == .broader ? .all : .local)
  }

  var body: some View {
    Section {
      DisclosureGroup(isExpanded: $isExpanded) {
        scopeMenu
        historyContent
      } label: {
        Label("History", systemImage: "clock.arrow.circlepath")
      }
      .accessibilityIdentifier("session-history")
    }
    .onChange(of: isExpanded) {
      guard isExpanded, shouldLoad else { return }
      store.refreshSessions(request)
    }
    .onChange(of: store.sessionState) { previous, current in
      guard case .resuming = previous, current == .ready, store.sessionCatalog == nil else {
        return
      }
      isExpanded = false
    }
  }

  private var scopeMenu: some View {
    Menu {
      scopeButton("Saved Vivi Sessions", request: .local)
      scopeButton("Copilot Sessions in This Workspace", request: .all)
      Divider()
      Button("Refresh", systemImage: "arrow.clockwise") {
        store.refreshSessions(request)
      }
    } label: {
      HStack {
        Text(scopeLabel)
          .lineLimit(1)
        Spacer()
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .disabled(isOperating)
    .accessibilityLabel("Session history scope")
    .accessibilityValue(scopeAccessibilityValue)
    .accessibilityIdentifier("session-history-scope")
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
            store.refreshSessions(request)
          }
          .disabled(isOperating)
        }
        .accessibilityIdentifier("session-history-failure")
      } else if let catalog = store.sessionCatalog {
        let groups = sessionHistoryPresentation(
          catalog: catalog,
          currentWorkspace: store.workspace,
          formatLastUsed: sessionHistoryLastUsed)
        if groups.allSatisfy(\.rows.isEmpty) {
          Label(emptyMessage, systemImage: "clock")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("session-history-empty")
        } else {
          if catalog.skippedInvalidShards {
            Label("Some sessions couldn’t be read.", systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("session-history-partial-warning")
          }
          ForEach(groups) { group in
            if let title = group.title {
              Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(title)
            }
            ForEach(group.rows) { row in
              SessionHistoryRow(
                presentation: row,
                isResuming: resumingKey == row.key
              ) {
                store.resumeSession(row.key)
              }
              .disabled(isOperating)
            }
          }
        }
      } else {
        Label(emptyMessage, systemImage: "clock")
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("session-history-empty")
      }
    }
  }

  private func scopeButton(
    _ title: String,
    request selectedRequest: SessionCatalogRequest
  ) -> some View {
    Button {
      request = selectedRequest
      store.refreshSessions(selectedRequest)
    } label: {
      if request == selectedRequest {
        Label(title, systemImage: "checkmark")
      } else {
        Text(title)
      }
    }
  }

  private var scopeLabel: String {
    request == .local ? "Saved in Vivi" : "This Workspace"
  }

  private var scopeAccessibilityValue: String {
    request == .local ? "Saved Vivi Sessions" : "Copilot Sessions in This Workspace"
  }

  private var emptyMessage: String {
    request == .local
      ? "No saved Vivi sessions." : "No Copilot sessions in this workspace."
  }

  private var shouldLoad: Bool {
    guard store.sessionCatalogFailure == nil else { return false }
    guard let catalog = store.sessionCatalog else { return true }
    return catalog.scope != requestedScope
  }

  private var requestedScope: SessionCatalogScope {
    request == .local ? .local : .broader
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
