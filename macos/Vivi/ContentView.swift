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

private enum ChatFocusTarget: Hashable {
  case composer
  case commandSearch
  case commandArgument
}

struct ContentView: View {
  @ObservedObject private var store: NativeChatStore
  @FocusState private var focus: ChatFocusTarget?

  init(store: NativeChatStore) {
    self.store = store
  }

  var body: some View {
    VStack(spacing: 14) {
      header
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(store.transcript) { item in
              ChatItemView(item: item, store: store)
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
      if store.isCommandPalettePresented {
        CommandPaletteView(store: store, focus: $focus)
          .transition(.opacity)
      }
      composer
    }
    .padding(20)
    .frame(minHeight: 420)
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
      .focused($focus, equals: .composer)
      .onChange(of: store.draft) {
        store.composerDraftChanged()
      }
      .disabled(store.activeUserInput != nil)

      if !store.attachments.isEmpty {
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            ForEach(store.attachments) { attachment in
              ComposerAttachmentChip(attachment: attachment) {
                store.removeAttachment(attachment.id)
              }
            }
          }
          .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("composer-attachments")
      }

      if let attachmentError = store.attachmentError {
        Label(attachmentError, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("composer-attachment-error")
      }

      HStack(spacing: 10) {
        Button(action: store.toggleCommandPalette) {
          Image(systemName: "command")
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("k", modifiers: .command)
        .help("Commands (⌘K)")
        .accessibilityLabel("Commands")
        .accessibilityIdentifier("command-palette-button")
        .disabled(store.lifecycle == .closing || store.lifecycle == .closed)

        attachmentMenu
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
    .onChange(of: store.isCommandPalettePresented) { _, presented in
      focus =
        presented
        ? (store.commandArgumentSession == nil ? .commandSearch : .commandArgument)
        : .composer
    }
    .onChange(of: store.commandArgumentSession) {
      focus = store.commandArgumentSession == nil ? .commandSearch : .commandArgument
    }
  }

  private var attachmentMenu: some View {
    Menu {
      Button("Choose Image…", action: store.chooseAttachments)
        .accessibilityIdentifier("composer-choose-image")
      Button("Paste Image", action: store.pasteAttachment)
        .accessibilityIdentifier("composer-paste-image")
    } label: {
      Image(systemName: "paperclip")
        .font(.system(size: 14, weight: .medium))
        .frame(width: 24, height: 24)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .help("Add image attachment")
    .accessibilityLabel("Add image attachment")
    .accessibilityIdentifier("composer-attachment-menu")
    .disabled(!store.canAcquireAttachments)
  }

  private var modelMenu: some View {
    Button {
      store.isModelPickerPresented.toggle()
    } label: {
      Text(modelLabel)
        .lineLimit(1)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .fixedSize()
    .help(selectedModel?.detail ?? "Choose a model and reasoning level")
    .disabled(store.modelState != .ready || store.isBusy)
    .accessibilityIdentifier("model-picker-button")
    .popover(isPresented: $store.isModelPickerPresented, arrowEdge: .top) {
      ModelPickerView(store: store)
    }
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
    case .awaitingInput: return "Waiting for your answer"
    case .closing: return "Closing"
    case .closed: return "Closed"
    }
  }
}

private struct CommandPaletteView: View {
  @ObservedObject var store: NativeChatStore
  var focus: FocusState<ChatFocusTarget?>.Binding

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let argument = store.commandArgumentSession {
        argumentView(argument)
      } else {
        searchView
        catalogContent
      }
    }
    .padding(12)
    .background(.background, in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(.secondary.opacity(0.4), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("command-palette")
    .onAppear {
      focus.wrappedValue =
        store.commandArgumentSession == nil ? .commandSearch : .commandArgument
      announce("Command palette")
    }
    .onChange(of: store.commandCatalogState) { _, state in
      switch state {
      case .loading:
        announce("Loading commands")
      case .failed(let message, _):
        announce("Command loading failed. \(message)")
      case .loaded:
        break
      }
    }
    .onChange(of: store.commandExecution) { _, execution in
      if let execution {
        announce("Running \(execution.command.displayName)")
      }
    }
  }

  private var searchView: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField("Search commands", text: $store.commandQuery)
        .textFieldStyle(.plain)
        .focused(focus, equals: .commandSearch)
        .onChange(of: store.commandQuery) {
          store.moveCommandSelection(0)
        }
        .onSubmit(store.activateSelectedCommand)
        .onKeyPress(.upArrow) {
          store.moveCommandSelection(-1)
          return .handled
        }
        .onKeyPress(.downArrow) {
          store.moveCommandSelection(1)
          return .handled
        }
        .onKeyPress(.escape) {
          store.closeCommandPalette()
          return .handled
        }
        .accessibilityIdentifier("command-palette-search")
      Text("⌘K")
        .font(.caption.monospaced())
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private var catalogContent: some View {
    switch store.commandCatalogState {
    case .loading where store.commandCatalog == nil:
      paletteMessage("Loading commands…", systemImage: "clock")
        .accessibilityIdentifier("command-palette-loading")
    case .failed(let message, let hasFallback):
      VStack(alignment: .leading, spacing: 6) {
        Label(message, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.secondary)
        HStack {
          if hasFallback {
            Text("Showing available built-in commands.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Retry", action: store.retryCommands)
            .disabled(store.commandDisabledReason != nil)
            .accessibilityIdentifier("command-palette-retry")
        }
        commandResults
      }
      .accessibilityIdentifier("command-palette-failure")
    case .loaded, .loading:
      commandResults
    }
  }

  @ViewBuilder
  private var commandResults: some View {
    if store.filteredCommands.isEmpty {
      paletteMessage("No matching commands.", systemImage: "command")
        .accessibilityIdentifier("command-palette-empty")
    } else {
      CommandResultsView(store: store)
    }
    if let execution = store.commandExecution {
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text("Running \(execution.command.displayName)…")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("command-palette-execution")
    } else if let reason = store.commandDisabledReason {
      Label(reason, systemImage: "lock")
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("command-palette-disabled-reason")
    }
  }

  private func argumentView(_ session: CommandArgumentSession) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("/\(session.command.displayName)")
          .font(.headline)
        Spacer()
        Text(session.command.source.label)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let hint = session.command.hint {
        Text(hint)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      TextField(
        session.command.argumentPolicy == .required ? "Required argument" : "Optional argument",
        text: Binding(
          get: { session.draft },
          set: store.updateCommandArgumentDraft)
      )
      .textFieldStyle(.roundedBorder)
      .focused(focus, equals: .commandArgument)
      .onSubmit(store.submitCommandArgument)
      .onKeyPress(.escape) {
        store.exitCommandArgumentMode()
        return .handled
      }
      .accessibilityIdentifier("command-palette-argument")
      HStack {
        Button("Cancel", action: store.exitCommandArgumentMode)
        Spacer()
        Button("Run", action: store.submitCommandArgument)
          .buttonStyle(.borderedProminent)
          .disabled(
            store.commandDisabledReason != nil
              || (session.command.argumentPolicy == .required
                && session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          )
          .accessibilityIdentifier("command-palette-run")
      }
    }
  }

  private func paletteMessage(_ text: String, systemImage: String) -> some View {
    Label(text, systemImage: systemImage)
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 8)
  }

  private func announce(_ message: String) {
    NSAccessibility.post(
      element: NSApp.mainWindow ?? NSApp,
      notification: .announcementRequested,
      userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
  }
}

private struct CommandResultsView: View {
  @ObservedObject var store: NativeChatStore

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 2) {
          ForEach(store.filteredCommands) { command in
            commandRow(command)
              .id(command.key)
          }
        }
      }
      .frame(maxHeight: 260)
      .onChange(of: store.selectedCommandKey) { _, key in
        guard let key else { return }
        withAnimation(.easeOut(duration: 0.12)) {
          proxy.scrollTo(key, anchor: .center)
        }
      }
    }
  }

  private func commandRow(_ command: CommandInfo) -> some View {
    Button {
      store.selectCommand(command.key)
      store.activateSelectedCommand()
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text("/\(command.displayName)")
          .font(.body.weight(.medium))
        Text(command.description)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Spacer(minLength: 8)
        Text(command.source.label)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        store.selectedCommandKey == command.key
          ? Color.accentColor.opacity(0.13) : Color.clear,
        in: RoundedRectangle(cornerRadius: 7)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(store.commandDisabledReason != nil)
    .accessibilityLabel(
      "\(command.displayName), \(command.source.label), \(command.description)"
    )
    .accessibilityAddTraits(
      store.selectedCommandKey == command.key ? .isSelected : []
    )
    .accessibilityIdentifier(
      "command-row-\(command.key.generation)-\(command.key.slot)")
  }
}

private struct ModelPickerView: View {
  @ObservedObject var store: NativeChatStore

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Choose Model")
        .font(.headline)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(store.modelChoices) { model in
            VStack(alignment: .leading, spacing: 4) {
              Text(model.displayName)
                .font(.body.weight(.medium))
              if !model.detail.isEmpty {
                Text(model.detail)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              HStack {
                ForEach(model.reasoning) { effort in
                  Button {
                    store.select(modelID: model.id, reasoning: effort)
                    store.isModelPickerPresented = false
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
                  .buttonStyle(.bordered)
                }
              }
            }
            .padding(.vertical, 4)
          }
        }
      }
      .frame(width: 360, height: 280)
      Divider()
      Button("Refresh Models", systemImage: "arrow.clockwise", action: store.refreshModels)
    }
    .padding(14)
    .accessibilityIdentifier("model-picker")
  }
}

