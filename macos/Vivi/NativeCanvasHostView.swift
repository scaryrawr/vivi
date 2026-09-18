import SwiftUI
import WebKit

struct NativeCanvasHostView: View {
  @ObservedObject var rendererStore: NativeCanvasRendererStore
  let canvases: NativeCanvasStore

  var body: some View {
    if !rendererStore.renderers.isEmpty {
      TabView {
        ForEach(rendererStore.renderers, id: \.lease) { renderer in
          CanvasRendererPane(renderer: renderer) {
            _ = canvases.close(renderer.lease)
          }
          .tabItem {
            Text(renderer.title)
          }
        }
      }
      .frame(minHeight: 220, idealHeight: 320)
      .accessibilityIdentifier("canvas-host")
    }
  }
}

private struct CanvasRendererPane: View {
  @ObservedObject var renderer: NativeCanvasRenderer
  let close: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(renderer.title)
            .font(.headline)
            .lineLimit(1)
          if let status = renderer.status {
            Text(status)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer()
        Button("Close", systemImage: "xmark", action: close)
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .accessibilityLabel("Close \(renderer.title)")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.bar)

      Divider()

      switch renderer.state {
      case .preparing:
        ProgressView("Preparing canvas…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .ready:
        if let webView = renderer.webView {
          ExistingCanvasWebView(webView: webView)
        } else {
          canvasMessage("Canvas renderer unavailable.", systemImage: "exclamationmark.triangle")
        }
      case .blocked(let message):
        canvasMessage(message, systemImage: "lock.shield")
      case .failed(let message):
        canvasMessage(message, systemImage: "exclamationmark.triangle")
      case .tornDown:
        EmptyView()
      }
    }
    .accessibilityIdentifier(
      "canvas-\(renderer.lease.key.declarationID.extensionID)-"
        + "\(renderer.lease.key.declarationID.canvasID)-"
        + renderer.lease.key.instanceID.encodedValue)
  }

  private func canvasMessage(_ message: String, systemImage: String) -> some View {
    ContentUnavailableView {
      Label("Canvas Unavailable", systemImage: systemImage)
    } description: {
      Text(message)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct ExistingCanvasWebView: NSViewRepresentable {
  let webView: WKWebView

  func makeNSView(context: Context) -> WKWebView {
    webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {}
}
