import SwiftUI

enum ToolInputLayout: Equatable {
  case presentation(ToolPresentation)
  case presentationWithCanonicalJSON(ToolPresentation, String)
}

func toolInputLayout(input: String, presentation: ToolPresentation) -> ToolInputLayout {
  guard case .source(_, .bash, _) = presentation,
    input != presentation.text
  else {
    return .presentation(presentation)
  }
  return .presentationWithCanonicalJSON(presentation, input)
}

func toolInputIsVisible(input: String) -> Bool {
  !input.isEmpty
}

struct ContentView: View {
  @StateObject private var store: NativeChatStore

  init(store: NativeChatStore) {
    _store = StateObject(wrappedValue: store)
  }

  var body: some View {
    VStack(spacing: 14) {
      header
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(store.transcript) { item in
              ChatItemView(item: item)
                .id(item.id)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: store.transcript) {
          guard let last = store.transcript.last else { return }
          proxy.scrollTo(last.id, anchor: .bottom)
        }
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
        .lineLimit(1)
        .truncationMode(.tail)
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
        "Ask anything…",
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
            .foregroundStyle(store.canSubmit ? Color.white : Color.secondary)
            .frame(width: 30, height: 30)
            .background(
              store.canSubmit ? Color.accentColor : Color.secondary.opacity(0.14),
              in: Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Send")
        .disabled(!store.canSubmit)
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
    .disabled(store.modelState != .ready || store.isBusy)
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
    case .assistantHeader:
      Text("Vivi")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .assistant(_, let text):
      MarkdownContentView(source: text)
    case .reasoning(_, let text):
      ExpandableCard {
        Text("Reasoning")
      } content: {
        MarkdownContentView(source: text)
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 10)
          .padding(.bottom, 10)
      }
    case .tool(_, let activity):
      ToolActivityView(activity: activity)
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

  private struct ToolActivityView: View {
    let activity: ToolActivity

    var body: some View {
      ExpandableCard {
        Label {
          HStack(spacing: 6) {
            Text(activity.title)
            Text(status)
              .font(.caption)
              .foregroundStyle(statusColor)
          }
        } icon: {
          Image(systemName: icon)
            .foregroundStyle(statusColor)
        }
      } content: {
        VStack(alignment: .leading, spacing: 8) {
          if !activity.detail.isEmpty {
            detail("Detail", .literal(activity.detail))
          }
          if toolInputIsVisible(input: activity.input) {
            inputDetail
          }
          if let output = activity.outputPresentation, !output.text.isEmpty {
            detail("Output", output)
          }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
      }
    }

    private var inputDetail: some View {
      VStack(alignment: .leading, spacing: 2) {
        Text("Input")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        switch toolInputLayout(
          input: activity.input,
          presentation: activity.inputPresentation)
        {
        case .presentation(let presentation):
          PresentationView(presentation: presentation)
        case .presentationWithCanonicalJSON(let presentation, let canonicalJSON):
          PresentationView(presentation: presentation)
          VStack(alignment: .leading, spacing: 2) {
            Text("Canonical JSON")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
              Text(canonicalJSON)
                .font(.system(.body, design: .monospaced))
                .fixedSize(horizontal: true, vertical: true)
            }
            .textSelection(.enabled)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func detail(_ label: String, _ value: ToolPresentation) -> some View {
      VStack(alignment: .leading, spacing: 2) {
        Text(label)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        PresentationView(presentation: value)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var status: String {
      switch activity.result {
      case .running: "Running"
      case .succeeded: "Succeeded"
      case .failed: "Failed"
      case .image: "Image"
      }
    }

    private var icon: String {
      switch activity.result {
      case .running: "circle.dotted"
      case .succeeded: "checkmark.circle.fill"
      case .failed: "xmark.circle.fill"
      case .image: "photo"
      }
    }

    private var statusColor: Color {
      switch activity.result {
      case .running: .secondary
      case .succeeded: .green
      case .failed: .red
      case .image: .blue
      }
    }
  }

  private struct PresentationView: View {
    let presentation: ToolPresentation
    var inline = false

    @ViewBuilder
    var body: some View {
      switch presentation {
      case .literal(let text):
        Text(text)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
      case .markdown(let text):
        MarkdownContentView(source: text)
      case .source(let text, _, let spans):
        if inline {
          Text(attributedSource(text, spans: spans))
            .font(.system(.body, design: .monospaced))
            .fixedSize(horizontal: true, vertical: true)
        } else {
          ScrollView(.horizontal) {
            Text(attributedSource(text, spans: spans))
              .font(.system(.body, design: .monospaced))
              .fixedSize(horizontal: true, vertical: true)
          }
          .textSelection(.enabled)
        }
      }
    }

    private func attributedSource(_ text: String, spans: [SemanticSpan]) -> AttributedString {
      var result = AttributedString(text)
      var boundaries: [Int: String.Index] = [0: text.startIndex]
      var offset = 0
      var index = text.unicodeScalars.startIndex
      while index < text.unicodeScalars.endIndex {
        let next = text.unicodeScalars.index(after: index)
        offset += text.unicodeScalars[index].utf8.count
        boundaries[offset] = next
        index = next
      }
      for span in spans {
        guard let lower = boundaries[span.byteRange.lowerBound],
          let upper = boundaries[span.byteRange.upperBound],
          let attributedLower = AttributedString.Index(lower, within: result),
          let attributedUpper = AttributedString.Index(upper, within: result)
        else { continue }
        result[attributedLower..<attributedUpper].foregroundColor = color(span.token)
      }
      return result
    }

    private func color(_ token: SemanticToken) -> Color {
      switch token {
      case .comment: .secondary
      case .string, .inserted: .green
      case .number, .constant: .orange
      case .keyword: .purple
      case .function, .meta: .cyan
      case .property: .yellow
      case .operator: .pink
      case .deleted: .red
      }
    }
  }

  private struct ExpandableCard<Label: View, Content: View>: View {
    @State private var isExpanded = false

    private let label: Label
    private let content: Content

    init(
      @ViewBuilder label: () -> Label,
      @ViewBuilder content: () -> Content
    ) {
      self.label = label()
      self.content = content()
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        Button {
          withAnimation(.easeInOut(duration: 0.16)) {
            isExpanded.toggle()
          }
        } label: {
          HStack(spacing: 8) {
            Image(systemName: "chevron.right")
              .font(.caption.weight(.semibold))
              .rotationEffect(.degrees(isExpanded ? 90 : 0))
              .accessibilityHidden(true)
            label
            Spacer(minLength: 0)
          }
          .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
          .contentShape(Rectangle())
          .padding(10)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

        if isExpanded {
          content
            .transition(.opacity)
        }
      }
      .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
  }

  private struct MarkdownContentView: View {
    let source: String

    private var blocks: [MarkdownBlock] {
      markdownBlocks(source)
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
          blockView(block)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
      switch block.kind {
      case .paragraph:
        Text(block.content)
          .fixedSize(horizontal: false, vertical: true)
      case .heading(let level):
        Text(block.content)
          .font(headingFont(level))
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, level > 2 ? 2 : 6)
      case .unorderedListItem:
        listRow(prefix: "•", content: block.content)
      case .orderedListItem(let ordinal):
        listRow(prefix: "\(ordinal).", content: block.content)
      case .code:
        ScrollView(.horizontal) {
          if let presentation = block.codePresentation {
            PresentationView(presentation: presentation, inline: true)
          } else {
            Text(block.content)
          }
        }
        .font(.system(.body, design: .monospaced))
        .fixedSize(horizontal: true, vertical: true)
        .padding(10)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
      case .quote:
        HStack(alignment: .top, spacing: 10) {
          Rectangle()
            .fill(.secondary.opacity(0.45))
            .frame(width: 2)
          Text(block.content)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      case .thematicBreak:
        Divider()
          .padding(.vertical, 4)
      }
    }

    private func listRow(prefix: String, content: AttributedString) -> some View {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(prefix)
          .foregroundStyle(.secondary)
          .frame(minWidth: 16, alignment: .trailing)
        Text(content)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.leading, 4)
    }

    private func headingFont(_ level: Int) -> Font {
      switch level {
      case 1: .title2.weight(.bold)
      case 2: .title3.weight(.semibold)
      default: .headline
      }
    }

  }
}
