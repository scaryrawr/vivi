import AppKit
import SwiftUI

@main
struct ViviApp: App {
  @NSApplicationDelegateAdaptor(ViviAppDelegate.self) private var appDelegate

  var body: some Scene {
    Settings {
      EmptyView()
    }
  }
}

@MainActor
final class ViviAppDelegate: NSObject, NSApplicationDelegate {
  private let applicationCoordinator: NativeApplicationCoordinator

  override init() {
    applicationCoordinator = .live()
    super.init()
  }

  init(applicationCoordinator: NativeApplicationCoordinator) {
    self.applicationCoordinator = applicationCoordinator
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    applicationCoordinator.presentMainWindow()
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    applicationCoordinator.open(urls)
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    applicationCoordinator.presentMainWindow()
    return false
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    applicationCoordinator.beginTermination {
      sender.reply(toApplicationShouldTerminate: true)
    }
  }
}
