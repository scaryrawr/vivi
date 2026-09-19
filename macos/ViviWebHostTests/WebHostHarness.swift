import CryptoKit
import Foundation
import WebKit

struct ScriptMessageContext: Equatable {
  let name: String
  let isMainFrame: Bool
  let securityProtocol: String
  let securityHost: String
  let securityPort: Int
}

enum ScriptMessagePolicy {
  static let expected = ScriptMessageContext(
    name: "viviHostV1",
    isMainFrame: true,
    securityProtocol: "vivi-test",
    securityHost: "app",
    securityPort: 0)

  enum Rejection: Error, Equatable {
    case wrongHandler
    case nonMainFrame
    case unexpectedOrigin
  }

  static func validate(_ context: ScriptMessageContext) throws {
    guard context.name == expected.name else { throw Rejection.wrongHandler }
    guard context.isMainFrame else { throw Rejection.nonMainFrame }
    guard context.securityProtocol == expected.securityProtocol,
      context.securityHost == expected.securityHost,
      context.securityPort == expected.securityPort
    else { throw Rejection.unexpectedOrigin }
  }
}

@MainActor
final class WebHostHarness: NSObject {
  static let contentSecurityPolicy =
    "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'none'; base-uri 'none'; form-action 'none'"

  private static let handlerName = "viviHostV1"
  private let runtime: NativeHostRuntime
  private let resourceBundle: Bundle
  private let loadRequest: (WKWebView, URLRequest) -> Void
  private let deliverMessage: (@MainActor (WKWebView, [String: Any]) async throws -> Void)?
  private var assetSchemeHandler: LocalAssetSchemeHandler?
  private var scriptMessageHandler: WeakScriptMessageHandler?
  private var runGeneration = 0
  private var isStarting = false
  private(set) var bridgeSessionID: UUID?
  private var loadContinuation: CheckedContinuation<Void, Error>?
  private var isRunning = false
  private(set) var webView: WKWebView?
  private(set) var receivedMessageCount = 0
  private(set) var lastBridgeError: HostWireV1.ValidationError?
  private(set) var lastPolicyError: ScriptMessagePolicy.Rejection?
  private(set) var lastDeliveryError: BridgeDeliveryError?
  private(set) var hasInstalledScriptHandlers = false

  init(
    adapter: any WebHostDomainAdapter = DeterministicWebHostAdapter(),
    resourceBundle: Bundle = Bundle(for: WebHostHarness.self),
    loadRequest: @escaping (WKWebView, URLRequest) -> Void = { webView, request in
      webView.load(request)
    },
    deliverMessage: (@MainActor (WKWebView, [String: Any]) async throws -> Void)? = nil
  ) {
    runtime = NativeHostRuntime(adapter: adapter)
    self.resourceBundle = resourceBundle
    self.loadRequest = loadRequest
    self.deliverMessage = deliverMessage
    super.init()
  }

