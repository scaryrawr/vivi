import Foundation
import WebKit
import XCTest

@testable import Vivi

@MainActor
final class NativeCanvasSecurityTests: XCTestCase {
  func testExactLoopbackOriginsRequireLiteralHostAndExplicitPort() throws {
    let policy = try NativeCanvasSecurityPolicy()
    let cases = [
      ("http://localhost:4317/canvas", "http://localhost:4317"),
      ("https://127.0.0.1:9443/canvas", "https://127.0.0.1:9443"),
      ("http://[::1]:8080/canvas", "http://[::1]:8080"),
    ]

    for (value, expectedOrigin) in cases {
      XCTAssertEqual(try policy.authorize(value).origin.description, expectedOrigin)
    }
  }

  func testLoopbackPolicyRejectsAliasesPrivateNetworksAndMissingPorts() throws {
    let policy = try NativeCanvasSecurityPolicy()
    let rejected = [
      "http://localhost/canvas",
      "http://foo.localhost:8080/canvas",
      "http://127.1:8080/canvas",
      "http://10.0.0.1:8080/canvas",
      "http://172.16.0.1:8080/canvas",
      "http://192.168.1.1:8080/canvas",
      "http://169.254.169.254:80/latest",
      "http://[fe80::1]:8080/canvas",
      "http://loopback.example:8080/canvas",
      "file:///tmp/canvas.html",
      "data:text/html,canvas",
      "javascript:alert(1)",
    ]

    for value in rejected {
      XCTAssertThrowsError(try policy.authorize(value), value)
    }
  }

  func testRemoteOriginsRequireExactInjectedHTTPSAuthority() throws {
    let policy = try NativeCanvasSecurityPolicy(
      remoteOriginStrings: ["https://canvas.example.test", "https://cdn.example.test:8443"])

    XCTAssertEqual(
      try policy.authorize("https://canvas.example.test/view").origin.description,
      "https://canvas.example.test:443")
    XCTAssertEqual(
      try policy.authorize("https://cdn.example.test:8443/view").origin.description,
      "https://cdn.example.test:8443")
    XCTAssertThrowsError(try policy.authorize("http://canvas.example.test:80/view"))
    XCTAssertThrowsError(try policy.authorize("https://other.example.test/view"))
    XCTAssertThrowsError(
      try NativeCanvasSecurityPolicy(remoteOriginStrings: ["https://127.0.0.1:443"]))
    XCTAssertThrowsError(
      try NativeCanvasSecurityPolicy(remoteOriginStrings: ["https://canvas.example.test:0"]))
  }

  func testRendererAuthorityCannotPivotSchemeHostOrPort() throws {
    let policy = try NativeCanvasSecurityPolicy()
    let authorized = try policy.authorize("http://localhost:8080/canvas")

    XCTAssertTrue(
      policy.allows(URL(string: "http://localhost:8080/script.js")!, for: authorized.origin))
    XCTAssertFalse(
      policy.allows(URL(string: "https://localhost:8080/script.js")!, for: authorized.origin))
    XCTAssertFalse(
      policy.allows(URL(string: "http://localhost:8081/script.js")!, for: authorized.origin))
    XCTAssertFalse(
      policy.allows(URL(string: "http://127.0.0.1:8080/script.js")!, for: authorized.origin))
    XCTAssertFalse(
      policy.allows(URL(string: "ws://localhost:8080/socket")!, for: authorized.origin))
    XCTAssertFalse(
      policy.allows(URL(string: "http://user@localhost:8080/script.js")!, for: authorized.origin))
  }

  func testLiveConfigurationIsDisabledByDefaultAndFailsClosed() {
    XCTAssertEqual(NativeCanvasConfiguration.live(environment: [:]), .disabled)

    let invalid = NativeCanvasConfiguration.live(
      environment: [
        "VIVI_ENABLE_CANVAS": "1",
        "VIVI_CANVAS_REMOTE_ORIGINS": "http://canvas.example.test",
      ])
    XCTAssertFalse(invalid.enabled)
    XCTAssertNotNil(invalid.configurationFailure)
  }

  func testRendererConfigurationIsEphemeralAndHasNoInjectedScripts() {
    let configuration = NativeCanvasRenderer.makeConfiguration()

    XCTAssertFalse(configuration.websiteDataStore === WKWebsiteDataStore.default())
    XCTAssertTrue(configuration.userContentController.userScripts.isEmpty)
    XCTAssertFalse(configuration.preferences.javaScriptCanOpenWindowsAutomatically)
    XCTAssertEqual(configuration.mediaTypesRequiringUserActionForPlayback, .all)
  }

  func testContentRulesBlockEverythingBeforeAllowingOnlyExactOrigin() throws {
    let policy = try NativeCanvasSecurityPolicy()
    let origin = try policy.authorize("http://127.0.0.1:8080/canvas").origin
    let encoded = try NativeCanvasRenderer.contentRules(for: origin)
    let rules = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [[String: Any]])

    XCTAssertEqual(rules.count, 2)
    XCTAssertEqual((rules[0]["action"] as? [String: String])?["type"], "block")
    XCTAssertEqual(
      (rules[1]["action"] as? [String: String])?["type"],
      "ignore-previous-rules")
    let filter = try XCTUnwrap((rules[1]["trigger"] as? [String: String])?["url-filter"])
    XCTAssertNotNil(filter.range(of: "127\\.0\\.0\\.1:8080"))
    XCTAssertNil(filter.range(of: "ws"))
  }

  func testDisallowedURLNeverCreatesWebView() throws {
    let key = try CanvasInstanceKey(
      declarationID: CanvasDeclarationID(
        extensionID: "acme.preview",
        canvasID: "diff"),
      instanceID: CanvasInstanceID(validating: "instance-1"))
    let renderer = NativeCanvasRenderer(
      lease: CanvasRenderLease(
        key: key,
        generation: CanvasRendererGeneration(1)!,
        epoch: CanvasRendererEpoch(1)!),
      title: "Preview",
      status: nil,
      url: "http://192.168.1.1:8080/canvas",
      policy: try NativeCanvasSecurityPolicy(),
      acceptsLease: { _ in true })

    XCTAssertNil(renderer.webView)
    XCTAssertEqual(
      renderer.state,
      .blocked("The canvas URL is outside Vivi’s allowed origin policy."))
  }
}
