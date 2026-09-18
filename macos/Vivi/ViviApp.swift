import AppKit
import Combine
import SwiftUI

@main
struct ViviApp: App {
  @NSApplicationDelegateAdaptor(ViviAppDelegate.self) private var appDelegate

  var body: some Scene {
    Settings {
      EmptyView()
    }
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("New Conversation") {
          appDelegate.requestNewConversation()
        }
        .keyboardShortcut("n")
        .disabled(!appDelegate.canRequestNewConversation)
      }
    }
  }
}

@MainActor
final class ViviAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
  @Published private(set) var canRequestNewConversation = true

  private let applicationCoordinator: NativeApplicationCoordinator
  private var presentationObservation: AnyCancellable?

  override init() {
    applicationCoordinator = .live()
    super.init()
    observePresentation()
  }

  init(applicationCoordinator: NativeApplicationCoordinator) {
    self.applicationCoordinator = applicationCoordinator
    super.init()
    observePresentation()
  }

  func requestNewConversation() {
    applicationCoordinator.requestNewConversation()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    applicationCoordinator.presentMainWindow()
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    applicationCoordinator.open(urls)
  }

  func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
    applicationCoordinator.presentMainWindow()
    return true
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows _: Bool
  ) -> Bool {
    applicationCoordinator.presentMainWindow()
    return false
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    applicationCoordinator.beginTermination {
      sender.reply(toApplicationShouldTerminate: true)
    }
  }

  private func observePresentation() {
    presentationObservation = applicationCoordinator.presentation.$workspaceChoice
      .map { !$0.isChoosing }
      .removeDuplicates()
      .sink { [weak self] canRequest in
        self?.canRequestNewConversation = canRequest
      }
  }
}