  func start() async throws {
    guard !isStarting else { throw LifecycleError.startInProgress }
    guard webView == nil else { return }
    isStarting = true
    defer { isStarting = false }
    let generation = runGeneration
    let assets = try verifiedAssetsDirectory()
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    let controller = WKUserContentController()
    let rule = try await compileNetworkDenyRule()
    guard generation == runGeneration else { throw CancellationError() }
    controller.add(rule)
    let scriptMessageHandler = WeakScriptMessageHandler(owner: self)
    controller.add(scriptMessageHandler, name: Self.handlerName)
    self.scriptMessageHandler = scriptMessageHandler
    hasInstalledScriptHandlers = true
    configuration.userContentController = controller
    let assetSchemeHandler = LocalAssetSchemeHandler(assets: assets)
    configuration.setURLSchemeHandler(assetSchemeHandler, forURLScheme: "vivi-test")
    self.assetSchemeHandler = assetSchemeHandler

    let webView = WKWebView(
      frame: .init(x: 0, y: 0, width: 1200, height: 800), configuration: configuration)
    webView.navigationDelegate = self
    webView.uiDelegate = self
    self.webView = webView
    isRunning = true
    do {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          loadContinuation = continuation
          loadRequest(webView, URLRequest(url: URL(string: "vivi-test://app/native.html")!))
        }
      } onCancel: {
        Task { @MainActor [weak self] in
          self?.stop()
        }
      }
    } catch {
      if generation == runGeneration {
        stop()
      }
      throw error
    }
  }

  func stop() {
    isRunning = false
    runGeneration += 1
    runtime.stop()
    loadContinuation?.resume(throwing: CancellationError())
    loadContinuation = nil
    guard let webView else { return }
    webView.stopLoading()
    webView.configuration.userContentController.removeAllScriptMessageHandlers()
    scriptMessageHandler?.invalidate()
    scriptMessageHandler = nil
    hasInstalledScriptHandlers = false
    webView.configuration.userContentController.removeAllContentRuleLists()
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
    self.webView = nil
    assetSchemeHandler = nil
    bridgeSessionID = nil
  }

  func allowsNavigation(
    to url: URL?,
    isMainFrame: Bool,
    navigationType: WKNavigationType
  ) -> Bool {
    isMainFrame && url?.scheme == "vivi-test" && url?.host == "app"
      && url?.path == "/native.html" && url?.query == nil
      && navigationType == .other
  }

  private func verifiedAssetsDirectory() throws -> VerifiedAssets {
    guard let assets = resourceBundle.resourceURL?.appending(path: "ViviWebAssets"),
      FileManager.default.fileExists(atPath: assets.path),
      let manifestURL = resourceBundle.url(
        forResource: "asset-manifest",
        withExtension: "json",
        subdirectory: "ViviWebAssets"),
      let manifestData = try? Data(contentsOf: manifestURL),
      let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: String],
      !manifest.isEmpty
    else {
      throw AssetError.missing
    }
    var verifiedFiles: [String: Data] = [:]
    for (relativePath, expectedDigest) in manifest {
      guard relativePath != "asset-manifest.json",
        !relativePath.hasPrefix("/"),
        !relativePath.split(separator: "/").contains("..")
      else { throw AssetError.invalidManifest }
      let data = try Data(contentsOf: assets.appending(path: relativePath))
      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      guard digest == expectedDigest else {
        throw AssetError.digestMismatch(relativePath)
      }
      verifiedFiles[relativePath] = data
    }
    guard let indexData = verifiedFiles["native.html"],
      let index = String(data: indexData, encoding: .utf8)
    else {
      throw AssetError.missing
    }
    let decodedIndex = index.replacingOccurrences(of: "&#39;", with: "'")
    guard decodedIndex.components(separatedBy: Self.contentSecurityPolicy).count == 2,
      decodedIndex.contains("http-equiv=\"Content-Security-Policy\"")
    else {
      throw AssetError.contentSecurityPolicyMismatch
    }
    return VerifiedAssets(files: verifiedFiles)
  }

  private func compileNetworkDenyRule() async throws -> WKContentRuleList {
    let source =
      """
      [
        {"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
        {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
        {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}},
        {"trigger":{"url-filter":"^file://"},"action":{"type":"block"}}
      ]
      """
    return try await withCheckedThrowingContinuation { continuation in
      WKContentRuleListStore.default().compileContentRuleList(
        forIdentifier: "com.scaryrawr.vivi.test-only.network-deny",
        encodedContentRuleList: source
      ) { rule, error in
        if let rule {
          continuation.resume(returning: rule)
        } else {
          continuation.resume(throwing: error ?? AssetError.ruleCompilation)
        }
      }
    }
  }

  fileprivate func receive(_ message: WKScriptMessage) async {
    let origin = message.frameInfo.securityOrigin
    await receive(
      context: ScriptMessageContext(
        name: message.name,
        isMainFrame: message.frameInfo.isMainFrame,
        securityProtocol: origin.protocol,
        securityHost: origin.host,
        securityPort: origin.port),
      body: message.body)
  }

  func receive(context: ScriptMessageContext, body: Any) async {
    guard isRunning else { return }
    let generation = runGeneration
    do {
      try ScriptMessagePolicy.validate(context)
    } catch let error as ScriptMessagePolicy.Rejection {
      lastPolicyError = error
      return
    } catch {
      preconditionFailure("ScriptMessagePolicy only throws typed rejections")
    }
    receivedMessageCount += 1
    do {
      let request = try HostWireV1.decodeRequest(body)
      let messages = runtime.handle(request)
      if request.command == .connect,
        messages.contains(where: { $0["kind"] as? String == "response" })
      {
        bridgeSessionID = request.bridgeSessionID
      }
      for message in messages {
        try await send(message, generation: generation)
      }
    } catch let error as HostWireV1.ValidationError {
      lastBridgeError = error
      guard let bridgeSessionID = bridgeSessionID ?? bridgeSessionID(from: body) else { return }
      do {
        try await send(
          HostWireV1.failure(bridgeSessionID: bridgeSessionID, error: error),
          generation: generation)
      } catch let deliveryError as BridgeDeliveryError {
        reportDeliveryFailure(deliveryError, generation: generation)
      } catch {
        preconditionFailure("send only throws BridgeDeliveryError")
      }
    } catch let deliveryError as BridgeDeliveryError {
      reportDeliveryFailure(deliveryError, generation: generation)
    } catch {
      preconditionFailure("WebHostHarness received an unexpected error type")
    }
  }

  private func bridgeSessionID(from body: Any) -> UUID? {
    guard let body = body as? [String: Any],
      let value = body["bridgeSessionId"] as? String
    else { return nil }
    return UUID(uuidString: value)
  }

  private func send(_ message: [String: Any], generation: Int) async throws {
    guard JSONSerialization.isValidJSONObject(message) else {
      throw BridgeDeliveryError.invalidEnvelope
    }
    guard isRunning, generation == runGeneration, let webView else {
      throw BridgeDeliveryError.hostStopped
    }
    if let deliverMessage {
      do {
        try await deliverMessage(webView, message)
      } catch let error as BridgeDeliveryError {
        throw error
      } catch {
        throw BridgeDeliveryError.javaScript(String(describing: error))
      }
      return
    }
    do {
      _ = try await webView.callAsyncJavaScript(
        """
        if (typeof window.__viviHostV1Receive !== "function") {
          throw new Error("Vivi host receiver is unavailable");
        }
        window.__viviHostV1Receive(message);
        """,
        arguments: ["message": message],
        in: nil,
        contentWorld: .page)
    } catch {
      throw BridgeDeliveryError.javaScript(String(describing: error))
    }
  }

  private func reportDeliveryFailure(_ error: BridgeDeliveryError, generation: Int) {
    guard isRunning, generation == runGeneration else { return }
    lastDeliveryError = error
    runtime.deliveryFailed()
  }

  enum BridgeDeliveryError: Error, Equatable {
    case invalidEnvelope
    case hostStopped
    case javaScript(String)
  }

  enum LifecycleError: Error, Equatable {
    case startInProgress
  }

  enum AssetError: Error, Equatable {
    case missing
    case invalidManifest
    case digestMismatch(String)
    case contentSecurityPolicyMismatch
    case ruleCompilation
  }

  struct VerifiedAssets {
    let files: [String: Data]
  }
}

