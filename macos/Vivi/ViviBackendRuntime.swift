import ViviBackend

struct ViviBackendRuntime: Sendable {
  enum Error: Swift.Error {
    case unavailable
    case unknownLifecycle(UInt32)
  }

  let abiVersion: UInt32
  let statusMessage: String

  init() {
    do {
      self = try Self.load()
    } catch {
      abiVersion = 0
      statusMessage = "Backend unavailable."
    }
  }

  static func load() throws -> Self {
    var status = vivi_backend_status_t()
    guard vivi_backend_status(&status) == VIVI_BACKEND_OK else {
      throw Error.unavailable
    }
    guard status.lifecycle == VIVI_BACKEND_LIFECYCLE_SCAFFOLD else {
      throw Error.unknownLifecycle(status.lifecycle)
    }
    return Self(
      abiVersion: status.abi_version,
      statusMessage: "Copilot operations are not implemented in this scaffold."
    )
  }

  private init(abiVersion: UInt32, statusMessage: String) {
    self.abiVersion = abiVersion
    self.statusMessage = statusMessage
  }
}
