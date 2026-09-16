import SwiftUI

struct ContentView: View {
  @StateObject private var store: NativeChatStore

  init(store: NativeChatStore) {
    _store = StateObject(wrappedValue: store)
  }

  var body: some View {
    VStack(spacing: 12) {
      Text(store.workspace)
        .font(.caption)
        .foregroundStyle(.secondary)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(store.transcript) { item in
            Text(item.text)
              .foregroundStyle(color(for: item))
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      HStack {
        TextField("Ask Vivi", text: $store.draft)
          .onSubmit(store.submit)
        Button("Send", action: store.submit)
          .disabled(
            store.isBusy || store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      Text(status)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(20)
    .frame(minWidth: 520, minHeight: 360)
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

  private func color(for item: ChatItem) -> Color {
    if case .failure = item {
      return .red
    }
    return .primary
  }
}
