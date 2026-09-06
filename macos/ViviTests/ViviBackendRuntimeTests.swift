import XCTest

@testable import Vivi

final class ViviBackendRuntimeTests: XCTestCase {
  func testLoadsStatusFromZigBackend() throws {
    let backend = try ViviBackendRuntime.load()

    XCTAssertEqual(backend.abiVersion, 1)
    XCTAssertEqual(
      backend.statusMessage,
      "Copilot operations are not implemented in this scaffold."
    )
  }
}