private struct ComposerAttachmentChip: View {
  let attachment: ComposerAttachment
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Group {
        if let preview = attachment.preview {
          Image(decorative: preview, scale: 1)
            .resizable()
            .scaledToFill()
        } else {
          Image(systemName: "photo")
            .foregroundStyle(.secondary)
        }
      }
      .frame(width: 36, height: 36)
      .background(.secondary.opacity(0.08))
      .clipShape(RoundedRectangle(cornerRadius: 7))

      VStack(alignment: .leading, spacing: 1) {
        Text(attachment.displayName)
          .font(.caption.weight(.medium))
          .lineLimit(1)
          .truncationMode(.middle)
        Text("\(attachment.media.label) · \(attachment.sizeLabel)")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: 150, alignment: .leading)

      Button(action: remove) {
        Image(systemName: "xmark")
          .font(.caption.weight(.semibold))
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Remove \(attachment.displayName)")
      .accessibilityLabel("Remove \(attachment.displayName)")
      .accessibilityIdentifier("composer-remove-attachment-\(attachment.id.uuidString)")
    }
    .padding(6)
    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(attachment.displayName)
    .accessibilityValue("\(attachment.media.label), \(attachment.sizeLabel)")
    .accessibilityIdentifier("composer-attachment-\(attachment.id.uuidString)")
  }
}

