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
