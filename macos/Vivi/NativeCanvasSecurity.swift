import Foundation

enum CanvasRendererPolicyError: Error, Equatable {
  case invalidURL
  case disallowedOrigin
  case invalidRemoteOrigin
}

struct CanvasRendererOrigin: Hashable, CustomStringConvertible {
  enum Kind: Hashable {
    case loopback
    case remote
  }

  let scheme: String
  let host: String
  let port: Int
  let kind: Kind

  var description: String {
    let renderedHost = host.contains(":") ? "[\(host)]" : host
    return "\(scheme)://\(renderedHost):\(port)"
  }

  var contentRuleURLFilter: String {
    let renderedHost = host.contains(":") ? "[\(host)]" : host
    let authority = NSRegularExpression.escapedPattern(for: "\(scheme)://\(renderedHost)")
    let portPattern = kind == .remote && port == 443 ? "(?::443)?" : ":\(port)"
    return "^\(authority)\(portPattern)(?:[/?#]|$)"
  }
}

struct CanvasAuthorizedURL: Equatable {
  let url: URL
  let origin: CanvasRendererOrigin
}

struct NativeCanvasSecurityPolicy: Equatable {
  let remoteOrigins: Set<CanvasRendererOrigin>

  fileprivate init(remoteOrigins: Set<CanvasRendererOrigin>) {
    self.remoteOrigins = remoteOrigins
  }

  init(remoteOriginStrings: [String] = []) throws {
    var origins: Set<CanvasRendererOrigin> = []
    for value in remoteOriginStrings {
      let origin = try Self.remoteOrigin(value)
      guard origins.insert(origin).inserted else { continue }
    }
    remoteOrigins = origins
  }

  func authorize(_ value: String) throws -> CanvasAuthorizedURL {
    guard let components = URLComponents(string: value),
      components.user == nil,
      components.password == nil,
      let url = components.url,
      let scheme = components.scheme?.lowercased(),
      let rawHost = components.host
    else {
      throw CanvasRendererPolicyError.invalidURL
    }
    let host = Self.normalizedHost(rawHost)
    guard !host.isEmpty else { throw CanvasRendererPolicyError.invalidURL }

    if Self.isLoopbackLiteral(host) {
      guard scheme == "http" || scheme == "https",
        let port = components.port,
        (1...65_535).contains(port)
      else {
        throw CanvasRendererPolicyError.disallowedOrigin
      }
      return CanvasAuthorizedURL(
        url: url,
        origin: CanvasRendererOrigin(
          scheme: scheme,
          host: host,
          port: port,
          kind: .loopback))
    }

    guard scheme == "https" else {
      throw CanvasRendererPolicyError.disallowedOrigin
    }
    let port = components.port ?? 443
    guard (1...65_535).contains(port) else {
      throw CanvasRendererPolicyError.disallowedOrigin
    }
    let origin = CanvasRendererOrigin(
      scheme: scheme,
      host: host,
      port: port,
      kind: .remote)
    guard remoteOrigins.contains(origin) else {
      throw CanvasRendererPolicyError.disallowedOrigin
    }
    return CanvasAuthorizedURL(url: url, origin: origin)
  }

  func allows(_ url: URL, for origin: CanvasRendererOrigin) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.user == nil,
      components.password == nil,
      let scheme = components.scheme?.lowercased(),
      let rawHost = components.host
    else { return false }
    let host = Self.normalizedHost(rawHost)
    guard !host.isEmpty else { return false }

    let port: Int
    switch origin.kind {
    case .loopback:
      guard Self.isLoopbackLiteral(host), let explicitPort = components.port else {
        return false
      }
      port = explicitPort
    case .remote:
      guard scheme == "https" else { return false }
      port = components.port ?? 443
    }
    return scheme == origin.scheme && host == origin.host && port == origin.port
  }

  private static func remoteOrigin(_ value: String) throws -> CanvasRendererOrigin {
    guard let components = URLComponents(string: value),
      components.scheme?.lowercased() == "https",
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      components.path.isEmpty || components.path == "/",
      let rawHost = components.host
    else {
      throw CanvasRendererPolicyError.invalidRemoteOrigin
    }
    let host = normalizedHost(rawHost)
    guard !host.isEmpty,
      !isLoopbackLiteral(host),
      !isLocalOrPrivateLiteral(host)
    else {
      throw CanvasRendererPolicyError.invalidRemoteOrigin
    }
    let port = components.port ?? 443
    guard (1...65_535).contains(port) else {
      throw CanvasRendererPolicyError.invalidRemoteOrigin
    }
    return CanvasRendererOrigin(
      scheme: "https",
      host: host,
      port: port,
      kind: .remote)
  }

  private static func isLoopbackLiteral(_ host: String) -> Bool {
    host == "localhost" || host == "127.0.0.1" || host == "::1"
  }

  private static func normalizedHost(_ value: String) -> String {
    let lower = value.lowercased()
    guard lower.first == "[", lower.last == "]" else { return lower }
    return String(lower.dropFirst().dropLast())
  }

  private static func isLocalOrPrivateLiteral(_ host: String) -> Bool {
    if host.contains(":") {
      let lower = host.lowercased()
      return lower == "::1" || lower.hasPrefix("fc") || lower.hasPrefix("fd")
        || lower.hasPrefix("fe8") || lower.hasPrefix("fe9")
        || lower.hasPrefix("fea") || lower.hasPrefix("feb")
    }
    let octets = host.split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4,
      let a = Int(octets[0]), let b = Int(octets[1]),
      let c = Int(octets[2]), let d = Int(octets[3]),
      [a, b, c, d].allSatisfy({ (0...255).contains($0) })
    else { return false }
    return a == 10 || a == 127 || (a == 169 && b == 254)
      || (a == 172 && (16...31).contains(b))
      || (a == 192 && b == 168)
  }
}

struct NativeCanvasConfiguration: Equatable {
  let enabled: Bool
  let securityPolicy: NativeCanvasSecurityPolicy
  let configurationFailure: String?

  static let disabled = NativeCanvasConfiguration(
    enabled: false,
    securityPolicy: NativeCanvasSecurityPolicy(remoteOrigins: []),
    configurationFailure: nil)

  static func live(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> NativeCanvasConfiguration {
    guard environment["VIVI_ENABLE_CANVAS"] == "1" else { return .disabled }
    let values =
      environment["VIVI_CANVAS_REMOTE_ORIGINS"]?
      .split(separator: ",")
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty } ?? []
    do {
      return NativeCanvasConfiguration(
        enabled: true,
        securityPolicy: try NativeCanvasSecurityPolicy(remoteOriginStrings: values),
        configurationFailure: nil)
    } catch {
      return NativeCanvasConfiguration(
        enabled: false,
        securityPolicy: NativeCanvasSecurityPolicy(remoteOrigins: []),
        configurationFailure: "Canvas rendering is disabled because its origin policy is invalid.")
    }
  }
}
