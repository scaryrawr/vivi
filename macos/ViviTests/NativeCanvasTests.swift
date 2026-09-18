import ViviBackend
import XCTest

@testable import Vivi

@MainActor
final class NativeCanvasTests: XCTestCase {
  func testInstanceIDGeneratorRejectsInvalidGeneratedIdentifier() {
    let generator = CanvasInstanceIDGenerator { "" }

    XCTAssertThrowsError(try generator.next())
  }

  func testCanvasJSONRequiresValidNonemptyJSON() {
    XCTAssertNoThrow(try CanvasActionInput(jsonUTF8: "false"))
    XCTAssertNoThrow(try CanvasActionInput(jsonUTF8: #"{"value":1}"#))
    XCTAssertThrowsError(try CanvasActionInput(jsonUTF8: ""))
    XCTAssertThrowsError(try CanvasActionInput(jsonUTF8: "{"))
  }

  func testDecoderAcceptsExactSnapshotAndPreservesOrthogonalState() throws {
    let fixture = try canvasSnapshotFixture()

    guard
      case .canvas(.snapshot(let snapshot)) = try NativeEventDecoder.decode(
        fixture.event,
        bytes: fixture.bytes,
        models: [],
        canvasDeclarations: fixture.declarations,
        canvasActions: fixture.actions,
        canvasInstances: fixture.instances)
    else {
      return XCTFail("Expected canvas snapshot")
    }

    XCTAssertEqual(snapshot.capability, .supported)
    XCTAssertEqual(snapshot.declarations.map(\.displayName), ["Preview"])
    XCTAssertEqual(snapshot.declarations[0].actions.map(\.name.rawValue), ["refresh"])
    XCTAssertEqual(
      String(data: snapshot.declarations[0].inputSchema!.data, encoding: .utf8),
      #"{"type":"object"}"#)
    XCTAssertEqual(snapshot.instances.count, 1)
    guard case .opened(let opened) = snapshot.instances[0].runtime else {
      return XCTFail("Expected opened runtime")
    }
    XCTAssertEqual(opened.generation.rawValue, 7)
    XCTAssertEqual(opened.title, "Title")
    guard case .recorded(let title, let input) = snapshot.instances[0].record else {
      return XCTFail("Expected recorded state")
    }
    XCTAssertEqual(title, "Recorded")
    XCTAssertEqual(String(data: input!.data, encoding: .utf8), #"{"saved":true}"#)
  }

  func testDecoderRejectsInvalidJSONWithoutPublishingPartialSnapshot() throws {
    var fixture = try canvasSnapshotFixture()
    fixture.bytes[0] = Character("!").asciiValue!

    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event,
        bytes: fixture.bytes,
        models: [],
        canvasDeclarations: fixture.declarations,
        canvasActions: fixture.actions,
        canvasInstances: fixture.instances))
  }

  func testDecoderRejectsActionRangeGapAndTrailingBytes() throws {
    var fixture = try canvasSnapshotFixture()
    fixture.declarations[0].action_offset = 1
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event,
        bytes: fixture.bytes,
        models: [],
        canvasDeclarations: fixture.declarations,
        canvasActions: fixture.actions,
        canvasInstances: fixture.instances))

    fixture = try canvasSnapshotFixture()
    fixture.bytes.append(0)
    fixture.event.byte_count += 1
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event,
        bytes: fixture.bytes,
        models: [],
        canvasDeclarations: fixture.declarations,
        canvasActions: fixture.actions,
        canvasInstances: fixture.instances))
  }

  func testDecoderRejectsCountMismatchOutOfOrderSpanAndInvalidUTF8() throws {
    var fixture = try canvasSnapshotFixture()
    fixture.event.canvas_snapshot.declaration_count = 2
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event,
        bytes: fixture.bytes,
        models: [],
        canvasDeclarations: fixture.declarations,
        canvasActions: fixture.actions,
        canvasInstances: fixture.instances))

    fixture = try canvasSnapshotFixture()
    fixture.declarations[0].extension_id.offset += 1
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event,
        bytes: fixture.bytes,
        models: [],
        canvasDeclarations: fixture.declarations,
        canvasActions: fixture.actions,
        canvasInstances: fixture.instances))

    fixture = try canvasSnapshotFixture()
    let extensionOffset = Int(fixture.declarations[0].extension_id.offset)
    fixture.bytes[extensionOffset] = 0xFF
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event,
        bytes: fixture.bytes,
        models: [],
        canvasDeclarations: fixture.declarations,
        canvasActions: fixture.actions,
        canvasInstances: fixture.instances))
  }

  func testDecoderRejectsDuplicateDeclarationAndActionNames() throws {
    var fixture = duplicateRegistryFixture(duplicateActions: false)
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event,
        bytes: fixture.bytes,
        models: [],
        canvasDeclarations: fixture.declarations,
        canvasActions: fixture.actions,
        canvasInstances: fixture.instances))

    fixture = duplicateRegistryFixture(duplicateActions: true)
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event,
        bytes: fixture.bytes,
        models: [],
        canvasDeclarations: fixture.declarations,
        canvasActions: fixture.actions,
        canvasInstances: fixture.instances))
  }

  func testDecoderRejectsDuplicateInstanceAndUnknownFlags() throws {
    var fixture = try canvasSnapshotFixture()
    var builder = CanvasByteFixtureBuilder(bytes: fixture.bytes)
    var duplicate = vivi_backend_canvas_instance_t()
    duplicate.key = vivi_backend_canvas_key_t(
      extension_id: builder.append("acme.preview"),
      canvas_id: builder.append("diff"),
      instance_id: builder.append("instance-1"))
    duplicate.runtime = VIVI_BACKEND_CANVAS_RUNTIME_CLOSED
    duplicate.record = VIVI_BACKEND_CANVAS_RECORD_REMOVED
    duplicate.degradation = VIVI_BACKEND_CANVAS_DEGRADATION_NONE
    fixture.bytes = builder.bytes
    fixture.instances.append(duplicate)
    fixture.event.byte_count = UInt32(fixture.bytes.count)
    fixture.event.canvas_snapshot.instance_count = 2
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event,
        bytes: fixture.bytes,
        models: [],
        canvasDeclarations: fixture.declarations,
        canvasActions: fixture.actions,
        canvasInstances: fixture.instances))

    fixture = try canvasSnapshotFixture()
    fixture.instances[0].flags |= 1 << 31
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event,
        bytes: fixture.bytes,
        models: [],
        canvasDeclarations: fixture.declarations,
        canvasActions: fixture.actions,
        canvasInstances: fixture.instances))
  }

  func testDecoderRejectsOpenedInstanceWithoutGenerationAndRemovedRecordMetadata() throws {
    var fixture = try canvasSnapshotFixture()
    fixture.instances[0].flags &=
      ~UInt32(VIVI_BACKEND_CANVAS_INSTANCE_RENDERER_GENERATION_PRESENT.rawValue)
    fixture.instances[0].renderer_generation = 0
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event,
        bytes: fixture.bytes,
        models: [],
        canvasDeclarations: fixture.declarations,
        canvasActions: fixture.actions,
        canvasInstances: fixture.instances))

    fixture = try canvasSnapshotFixture()
    fixture.instances[0].record = VIVI_BACKEND_CANVAS_RECORD_REMOVED
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event,
        bytes: fixture.bytes,
        models: [],
        canvasDeclarations: fixture.declarations,
        canvasActions: fixture.actions,
        canvasInstances: fixture.instances))
  }

  func testDecoderRejectsNonneutralMetadataAndReservedFields() throws {
    var fixture = try canvasSnapshotFixture()
    fixture.event.default_saved = 1
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event,
        bytes: fixture.bytes,
        models: [],
        canvasDeclarations: fixture.declarations,
        canvasActions: fixture.actions,
        canvasInstances: fixture.instances))

    fixture = try canvasSnapshotFixture()
    fixture.declarations[0].reserved = 1
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(
        fixture.event,
        bytes: fixture.bytes,
        models: [],
        canvasDeclarations: fixture.declarations,
        canvasActions: fixture.actions,
        canvasInstances: fixture.instances))
  }

  func testDecoderPreservesOperationIDAndRequiresExactCompletionShape() throws {
    let fixture = actionCompletionFixture()
    guard
      case .canvas(.completion(.actionSucceeded(let id, let result))) =
        try NativeEventDecoder.decode(fixture.event, bytes: fixture.bytes, models: [])
    else {
      return XCTFail("Expected action completion")
    }
    XCTAssertEqual(id.rawValue, 41)
    XCTAssertEqual(String(data: result.data, encoding: .utf8), #"{"ok":true}"#)

    var malformed = fixture
    malformed.event.canvas_completion.outcome = VIVI_BACKEND_CANVAS_OPERATION_FAILED
    malformed.event.canvas_completion.failure = VIVI_BACKEND_CANVAS_FAILURE_STALE
    XCTAssertThrowsError(
      try NativeEventDecoder.decode(malformed.event, bytes: malformed.bytes, models: []))
  }

  func testCommandEncoderProducesTypedContiguousOpenOperation() throws {
    let key = try canvasKey()
    let input = try CanvasOpenInput(jsonUTF8: #"{"path":"a"}"#)

    let encoded = try NativeCanvasCommandEncoder.encode(.open(key: key, input: input))

    XCTAssertEqual(encoded.operation.abi_version, UInt32(VIVI_BACKEND_ABI_VERSION))
    XCTAssertEqual(
      encoded.operation.struct_size,
      UInt32(MemoryLayout<vivi_backend_canvas_operation_t>.size))
    XCTAssertEqual(encoded.operation.kind, VIVI_BACKEND_CANVAS_OPERATION_OPEN)
    XCTAssertEqual(text(encoded.operation.key.extension_id, in: encoded.bytes), "acme.preview")
    XCTAssertEqual(text(encoded.operation.key.canvas_id, in: encoded.bytes), "diff")
    XCTAssertEqual(text(encoded.operation.key.instance_id, in: encoded.bytes), "instance-1")
    XCTAssertEqual(text(encoded.operation.open_input_json, in: encoded.bytes), #"{"path":"a"}"#)
    XCTAssertEqual(encoded.operation.action_name.length, 0)
    XCTAssertEqual(encoded.operation.action_input_json.length, 0)
    XCTAssertEqual(encoded.operation.expected_renderer_generation, 0)
  }

  func testCommandEncoderCarriesGenerationAndUsesActionJSONRole() throws {
    let key = try canvasKey()
    let input = try CanvasActionInput(jsonUTF8: "false")
    let generation = CanvasRendererGeneration(22)!

    let encoded = try NativeCanvasCommandEncoder.encode(
      .action(
        key: key,
        generation: generation,
        name: CanvasActionName("refresh"),
        input: input))

    XCTAssertEqual(encoded.operation.kind, VIVI_BACKEND_CANVAS_OPERATION_INVOKE_ACTION)
    XCTAssertEqual(encoded.operation.expected_renderer_generation, 22)
    XCTAssertEqual(text(encoded.operation.action_name, in: encoded.bytes), "refresh")
    XCTAssertEqual(text(encoded.operation.action_input_json, in: encoded.bytes), "false")
    XCTAssertEqual(encoded.operation.open_input_json.length, 0)
  }

  func testCommandEncoderRequiresGenerationForClose() throws {
    let key = try canvasKey()
    let generation = CanvasRendererGeneration(17)!

    let encoded = try NativeCanvasCommandEncoder.encode(
      .close(key: key, generation: generation))

    XCTAssertEqual(encoded.operation.kind, VIVI_BACKEND_CANVAS_OPERATION_CLOSE)
    XCTAssertEqual(encoded.operation.expected_renderer_generation, 17)
    XCTAssertEqual(encoded.operation.action_name.length, 0)
    XCTAssertEqual(encoded.operation.open_input_json.length, 0)
    XCTAssertEqual(encoded.operation.action_input_json.length, 0)
  }

  func testStoreRetainsDeclarationForLiveInstanceAfterRegistryDisappears() throws {
    let driver = FakeCanvasDriver()
    let store = NativeCanvasStore(driver: driver)
    let declaration = try canvasDeclaration()
    let key = try canvasKey()
    store.apply(.snapshot(canvasSnapshot(declarations: [declaration], key: key, generation: 1)))

    store.apply(.snapshot(canvasSnapshot(declarations: [], key: key, generation: 1)))

    XCTAssertEqual(store.presentation.declarations, [])
    XCTAssertEqual(store.presentation.instances[0].declaration, declaration)
    let action = try CanvasActionName("refresh")
    let lease = CanvasRenderLease(
      key: key,
      generation: CanvasRendererGeneration(1)!,
      epoch: CanvasRendererEpoch(1)!)
    XCTAssertEqual(store.invoke(action, on: lease, input: nil), .rejected(.actionUnavailable))
  }

  func testStoreBindsActionsToGenerationAndTearsDownReplacedGeneration() throws {
    let driver = FakeCanvasDriver()
    var directives: [CanvasHostDirective] = []
    let store = NativeCanvasStore(
      driver: driver,
      emitHostDirective: { directives.append($0) })
    let declaration = try canvasDeclaration()
    let key = try canvasKey()
    let generation1 = CanvasRendererGeneration(1)!
    let generation2 = CanvasRendererGeneration(2)!
    store.apply(.snapshot(canvasSnapshot(declarations: [declaration], key: key, generation: 1)))
    store.apply(.snapshot(canvasSnapshot(declarations: [declaration], key: key, generation: 2)))

    XCTAssertEqual(
      directives,
      [
        .teardown(
          CanvasRenderLease(
            key: key,
            generation: generation1,
            epoch: CanvasRendererEpoch(1)!),
          reason: .generationReplaced)
      ])
    XCTAssertEqual(
      store.invoke(
        try CanvasActionName("refresh"),
        on: CanvasRenderLease(
          key: key,
          generation: generation1,
          epoch: CanvasRendererEpoch(1)!),
        input: nil),
      .rejected(.staleGeneration))

    driver.results = [.accepted(CanvasOperationID(9)!)]
    XCTAssertEqual(
      store.invoke(
        try CanvasActionName("refresh"),
        on: CanvasRenderLease(
          key: key,
          generation: generation2,
          epoch: CanvasRendererEpoch(2)!),
        input: nil),
      .submitted(CanvasOperationID(9)!))
    guard case .action(_, let generation, _, _) = driver.commands.last else {
      return XCTFail("Expected action command")
    }
    XCTAssertEqual(generation, generation2)
  }

  func testRendererEpochNeverRepeatsAcrossSuccessfulResume() throws {
    let store = NativeCanvasStore(driver: FakeCanvasDriver())
    let declaration = try canvasDeclaration()
    let key = try canvasKey()
    store.apply(.snapshot(canvasSnapshot(declarations: [declaration], key: key, generation: 1)))
    let oldLease = try XCTUnwrap(store.renderLease(for: key))

    store.resetForSuccessfulResume()
    store.apply(.snapshot(canvasSnapshot(declarations: [declaration], key: key, generation: 1)))
    let replacementLease = try XCTUnwrap(store.renderLease(for: key))

    XCTAssertEqual(oldLease.key, replacementLease.key)
    XCTAssertEqual(oldLease.generation, replacementLease.generation)
    XCTAssertNotEqual(oldLease.epoch, replacementLease.epoch)
    XCTAssertFalse(store.acceptsRendererCallback(for: oldLease))
    XCTAssertTrue(store.acceptsRendererCallback(for: replacementLease))
  }

  func testPresentationCloseRevokesRendererAndReopenUsesFreshEpoch() throws {
    let configuration = NativeCanvasConfiguration(
      enabled: true,
      securityPolicy: try NativeCanvasSecurityPolicy(),
      configurationFailure: nil)
    let store = NativeChatStore(
      workspace: "/work/project",
      driver: CanvasConversationDriver(),
      canvasConfiguration: configuration)
    let key = try canvasKey()
    store.canvases.apply(
      .snapshot(
        canvasSnapshot(
          declarations: [try canvasDeclaration()],
          key: key,
          generation: 1,
          url: "http://localhost:4317/canvas")))
    store.canvasRenderers.reconcile(store.canvases.presentation, canvases: store.canvases)
    let oldLease = try XCTUnwrap(store.canvases.renderLease(for: key))
    let oldRenderer = try XCTUnwrap(store.canvasRenderers.renderers.first)

    store.suspendCanvasPresentation()

    XCTAssertTrue(store.canvasRenderers.renderers.isEmpty)
    XCTAssertEqual(oldRenderer.state, .tornDown)

    store.resumeCanvasPresentation()
    let replacementLease = try XCTUnwrap(store.canvases.renderLease(for: key))

    XCTAssertNotEqual(oldLease.epoch, replacementLease.epoch)
    XCTAssertFalse(store.canvases.acceptsRendererCallback(for: oldLease))
    XCTAssertEqual(store.canvasRenderers.renderers.map(\.lease), [replacementLease])
  }

  func testGenerationReplacementRevokesOldWebRendererBeforePublishingNewOne() throws {
    let configuration = NativeCanvasConfiguration(
      enabled: true,
      securityPolicy: try NativeCanvasSecurityPolicy(),
      configurationFailure: nil)
    let store = NativeChatStore(
      workspace: "/work/project",
      driver: CanvasConversationDriver(),
      canvasConfiguration: configuration)
    let key = try canvasKey()
    let declaration = try canvasDeclaration()
    store.reduce(
      .canvas(
        .snapshot(
          canvasSnapshot(
            declarations: [declaration],
            key: key,
            generation: 1,
            url: "http://127.0.0.1:4317/canvas"))))
    let oldRenderer = try XCTUnwrap(store.canvasRenderers.renderers.first)
    let oldLease = oldRenderer.lease

    store.reduce(
      .canvas(
        .snapshot(
          canvasSnapshot(
            declarations: [declaration],
            key: key,
            generation: 2,
            url: "http://127.0.0.1:4317/canvas"))))
    let replacement = try XCTUnwrap(store.canvasRenderers.renderers.first)

    XCTAssertEqual(oldRenderer.state, .tornDown)
    XCTAssertFalse(store.canvases.acceptsRendererCallback(for: oldLease))
    XCTAssertNotEqual(oldLease.epoch, replacement.lease.epoch)
    XCTAssertEqual(replacement.lease.generation, CanvasRendererGeneration(2)!)
  }

  func testCloseCarriesCurrentRendererGeneration() throws {
    let driver = FakeCanvasDriver()
    driver.results = [.accepted(CanvasOperationID(10)!)]
    var directives: [CanvasHostDirective] = []
    let store = NativeCanvasStore(
      driver: driver,
      emitHostDirective: { directives.append($0) })
    let declaration = try canvasDeclaration()
    let key = try canvasKey()
    store.apply(.snapshot(canvasSnapshot(declarations: [declaration], key: key, generation: 7)))
    let lease = try XCTUnwrap(store.renderLease(for: key))

    XCTAssertEqual(store.close(lease), .submitted(CanvasOperationID(10)!))
    guard case .close(let closedKey, let generation) = driver.commands.last else {
      return XCTFail("Expected close command")
    }
    XCTAssertEqual(closedKey, key)
    XCTAssertEqual(generation, CanvasRendererGeneration(7)!)
    XCTAssertEqual(directives, [.teardown(lease, reason: .runtimeEnded)])
    XCTAssertFalse(store.acceptsRendererCallback(for: lease))

    store.apply(.snapshot(canvasSnapshot(declarations: [declaration], key: key, generation: 7)))
    XCTAssertNil(store.renderLease(for: key))
  }

  func testOpenAndOpenSameKeyUseValidatedInjectedIDAndPreserveOperationIDs() throws {
    let driver = FakeCanvasDriver()
    driver.results = [
      .accepted(CanvasOperationID(11)!),
      .accepted(CanvasOperationID(12)!),
    ]
    let store = NativeCanvasStore(
      driver: driver,
      instanceIDs: CanvasInstanceIDGenerator { "fixed-instance" })
    let declaration = try canvasDeclaration()
    store.apply(.snapshot(canvasSnapshot(declarations: [declaration])))

    let first = store.open(declaration.id, input: nil)
    guard case .submitted(let key, let firstID) = first else {
      return XCTFail("Expected open submission")
    }

    XCTAssertEqual(firstID.rawValue, 11)
    XCTAssertEqual(key.instanceID.encodedValue, "fixed-instance")
    XCTAssertEqual(store.openSameKey(key, input: nil), .submitted(CanvasOperationID(12)!))
    XCTAssertEqual(driver.openKinds, [.newKey, .sameKey])
  }

  func testGeneratedOpenCannotSilentlyBecomeOpenSameKey() throws {
    let driver = FakeCanvasDriver()
    let store = NativeCanvasStore(
      driver: driver,
      instanceIDs: CanvasInstanceIDGenerator { "instance-1" })
    let declaration = try canvasDeclaration()
    store.apply(
      .snapshot(
        canvasSnapshot(
          declarations: [declaration],
          key: try canvasKey(),
          generation: 1)))

    XCTAssertEqual(store.open(declaration.id, input: nil), .rejected(.instanceIDCollision))
    XCTAssertTrue(driver.commands.isEmpty)
  }

  func testGeneratedOpenReservesInstanceIDAcrossPendingDeclarations() throws {
    let driver = FakeCanvasDriver()
    driver.results = [.accepted(CanvasOperationID(13)!)]
    let store = NativeCanvasStore(
      driver: driver,
      instanceIDs: CanvasInstanceIDGenerator { "shared-instance" })
    let first = try canvasDeclaration()
    let second = CanvasDeclaration(
      id: try CanvasDeclarationID(extensionID: "other.extension", canvasID: "other-canvas"),
      extensionName: "Other",
      displayName: "Other Canvas",
      description: "Other",
      inputSchema: nil,
      actions: [])
    store.apply(.snapshot(canvasSnapshot(declarations: [first, second])))

    guard case .submitted = store.open(first.id, input: nil) else {
      return XCTFail("Expected first open submission")
    }

    XCTAssertEqual(store.open(second.id, input: nil), .rejected(.instanceIDCollision))
    let collidingKey = try CanvasInstanceKey(
      declarationID: second.id,
      instanceID: CanvasInstanceID(validating: "shared-instance"))
    XCTAssertEqual(
      store.openSameKey(collidingKey, input: nil),
      .rejected(.instanceIDCollision))
    XCTAssertEqual(driver.commands.count, 1)
  }

  func testActionRejectsStaleNativeEpochWithSameBackendGeneration() throws {
    let driver = FakeCanvasDriver()
    driver.results = [.accepted(CanvasOperationID(14)!)]
    let store = NativeCanvasStore(driver: driver)
    let declaration = try canvasDeclaration()
    let key = try canvasKey()
    store.apply(.snapshot(canvasSnapshot(declarations: [declaration], key: key, generation: 3)))
    let oldLease = try XCTUnwrap(store.renderLease(for: key))
    store.renewRendererLeasesForPresentation()

    XCTAssertEqual(
      store.invoke(try CanvasActionName("refresh"), on: oldLease, input: nil),
      .rejected(.staleGeneration))
    XCTAssertTrue(driver.commands.isEmpty)
  }

  func testCompletionCorrelatesOperationAndRetainsGenerationBoundCommand() throws {
    let driver = FakeCanvasDriver()
    driver.results = [.accepted(CanvasOperationID(19)!)]
    let store = NativeCanvasStore(driver: driver)
    let declaration = try canvasDeclaration()
    let key = try canvasKey()
    let generation = CanvasRendererGeneration(3)!
    store.apply(.snapshot(canvasSnapshot(declarations: [declaration], key: key, generation: 3)))
    _ = store.invoke(
      try CanvasActionName("refresh"),
      on: CanvasRenderLease(
        key: key,
        generation: generation,
        epoch: CanvasRendererEpoch(1)!),
      input: nil)

    store.apply(
      .completion(
        .actionFailed(id: CanvasOperationID(19)!, failure: .stale)))

    XCTAssertEqual(store.presentation.completions.count, 1)
    guard
      case .action(_, let recordedGeneration, _, _) =
        store.presentation.completions[0].command
    else {
      return XCTFail("Expected correlated action")
    }
    XCTAssertEqual(recordedGeneration, generation)
  }

  func testCloseEmitsTeardownBeforeDriverClose() throws {
    var sequence: [String] = []
    let driver = CanvasConversationDriver { sequence.append("driver-close") }
    let store = NativeChatStore(
      workspace: "/work/project",
      driver: driver,
      canvasHostDirective: { directive in
        if directive == .teardownAll(reason: .conversationClosing) {
          sequence.append("canvas-teardown")
        }
      })
    store.canvases.apply(
      .snapshot(
        canvasSnapshot(
          declarations: [try canvasDeclaration()],
          key: try canvasKey(),
          generation: 1)))

    store.close()

    XCTAssertEqual(sequence, ["canvas-teardown", "driver-close"])
  }

  func testSuccessfulResumeExplicitlyTearsDownAndResetsCanvasState() throws {
    var directives: [CanvasHostDirective] = []
    let driver = CanvasConversationDriver()
    let store = NativeChatStore(
      workspace: "/work/current",
      driver: driver,
      canvasHostDirective: { directives.append($0) })
    let declaration = try canvasDeclaration()
    store.canvases.apply(
      .snapshot(canvasSnapshot(declarations: [declaration], key: try canvasKey(), generation: 1)))
    store.reduce(.ready)
    store.reduce(.modelCatalog(canvasModelCatalog()))
    store.refreshSessions(.local)
    let resumeKey = ResumeKey(generation: 4, slot: 2, scope: .local)
    store.reduce(
      .sessionCatalog(
        SessionCatalog(
          scope: .local,
          sessions: [
            SessionSummary(
              key: resumeKey,
              workingDirectory: "/work/resumed",
              modelID: "copilot/test",
              title: "Resumed",
              summary: nil,
              lastUsedUnixMilliseconds: 1,
              reasoning: .off,
              isCurrent: false)
          ],
          skippedInvalidShards: false)))
    store.resumeSession(resumeKey)

    store.reduce(
      .sessionResume(
        .resumed(
          ResumedSession(
            summary: SessionSummary(
              key: resumeKey,
              workingDirectory: "/work/resumed",
              modelID: "copilot/test",
              title: "Resumed",
              summary: nil,
              lastUsedUnixMilliseconds: 1,
              reasoning: .off,
              isCurrent: false),
            transcript: [],
            cleanupFailed: false))))

    XCTAssertEqual(directives.last, .teardownAll(reason: .sessionResumed))
    XCTAssertEqual(store.canvases.presentation, .empty)
    XCTAssertEqual(store.workspace, "/work/resumed")
  }

  func testUnknownCompletionFailsCanvasClosedWithoutClosingChat() {
    var directives: [CanvasHostDirective] = []
    let store = NativeCanvasStore(
      driver: FakeCanvasDriver(),
      emitHostDirective: { directives.append($0) })

    store.apply(.completion(.closeSucceeded(id: CanvasOperationID(99)!)))

    XCTAssertEqual(directives, [.teardownAll(reason: .protocolFailure)])
  }

  func testTerminalCanvasStateCannotBeRevivedByLaterSnapshots() throws {
    let declaration = try canvasDeclaration()
    let key = try canvasKey()
    let generation = CanvasRendererGeneration(1)!
    let opened = canvasSnapshot(declarations: [declaration], key: key, generation: 1)

    let protocolFailed = NativeCanvasStore(driver: FakeCanvasDriver())
    protocolFailed.apply(.completion(.closeSucceeded(id: CanvasOperationID(99)!)))
    protocolFailed.apply(.snapshot(opened))
    XCTAssertFalse(
      protocolFailed.acceptsRendererCallback(
        for: CanvasRenderLease(
          key: key,
          generation: generation,
          epoch: CanvasRendererEpoch(1)!)))

    let shutdown = NativeCanvasStore(driver: FakeCanvasDriver())
    shutdown.apply(
      .snapshot(
        CanvasSnapshot(
          capability: .supported,
          registryDegradation: nil,
          operationDegradation: nil,
          shutdownRequested: true,
          declarations: [],
          instances: [])))
    shutdown.apply(.snapshot(opened))
    XCTAssertFalse(
      shutdown.acceptsRendererCallback(
        for: CanvasRenderLease(
          key: key,
          generation: generation,
          epoch: CanvasRendererEpoch(1)!)))
  }
}

private func duplicateRegistryFixture(
  duplicateActions: Bool
) -> CanvasSnapshotFixture {
  var builder = CanvasByteFixtureBuilder()
  var declarations: [vivi_backend_canvas_declaration_t] = []
  var actions: [vivi_backend_canvas_action_t] = []

  func declaration(
    _ builder: inout CanvasByteFixtureBuilder,
    actionCount: UInt32
  ) -> vivi_backend_canvas_declaration_t {
    var value = vivi_backend_canvas_declaration_t()
    value.extension_id = builder.append("acme.preview")
    value.extension_name = builder.append("Acme")
    value.canvas_id = builder.append("diff")
    value.display_name = builder.append("Preview")
    value.description = builder.append("Shows a diff")
    value.action_offset = UInt32(actions.count)
    value.action_count = actionCount
    return value
  }

  func action(
    _ builder: inout CanvasByteFixtureBuilder
  ) -> vivi_backend_canvas_action_t {
    var value = vivi_backend_canvas_action_t()
    value.name = builder.append("refresh")
    value.description = builder.append("Refresh")
    return value
  }

  if duplicateActions {
    declarations.append(declaration(&builder, actionCount: 2))
    actions.append(action(&builder))
    actions.append(action(&builder))
  } else {
    declarations.append(declaration(&builder, actionCount: 0))
    declarations.append(declaration(&builder, actionCount: 0))
  }

  var event = vivi_backend_event_t()
  event.kind = VIVI_BACKEND_EVENT_CANVAS_SNAPSHOT
  event.content_kind = VIVI_BACKEND_CONTENT_CANVAS_SNAPSHOT
  event.byte_count = UInt32(builder.bytes.count)
  event.selected_reasoning = VIVI_BACKEND_REASONING_NONE
  event.canvas_snapshot.capability = VIVI_BACKEND_CANVAS_CAPABILITY_SUPPORTED
  event.canvas_snapshot.declaration_count = UInt32(declarations.count)
  event.canvas_snapshot.action_count = UInt32(actions.count)
  return CanvasSnapshotFixture(
    event: event,
    bytes: builder.bytes,
    declarations: declarations,
    actions: actions,
    instances: [])
}

private struct CanvasSnapshotFixture {
  var event: vivi_backend_event_t
  var bytes: [UInt8]
  var declarations: [vivi_backend_canvas_declaration_t]
  var actions: [vivi_backend_canvas_action_t]
  var instances: [vivi_backend_canvas_instance_t]
}

private struct CanvasByteFixtureBuilder {
  var bytes: [UInt8] = []

  mutating func append(_ value: String) -> vivi_backend_span_t {
    let encoded = Array(value.utf8)
    let span = vivi_backend_span_t(offset: UInt32(bytes.count), length: UInt32(encoded.count))
    bytes.append(contentsOf: encoded)
    return span
  }
}

private func canvasSnapshotFixture() throws -> CanvasSnapshotFixture {
  var builder = CanvasByteFixtureBuilder()
  let declarationSchema = builder.append(#"{"type":"object"}"#)
  let declarationExtensionID = builder.append("acme.preview")
  let declarationExtensionName = builder.append("Acme")
  let declarationCanvasID = builder.append("diff")
  let declarationDisplayName = builder.append("Preview")
  let declarationDescription = builder.append("Shows a diff")
  let actionSchema = builder.append(#"{"type":"boolean"}"#)
  let actionName = builder.append("refresh")
  let actionDescription = builder.append("Refresh the preview")
  let openInput = builder.append(#"{"path":"a"}"#)
  let title = builder.append("Title")
  let url = builder.append("")
  let status = builder.append("ready")
  let recordedTitle = builder.append("Recorded")
  let recordedInput = builder.append(#"{"saved":true}"#)
  let instanceExtensionID = builder.append("acme.preview")
  let instanceCanvasID = builder.append("diff")
  let instanceID = builder.append("instance-1")

  var declaration = vivi_backend_canvas_declaration_t()
  declaration.extension_id = declarationExtensionID
  declaration.extension_name = declarationExtensionName
  declaration.canvas_id = declarationCanvasID
  declaration.display_name = declarationDisplayName
  declaration.description = declarationDescription
  declaration.input_schema_json = declarationSchema
  declaration.action_count = 1
  declaration.flags = UInt32(VIVI_BACKEND_CANVAS_DECLARATION_INPUT_SCHEMA_PRESENT.rawValue)

  var action = vivi_backend_canvas_action_t()
  action.name = actionName
  action.description = actionDescription
  action.input_schema_json = actionSchema
  action.flags = UInt32(VIVI_BACKEND_CANVAS_ACTION_INPUT_SCHEMA_PRESENT.rawValue)

  var instance = vivi_backend_canvas_instance_t()
  instance.key = vivi_backend_canvas_key_t(
    extension_id: instanceExtensionID,
    canvas_id: instanceCanvasID,
    instance_id: instanceID)
  instance.open_input_json = openInput
  instance.title = title
  instance.url = url
  instance.status = status
  instance.recorded_title = recordedTitle
  instance.recorded_input_json = recordedInput
  instance.renderer_generation = 7
  instance.runtime = VIVI_BACKEND_CANVAS_RUNTIME_OPENED
  instance.record = VIVI_BACKEND_CANVAS_RECORD_RECORDED
  instance.degradation = VIVI_BACKEND_CANVAS_DEGRADATION_NONE
  instance.flags =
    UInt32(VIVI_BACKEND_CANVAS_INSTANCE_OPEN_INPUT_PRESENT.rawValue)
    | UInt32(VIVI_BACKEND_CANVAS_INSTANCE_RENDERER_GENERATION_PRESENT.rawValue)
    | UInt32(VIVI_BACKEND_CANVAS_INSTANCE_TITLE_PRESENT.rawValue)
    | UInt32(VIVI_BACKEND_CANVAS_INSTANCE_URL_PRESENT.rawValue)
    | UInt32(VIVI_BACKEND_CANVAS_INSTANCE_STATUS_PRESENT.rawValue)
    | UInt32(VIVI_BACKEND_CANVAS_INSTANCE_RECORDED_TITLE_PRESENT.rawValue)
    | UInt32(VIVI_BACKEND_CANVAS_INSTANCE_RECORDED_INPUT_PRESENT.rawValue)

  var event = vivi_backend_event_t()
  event.kind = VIVI_BACKEND_EVENT_CANVAS_SNAPSHOT
  event.content_kind = VIVI_BACKEND_CONTENT_CANVAS_SNAPSHOT
  event.byte_count = UInt32(builder.bytes.count)
  event.selected_reasoning = VIVI_BACKEND_REASONING_NONE
  event.canvas_snapshot.capability = VIVI_BACKEND_CANVAS_CAPABILITY_SUPPORTED
  event.canvas_snapshot.declaration_count = 1
  event.canvas_snapshot.action_count = 1
  event.canvas_snapshot.instance_count = 1
  return CanvasSnapshotFixture(
    event: event,
    bytes: builder.bytes,
    declarations: [declaration],
    actions: [action],
    instances: [instance])
}

private func actionCompletionFixture() -> (
  event: vivi_backend_event_t,
  bytes: [UInt8]
) {
  let bytes = Array(#"{"ok":true}"#.utf8)
  var event = vivi_backend_event_t()
  event.kind = VIVI_BACKEND_EVENT_CANVAS_OPERATION
  event.content_kind = VIVI_BACKEND_CONTENT_CANVAS_OPERATION
  event.byte_count = UInt32(bytes.count)
  event.selected_reasoning = VIVI_BACKEND_REASONING_NONE
  event.canvas_completion.operation_id = 41
  event.canvas_completion.kind = VIVI_BACKEND_CANVAS_OPERATION_INVOKE_ACTION
  event.canvas_completion.outcome = VIVI_BACKEND_CANVAS_OPERATION_SUCCEEDED
  event.canvas_completion.failure = VIVI_BACKEND_CANVAS_FAILURE_NONE
  event.canvas_completion.flags =
    UInt32(VIVI_BACKEND_CANVAS_COMPLETION_ACTION_RESULT_PRESENT.rawValue)
  event.canvas_completion.action_result_json = vivi_backend_span_t(
    offset: 0, length: UInt32(bytes.count))
  return (event, bytes)
}

private func canvasDeclaration() throws -> CanvasDeclaration {
  CanvasDeclaration(
    id: try CanvasDeclarationID(extensionID: "acme.preview", canvasID: "diff"),
    extensionName: "Acme",
    displayName: "Preview",
    description: "Shows a diff",
    inputSchema: nil,
    actions: [
      CanvasActionDeclaration(
        name: try CanvasActionName("refresh"),
        description: "Refresh",
        inputSchema: nil)
    ])
}

private func canvasKey() throws -> CanvasInstanceKey {
  try CanvasInstanceKey(
    declarationID: CanvasDeclarationID(extensionID: "acme.preview", canvasID: "diff"),
    instanceID: CanvasInstanceID(validating: "instance-1"))
}

private func canvasSnapshot(
  declarations: [CanvasDeclaration],
  key: CanvasInstanceKey? = nil,
  generation: UInt64 = 1,
  url: String? = nil
) -> CanvasSnapshot {
  CanvasSnapshot(
    capability: .supported,
    registryDegradation: nil,
    operationDegradation: nil,
    shutdownRequested: false,
    declarations: declarations,
    instances: key.map {
      [
        CanvasInstanceSnapshot(
          key: $0,
          openInput: nil,
          runtime: .opened(
            CanvasOpenedRuntime(
              generation: CanvasRendererGeneration(generation)!,
              title: "Preview",
              url: url,
              status: nil)),
          record: .removed,
          degradation: nil)
      ]
    } ?? [])
}

private enum FakeOpenKind: Equatable {
  case newKey
  case sameKey
}

private final class FakeCanvasDriver: CanvasCommandDriving {
  var results: [CanvasCommandTransportResult] = []
  var commands: [CanvasCommand] = []
  var openKinds: [FakeOpenKind] = []

  func openCanvas(
    key: CanvasInstanceKey,
    input: CanvasOpenInput?
  ) -> CanvasCommandTransportResult {
    openKinds.append(.newKey)
    commands.append(.open(key: key, input: input))
    return nextResult()
  }

  func openCanvasSameKey(
    key: CanvasInstanceKey,
    input: CanvasOpenInput?
  ) -> CanvasCommandTransportResult {
    openKinds.append(.sameKey)
    commands.append(.open(key: key, input: input))
    return nextResult()
  }

  func closeCanvas(lease: CanvasRenderLease) -> CanvasCommandTransportResult {
    commands.append(.close(key: lease.key, generation: lease.generation))
    return nextResult()
  }

  func invokeCanvasAction(
    name: CanvasActionName,
    on lease: CanvasRenderLease,
    input: CanvasActionInput?
  ) -> CanvasCommandTransportResult {
    commands.append(
      .action(
        key: lease.key,
        generation: lease.generation,
        name: name,
        input: input))
    return nextResult()
  }

  private func nextResult() -> CanvasCommandTransportResult {
    results.isEmpty ? .failed : results.removeFirst()
  }
}

private final class CanvasConversationDriver: ViviConversationDriving {
  private let onClose: () -> Void

  init(onClose: @escaping () -> Void = {}) {
    self.onClose = onClose
  }

  func start(
    receive: @escaping @MainActor (ChatEvent) -> Void
  ) -> ConversationOperationResult {
    .accepted
  }

  func submit(_ prompt: String) -> ConversationOperationResult { .accepted }
  func refreshModels() -> ConversationOperationResult { .accepted }
  func switchModel(_ selection: ModelSelection) -> ConversationOperationResult { .accepted }
  func refreshSessions(_ request: SessionCatalogRequest) -> ConversationOperationResult {
    .accepted
  }
  func resumeSession(_ key: ResumeKey) -> ConversationOperationResult { .accepted }

  func close(completion: @escaping @MainActor () -> Void) {
    onClose()
    Task { @MainActor in completion() }
  }
}

private func canvasModelCatalog() -> ModelCatalog {
  ModelCatalog(
    selected: ModelSelection(modelID: "copilot/test", reasoning: .off),
    models: [
      ModelInfo(
        id: "copilot/test",
        displayName: "Test",
        maxContextWindowTokens: 1,
        maxOutputTokens: 1,
        supportsVision: false,
        reasoning: [.off],
        advertisedDefaultReasoning: .off)
    ])
}

private func text(_ span: vivi_backend_span_t, in bytes: [UInt8]) -> String {
  let start = Int(span.offset)
  let end = start + Int(span.length)
  return String(decoding: bytes[start..<end], as: UTF8.self)
}
