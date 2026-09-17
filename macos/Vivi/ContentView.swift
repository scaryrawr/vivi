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
      HStack {
        TextField("Ask Vivi", text: $store.draft)
          .textFieldStyle(.roundedBorder)
          .onSubmit(store.submit)
        Button("Send", action: store.submit)
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(
            store.isBusy || store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      Text(status)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(20)
    .frame(minWidth: 620, minHeight: 420)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(store.sessionTitle)
        .font(.title2.weight(.semibold))
      Text(store.workspace)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      HStack(spacing: 10) {
        Picker(
          "Model",
          selection: Binding(
            get: { store.selectedModelID ?? "" },
            set: store.selectModel)
        ) {
          if store.catalog != nil {
            ForEach(store.modelChoices) { model in
              Text(
                model.detail.isEmpty
                  ? model.displayName : "\(model.displayName) · \(model.detail)"
              )
              .tag(model.id)
            }
          } else {
            Text(store.modelState == .loading ? "Loading models…" : "Models unavailable").tag("")
          }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 310)
        .disabled(store.modelState != .ready || store.catalog == nil || store.isBusy)

        Picker(
          "Reasoning",
          selection: Binding(
            get: { store.selectedReasoning ?? .off },
            set: store.selectReasoning)
        ) {
          ForEach(store.reasoningChoices) { effort in
            Text(
              effort == selectedModel?.advertisedDefaultReasoning
                ? "\(effort.label) (default)" : effort.label
            )
            .tag(effort)
          }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 190)
        .disabled(
          store.modelState != .ready || store.reasoningChoices.isEmpty || store.isBusy)

        Button(action: store.refreshModels) {
          Image(systemName: "arrow.clockwise")
        }
        .help("Refresh models")
        .disabled(store.modelState != .ready || store.isBusy)

        if store.modelState == .loading || store.modelState == .refreshing
          || store.modelState == .switching
        {
          ProgressView()
            .controlSize(.small)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var selectedModel: ModelInfo? {
    store.modelChoices.first(where: { $0.id == store.selectedModelID })
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