private struct ChatItemView: View {
  let item: ChatItem
  @ObservedObject var store: NativeChatStore

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
    case .userInput(_, let request, let answer):
      UserInputRequestView(
        request: request,
        answer: answer,
        interaction: store.activeUserInput?.request.id == request.id
          ? store.activeUserInput : nil,
        revealFreeform: store.revealFreeformInput,
        hideFreeform: store.hideFreeformInput,
        updateFreeform: store.updateFreeformDraft,
        submitChoice: store.submitUserInputChoice,
        submitFreeform: store.submitUserInputFreeform)
    }
  }

  private struct UserInputRequestView: View {
    let request: UserInputRequest
    let answer: UserInputAnswer?
    let interaction: ActiveUserInput?
    let revealFreeform: () -> Void
    let hideFreeform: () -> Void
    let updateFreeform: (String) -> Void
    let submitChoice: (String) -> Void
    let submitFreeform: () -> Void

    @FocusState private var freeformFocused: Bool

    var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        Label("Vivi needs your input", systemImage: "questionmark.bubble.fill")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tint)

        Text(request.question)
          .font(.body.weight(.medium))
          .textSelection(.enabled)

        if let answer {
          Label(answer.text, systemImage: "checkmark.circle.fill")
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .accessibilityLabel("Answered \(answer.text)")
        } else if let interaction {
          controls(interaction)
        }
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .stroke(.tint.opacity(0.35), lineWidth: 1)
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(request.question)
      .accessibilityIdentifier("user-input-request")
    }

    @ViewBuilder
    private func controls(_ interaction: ActiveUserInput) -> some View {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(request.choices.enumerated()), id: \.offset) { index, choice in
          Button {
            submitChoice(choice)
          } label: {
            Text(choice)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.bordered)
          .disabled(interaction.state == .submitting)
          .accessibilityLabel(choice)
          .accessibilityHint("Answers Vivi’s question")
          .accessibilityIdentifier("user-input-choice-\(index)")
        }

        if request.allowsFreeform {
          if interaction.showsFreeform {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              TextField(
                "Type your answer",
                text: Binding(
                  get: { interaction.freeformDraft },
                  set: updateFreeform)
              )
              .textFieldStyle(.roundedBorder)
              .focused($freeformFocused)
              .onSubmit(submitFreeform)
              .onKeyPress(.escape) {
                guard !request.choices.isEmpty else { return .ignored }
                hideFreeform()
                return .handled
              }
              .disabled(interaction.state == .submitting)
              .accessibilityIdentifier("user-input-freeform")

              Button("Answer", action: submitFreeform)
                .buttonStyle(.borderedProminent)
                .disabled(
                  interaction.state == .submitting
                    || interaction.freeformDraft
                      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .accessibilityIdentifier("user-input-freeform-submit")
            }
            .onAppear {
              freeformFocused = true
            }
          } else {
            Button("Other…", action: revealFreeform)
              .buttonStyle(.bordered)
              .disabled(interaction.state == .submitting)
              .accessibilityHint("Enter a custom answer")
              .accessibilityIdentifier("user-input-other")
          }
        }

        if interaction.state == .submitting {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
              .accessibilityHidden(true)
            Text("Sending answer…")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel("Sending answer")
          .accessibilityIdentifier("user-input-submitting")
        }

        if case .failed(let message) = interaction.state {
          Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .accessibilityIdentifier("user-input-error")
        }
      }
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
