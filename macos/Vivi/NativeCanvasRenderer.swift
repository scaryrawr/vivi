import AppKit
import Combine
import Foundation
import WebKit

enum CanvasRendererState: Equatable {
  case preparing
  case ready
  case blocked(String)
  case failed(String)
  case tornDown
}

@MainActor
final class NativeCanvasRenderer: NSObject, ObservableObject {
  let lease: CanvasRenderLease
  let title: String
  let status: String?
  @Published private(set) var state: CanvasRendererState = .preparing
  @Published private(set) var webView: WKWebView?

  private let policy: NativeCanvasSecurityPolicy
  private let acceptsLease: (CanvasRenderLease) -> Bool
  private var authorizedURL: CanvasAuthorizedURL?
  private var contentRuleIdentifier: String?
  private var tornDown = false

  init(
    lease: CanvasRenderLease,
    title: String,
    status: String?,
    url: String?,
    policy: NativeCanvasSecurityPolicy,
    acceptsLease: @escaping (CanvasRenderLease) -> Bool
  ) {
    self.lease = lease
    self.title = title
    self.status = status
    self.policy = policy
    self.acceptsLease = acceptsLease
    super.init()

    guard let url else {
      state = .blocked("The canvas provider did not supply a renderer URL.")
      return
    }
    do {
      authorizedURL = try policy.authorize(url)
      prepare()
    } catch {
      state = .blocked("The canvas URL is outside Vivi’s allowed origin policy.")
    }
  }

  func tearDown(finalState: CanvasRendererState = .tornDown) {
    guard !tornDown else { return }
    tornDown = true
    let view = webView
    webView = nil
    view?.stopLoading()
    view?.navigationDelegate = nil
    view?.uiDelegate = nil
    view?.removeFromSuperview()
    if let contentRuleIdentifier {
      WKContentRuleListStore.default().removeContentRuleList(
        forIdentifier: contentRuleIdentifier
      ) { _ in }
    }
    contentRuleIdentifier = nil
    authorizedURL = nil
    state = finalState
  }

  private func prepare() {
    guard let authorizedURL, acceptsLease(lease) else {
      state = .tornDown
      return
    }
    let identifier = "vivi-canvas-\(UUID().uuidString)"
    contentRuleIdentifier = identifier
    let encodedRules: String
    do {
      encodedRules = try Self.contentRules(for: authorizedURL.origin)
    } catch {
      state = .failed("Vivi could not create the canvas network policy.")
      return
    }
    WKContentRuleListStore.default().compileContentRuleList(
      forIdentifier: identifier,
      encodedContentRuleList: encodedRules
    ) { [weak self] ruleList, error in
      Task { @MainActor [weak self] in
        guard let self, !self.tornDown, self.acceptsLease(self.lease) else { return }
        guard error == nil, let ruleList, let authorizedURL = self.authorizedURL else {
          self.state = .failed("Vivi could not create the canvas network policy.")
          return
        }
        self.installWebView(ruleList: ruleList, authorizedURL: authorizedURL)
      }
    }
  }

  private func installWebView(
    ruleList: WKContentRuleList,
    authorizedURL: CanvasAuthorizedURL
  ) {
    let configuration = Self.makeConfiguration()
    configuration.userContentController.add(ruleList)

    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = self
    view.uiDelegate = self
    webView = view
    state = .ready
    view.load(URLRequest(url: authorizedURL.url))
  }

  private func accepts(_ url: URL?) -> Bool {
    guard !tornDown, acceptsLease(lease), let url, let authorizedURL else {
      return false
    }
    return policy.allows(url, for: authorizedURL.origin)
  }

