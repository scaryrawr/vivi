import AppKit

@MainActor
protocol WorkspaceChoosing: AnyObject {
  func chooseWorkspace() async -> URL?
  func cancel()
}

@MainActor
final class AppKitWorkspaceChooser: WorkspaceChoosing {
  private var continuation: CheckedContinuation<URL?, Never>?
  private var panel: NSOpenPanel?

  func chooseWorkspace() async -> URL? {
    precondition(panel == nil)
    return await withCheckedContinuation { continuation in
      self.continuation = continuation

      let panel = NSOpenPanel()
      panel.title = "New Conversation"
      panel.message = "Choose a workspace for the new conversation."
      panel.prompt = "Choose"
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.allowsMultipleSelection = false
      panel.canCreateDirectories = false
      self.panel = panel
      panel.begin { [weak self] response in
        MainActor.assumeIsolated {
          self?.finish(response == .OK ? panel.url : nil)
        }
      }
    }
  }

  func cancel() {
    panel?.close()
    finish(nil)
  }

  private func finish(_ url: URL?) {
    guard let continuation else { return }
    self.continuation = nil
    panel = nil
    continuation.resume(returning: url)
  }
}