final class OrderedMainActorTaskQueue: @unchecked Sendable {
  private let lock = NSLock()
  private var generation = 0
  private var tail: Task<Void, Never>?

  func enqueue(_ operation: @escaping @MainActor @Sendable () async -> Void) {
    lock.lock()
    let previous = tail
    let generation = generation
    let task = Task { @MainActor [weak self] in
      await previous?.value
      guard self?.isCurrent(generation) == true else { return }
      await operation()
    }
    tail = task
    lock.unlock()
  }

  func invalidate() {
    lock.lock()
    generation += 1
    tail?.cancel()
    tail = nil
    lock.unlock()
  }

  private func isCurrent(_ candidate: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return candidate == generation
  }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
  private struct Message: @unchecked Sendable {
    let value: WKScriptMessage
  }

  private let queue = OrderedMainActorTaskQueue()
  weak var owner: WebHostHarness?

  init(owner: WebHostHarness) {
    self.owner = owner
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    let message = Message(value: message)
    queue.enqueue { @MainActor [weak owner] in
      await owner?.receive(message.value)
    }
  }

  func invalidate() {
    owner = nil
    queue.invalidate()
  }
}

private final class LocalAssetSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
  private let assets: WebHostHarness.VerifiedAssets

  init(assets: WebHostHarness.VerifiedAssets) {
    self.assets = assets
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
    guard let url = urlSchemeTask.request.url,
      url.scheme == "vivi-test",
      url.host == "app"
    else {
      urlSchemeTask.didFailWithError(URLError(.badURL))
      return
    }
    let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
    guard !components.isEmpty, !components.contains("..") else {
      urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
      return
    }
    let relativePath = components.joined(separator: "/")
    guard let data = assets.files[relativePath] else {
      urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
      return
    }
    let pathExtension = URL(fileURLWithPath: relativePath).pathExtension
    let response = URLResponse(
      url: url,
      mimeType: mimeType(for: pathExtension),
      expectedContentLength: data.count,
      textEncodingName: pathExtension == "html" ? "utf-8" : nil)
    urlSchemeTask.didReceive(response)
    urlSchemeTask.didReceive(data)
    urlSchemeTask.didFinish()
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

  private func mimeType(for pathExtension: String) -> String {
    switch pathExtension {
    case "html": "text/html"
    case "js": "text/javascript"
    case "css": "text/css"
    case "json": "application/json"
    case "svg": "image/svg+xml"
    case "png": "image/png"
    default: "application/octet-stream"
    }
  }
}

extension WebHostHarness: WKNavigationDelegate {
  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction
  ) async -> WKNavigationActionPolicy {
    let allowed = allowsNavigation(
      to: navigationAction.request.url,
      isMainFrame: navigationAction.targetFrame?.isMainFrame == true,
      navigationType: navigationAction.navigationType)
    return allowed ? .allow : .cancel
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    loadContinuation?.resume()
    loadContinuation = nil
  }

  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: Error
  ) {
    loadContinuation?.resume(throwing: error)
    loadContinuation = nil
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    loadContinuation?.resume(throwing: error)
    loadContinuation = nil
  }
}

extension WebHostHarness: WKUIDelegate {
  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    nil
  }
}