  static func makeConfiguration() -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController = WKUserContentController()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.allowsAirPlayForMediaPlayback = false
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    return configuration
  }

  static func contentRules(for origin: CanvasRendererOrigin) throws -> String {
    let rules: [[String: Any]] = [
      [
        "trigger": ["url-filter": ".*"],
        "action": ["type": "block"],
      ],
      [
        "trigger": ["url-filter": origin.contentRuleURLFilter],
        "action": ["type": "ignore-previous-rules"],
      ],
    ]
    let data = try JSONSerialization.data(withJSONObject: rules)
    guard let value = String(data: data, encoding: .utf8) else {
      throw CanvasRendererPolicyError.invalidURL
    }
    return value
  }
}

extension NativeCanvasRenderer: WKNavigationDelegate {
  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    guard navigationAction.targetFrame != nil,
      !navigationAction.shouldPerformDownload,
      accepts(navigationAction.request.url)
    else {
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
  ) {
    guard accepts(navigationResponse.response.url),
      navigationResponse.canShowMIMEType
    else {
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard acceptsLease(lease) else {
      tearDown()
      return
    }
    tearDown(finalState: .failed("The canvas renderer process stopped."))
  }

  func webView(
    _ webView: WKWebView,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @MainActor (
        URLSession.AuthChallengeDisposition, URLCredential?
      ) -> Void
  ) {
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      completionHandler(.performDefaultHandling, nil)
    } else {
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }
}

extension NativeCanvasRenderer: WKUIDelegate {
  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    nil
  }

  @available(macOS 12.0, *)
  func webView(
    _ webView: WKWebView,
    requestMediaCapturePermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo,
    type: WKMediaCaptureType,
    decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
  ) {
    decisionHandler(.deny)
  }

  func webView(
    _ webView: WKWebView,
    runOpenPanelWith parameters: WKOpenPanelParameters,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor ([URL]?) -> Void
  ) {
    completionHandler(nil)
  }
}

@MainActor
final class NativeCanvasRendererStore: ObservableObject {
  @Published private(set) var renderers: [NativeCanvasRenderer] = []

  private let configuration: NativeCanvasConfiguration
  private var acceptsLease: (CanvasRenderLease) -> Bool = { _ in false }
  private var presentationSuspended = false

  init(configuration: NativeCanvasConfiguration) {
    self.configuration = configuration
  }

  func setLeaseValidator(_ validator: @escaping (CanvasRenderLease) -> Bool) {
    acceptsLease = validator
  }

  func reconcile(_ presentation: NativeCanvasPresentation, canvases: NativeCanvasStore) {
    guard configuration.enabled, !presentationSuspended else {
      tearDownAll()
      return
    }

    var existing = Dictionary(uniqueKeysWithValues: renderers.map { ($0.lease.key, $0) })
    var next: [NativeCanvasRenderer] = []
    for instance in presentation.instances {
      guard case .opened(let opened) = instance.runtime,
        let lease = canvases.renderLease(for: instance.key)
      else { continue }
      if let renderer = existing.removeValue(forKey: instance.key),
        renderer.lease == lease
      {
        next.append(renderer)
        continue
      }
      existing.removeValue(forKey: instance.key)?.tearDown()
      next.append(
        NativeCanvasRenderer(
          lease: lease,
          title: opened.title ?? instance.declaration?.displayName ?? "Canvas",
          status: opened.status,
          url: opened.url,
          policy: configuration.securityPolicy,
          acceptsLease: acceptsLease))
    }
    for renderer in existing.values {
      renderer.tearDown()
    }
    renderers = next
  }

  func handle(_ directive: CanvasHostDirective) {
    switch directive {
    case .teardown(let lease, _):
      guard let renderer = renderers.first(where: { $0.lease == lease }) else { return }
      renderer.tearDown()
      renderers.removeAll { $0 === renderer }
    case .teardownAll:
      tearDownAll()
    }
  }

  func suspendPresentation() {
    presentationSuspended = true
    tearDownAll()
  }

  func resumePresentation() -> Bool {
    let wasSuspended = presentationSuspended
    presentationSuspended = false
    return wasSuspended
  }

  private func tearDownAll() {
    for renderer in renderers {
      renderer.tearDown()
    }
    renderers = []
  }
}
