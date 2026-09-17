import SwiftUI

struct ContentView: View {
  @StateObject private var store: NativeChatStore

  init(store: NativeChatStore) {
    _store = StateObject(wrappedValue: store)
  }

  var body: some View {
    VStack(spacing: 14) {
      header
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(store.transcript) { item in
            ChatItemView(item: item)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      composer
    }
    .padding(20)
    .frame(minWidth: 620, minHeight: 420)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(store.sessionTitle)
        .font(.title2.weight(.semibold))
      Text(store.workspace)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var composer: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField(
        "Ask anything. Use / for commands…",
        text: $store.draft,
        axis: .vertical
      )
      .textFieldStyle(.plain)
      .lineLimit(2...6)
      .onSubmit(store.submit)

      HStack(spacing: 10) {
        modelMenu

        if store.modelState == .loading || store.modelState == .refreshing
          || store.modelState == .switching || store.lifecycle == .responding
        {
          ProgressView()
            .controlSize(.small)
            .help(status)
        }

        Spacer()

        Button(action: store.submit) {
          Image(systemName: "arrow.up")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(canSubmit ? Color.white : Color.secondary)
            .frame(width: 30, height: 30)
            .background(
              canSubmit ? Color.accentColor : Color.secondary.opacity(0.14),
              in: Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Send")
        .disabled(!canSubmit)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(.background, in: RoundedRectangle(cornerRadius: 16))
    .overlay {
      RoundedRectangle(cornerRadius: 16)
        .stroke(.secondary.opacity(0.45), lineWidth: 1)
    }
  }

  private var modelMenu: some View {
    Menu {
      ForEach(store.modelChoices) { model in
        Menu(model.displayName) {
          if !model.detail.isEmpty {
            Text(model.detail)
          }
          ForEach(model.reasoning) { effort in
            Button {
              store.select(modelID: model.id, reasoning: effort)
            } label: {
              HStack {
                Text(
                  effort == model.advertisedDefaultReasoning
                    ? "\(effort.label) (default)" : effort.label)
                if store.selectedModelID == model.id && store.selectedReasoning == effort {
                  Image(systemName: "checkmark")
                }
              }
            }
          }
        }
      }
      Divider()
      Button("Refresh Models", systemImage: "arrow.clockwise", action: store.refreshModels)
    } label: {
      Text(modelLabel)
        .lineLimit(1)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(selectedModel?.detail ?? "Choose a model and reasoning level")
    .disabled(store.modelState != .ready || store.catalog == nil || store.isBusy)
  }

  private var selectedModel: ModelInfo? {
    store.modelChoices.first(where: { $0.id == store.selectedModelID })
  }

  private var modelLabel: String {
    guard let model = selectedModel, let reasoning = store.selectedReasoning else {
      return store.modelState == .loading ? "Loading models…" : "Models unavailable"
    }
    return "\(model.displayName) · \(reasoning.label)"
  }

  private var canSubmit: Bool {
    !store.isBusy && !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var status: String {
    switch store.lifecycle {
    case .starting: return "Starting"
    case .idle: return "Ready"
    case .responding: return "Responding"
    case .closing: return "Closing"
    case .closed: return "Closed"
    }
  }
}

private struct ChatItemView: View {
  let item: ChatItem

  var body: some View {
    switch item {
    case .user(_, let text):
      HStack {
        Spacer(minLength: 80)
        Text(text)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
      }
    case .assistant(_, let text):
      VStack(alignment: .leading, spacing: 4) {
        Text("Vivi")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(text.isEmpty ? "…" : text)
          .textSelection(.enabled)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    case .reasoning(_, let text):
      DisclosureGroup("Reasoning") {
        Text(text)
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 4)
      }
      .padding(10)
      .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    case .status(_, let text):
      Label(text, systemImage: "info.circle")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .failure(_, let text):
      Label(text, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
  }
}
