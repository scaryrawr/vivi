import Foundation
import ViviBackend

private let canvasKnownDeclarationFlags =
  UInt32(VIVI_BACKEND_CANVAS_DECLARATION_INPUT_SCHEMA_PRESENT.rawValue)
private let canvasKnownActionFlags =
  UInt32(VIVI_BACKEND_CANVAS_ACTION_INPUT_SCHEMA_PRESENT.rawValue)
private let canvasKnownInstanceFlags =
  UInt32(VIVI_BACKEND_CANVAS_INSTANCE_OPEN_INPUT_PRESENT.rawValue)
  | UInt32(VIVI_BACKEND_CANVAS_INSTANCE_RENDERER_GENERATION_PRESENT.rawValue)
  | UInt32(VIVI_BACKEND_CANVAS_INSTANCE_TITLE_PRESENT.rawValue)
  | UInt32(VIVI_BACKEND_CANVAS_INSTANCE_URL_PRESENT.rawValue)
  | UInt32(VIVI_BACKEND_CANVAS_INSTANCE_STATUS_PRESENT.rawValue)
  | UInt32(VIVI_BACKEND_CANVAS_INSTANCE_RECORDED_TITLE_PRESENT.rawValue)
  | UInt32(VIVI_BACKEND_CANVAS_INSTANCE_RECORDED_INPUT_PRESENT.rawValue)
private let canvasKnownSnapshotFlags =
  UInt32(VIVI_BACKEND_CANVAS_SNAPSHOT_SHUTDOWN_REQUESTED.rawValue)
private let canvasKnownCompletionFlags =
  UInt32(VIVI_BACKEND_CANVAS_COMPLETION_TITLE_PRESENT.rawValue)
  | UInt32(VIVI_BACKEND_CANVAS_COMPLETION_URL_PRESENT.rawValue)
  | UInt32(VIVI_BACKEND_CANVAS_COMPLETION_STATUS_PRESENT.rawValue)
  | UInt32(VIVI_BACKEND_CANVAS_COMPLETION_ACTION_RESULT_PRESENT.rawValue)

private struct CanvasByteDecoder {
  let bytes: [UInt8]
  private(set) var offset = 0

  mutating func identifier(_ span: vivi_backend_span_t) throws -> String {
    let value = try text(span, maximumBytes: 256)
    guard !value.isEmpty else { throw NativeEventDecodingError.malformed }
    return value
  }

  mutating func requiredText(_ span: vivi_backend_span_t) throws -> String {
    try text(span, maximumBytes: 4_096)
  }

  mutating func optionalText(
    _ span: vivi_backend_span_t,
    present: Bool
  ) throws -> String? {
    if !present {
      guard span.offset == 0, span.length == 0 else {
        throw NativeEventDecodingError.malformed
      }
      return nil
    }
    return try text(span, maximumBytes: 4_096)
  }

  mutating func optionalJSON<Role>(
    _ span: vivi_backend_span_t,
    present: Bool,
    _: Role.Type
  ) throws -> CanvasJSON<Role>? {
    if !present {
      guard span.offset == 0, span.length == 0 else {
        throw NativeEventDecodingError.malformed
      }
      return nil
    }
    let data = try consume(span, maximumBytes: 64 * 1_024, requireNonempty: true)
    do {
      return try CanvasJSON<Role>(data: data)
    } catch {
      throw NativeEventDecodingError.malformed
    }
  }

  mutating func requiredJSON<Role>(
    _ span: vivi_backend_span_t,
    _: Role.Type
  ) throws -> CanvasJSON<Role> {
    let data = try consume(span, maximumBytes: 64 * 1_024, requireNonempty: true)
    do {
      return try CanvasJSON<Role>(data: data)
    } catch {
      throw NativeEventDecodingError.malformed
    }
  }

  func finish() throws {
    guard offset == bytes.count else { throw NativeEventDecodingError.malformed }
  }

  private mutating func text(
    _ span: vivi_backend_span_t,
    maximumBytes: Int
  ) throws -> String {
    let data = try consume(span, maximumBytes: maximumBytes, requireNonempty: false)
    guard let value = String(data: data, encoding: .utf8) else {
      throw NativeEventDecodingError.malformed
    }
    return value
  }

  private mutating func consume(
    _ span: vivi_backend_span_t,
    maximumBytes: Int,
    requireNonempty: Bool
  ) throws -> Data {
    guard let start = Int(exactly: span.offset), let length = Int(exactly: span.length),
      start == offset, length <= maximumBytes, !requireNonempty || length > 0,
      start <= bytes.count, length <= bytes.count - start
    else {
      throw NativeEventDecodingError.malformed
    }
    offset += length
    return Data(bytes[start..<offset])
  }
}

enum NativeCanvasEventDecoder {
  static func requireAbsent(
    _ event: vivi_backend_event_t,
    declarations: [vivi_backend_canvas_declaration_t],
    actions: [vivi_backend_canvas_action_t],
    instances: [vivi_backend_canvas_instance_t]
  ) throws {
    guard declarations.isEmpty, actions.isEmpty, instances.isEmpty,
      snapshotIsNeutral(event.canvas_snapshot),
      completionIsNeutral(event.canvas_completion)
    else {
      throw NativeEventDecodingError.malformed
    }
  }

  static func decodeSnapshot(
    _ event: vivi_backend_event_t,
    bytes: [UInt8],
    declarations: [vivi_backend_canvas_declaration_t],
    actions: [vivi_backend_canvas_action_t],
    instances: [vivi_backend_canvas_instance_t]
  ) throws -> CanvasSnapshot {
    try requireCanvasEnvelope(event, contentKind: VIVI_BACKEND_CONTENT_CANVAS_SNAPSHOT)
    let raw = event.canvas_snapshot
    guard event.model_count == 0, event.semantic_span_count == 0, event.session_count == 0,
      event.transcript_item_count == 0,
      declarations.count == Int(exactly: raw.declaration_count),
      actions.count == Int(exactly: raw.action_count),
      instances.count == Int(exactly: raw.instance_count),
      declarations.count <= 128, instances.count <= 64,
      raw.flags & ~canvasKnownSnapshotFlags == 0, raw.reserved == 0,
      completionIsNeutral(event.canvas_completion)
    else {
      throw NativeEventDecodingError.malformed
    }

    let capability: CanvasCapability
    switch raw.capability {
    case VIVI_BACKEND_CANVAS_CAPABILITY_UNKNOWN: capability = .unknown
    case VIVI_BACKEND_CANVAS_CAPABILITY_UNSUPPORTED: capability = .unsupported
    case VIVI_BACKEND_CANVAS_CAPABILITY_SUPPORTED: capability = .supported
    default: throw NativeEventDecodingError.malformed
    }

    var decoder = CanvasByteDecoder(bytes: bytes)
    var decodedDeclarations: [CanvasDeclaration] = []
    var declarationIDs: Set<CanvasDeclarationID> = []
    var nextAction = 0
    for declaration in declarations {
      guard declaration.reserved == 0,
        declaration.flags & ~canvasKnownDeclarationFlags == 0,
        let actionOffset = Int(exactly: declaration.action_offset),
        let actionCount = Int(exactly: declaration.action_count),
        actionOffset == nextAction, actionCount <= 32,
        actionOffset <= actions.count, actionCount <= actions.count - actionOffset
      else {
        throw NativeEventDecodingError.malformed
      }
      let schema = try decoder.optionalJSON(
        declaration.input_schema_json,
        present: hasFlag(
          declaration.flags,
          VIVI_BACKEND_CANVAS_DECLARATION_INPUT_SCHEMA_PRESENT),
        CanvasSchemaRole.self)
      let extensionID = try decoder.identifier(declaration.extension_id)
      let extensionName = try decoder.requiredText(declaration.extension_name)
      let canvasID = try decoder.identifier(declaration.canvas_id)
      let id = try CanvasDeclarationID(extensionID: extensionID, canvasID: canvasID)
      guard declarationIDs.insert(id).inserted else {
        throw NativeEventDecodingError.malformed
      }
      let displayName = try decoder.requiredText(declaration.display_name)
      let description = try decoder.requiredText(declaration.description)
      var decodedActions: [CanvasActionDeclaration] = []
      var actionNames: Set<CanvasActionName> = []
      for action in actions[actionOffset..<(actionOffset + actionCount)] {
        guard action.reserved == 0, action.flags & ~canvasKnownActionFlags == 0 else {
          throw NativeEventDecodingError.malformed
        }
        let actionSchema = try decoder.optionalJSON(
          action.input_schema_json,
          present: hasFlag(action.flags, VIVI_BACKEND_CANVAS_ACTION_INPUT_SCHEMA_PRESENT),
          CanvasSchemaRole.self)
        let name = try CanvasActionName(decoder.identifier(action.name))
        guard actionNames.insert(name).inserted else {
          throw NativeEventDecodingError.malformed
        }
        decodedActions.append(
          CanvasActionDeclaration(
            name: name,
            description: try decoder.requiredText(action.description),
            inputSchema: actionSchema))
      }
      nextAction += actionCount
      decodedDeclarations.append(
        CanvasDeclaration(
          id: id,
          extensionName: extensionName,
          displayName: displayName,
          description: description,
          inputSchema: schema,
          actions: decodedActions))
    }
    guard nextAction == actions.count else { throw NativeEventDecodingError.malformed }

    var decodedInstances: [CanvasInstanceSnapshot] = []
    var instanceKeys: Set<CanvasInstanceKey> = []
    for instance in instances {
      guard zeroReserved(instance.reserved),
        instance.flags & ~canvasKnownInstanceFlags == 0
      else {
        throw NativeEventDecodingError.malformed
      }
      let openInput = try decoder.optionalJSON(
        instance.open_input_json,
        present: hasFlag(instance.flags, VIVI_BACKEND_CANVAS_INSTANCE_OPEN_INPUT_PRESENT),
        CanvasOpenInputRole.self)
      let title = try decoder.optionalText(
        instance.title,
        present: hasFlag(instance.flags, VIVI_BACKEND_CANVAS_INSTANCE_TITLE_PRESENT))
      let url = try decoder.optionalText(
        instance.url,
        present: hasFlag(instance.flags, VIVI_BACKEND_CANVAS_INSTANCE_URL_PRESENT))
      let status = try decoder.optionalText(
        instance.status,
        present: hasFlag(instance.flags, VIVI_BACKEND_CANVAS_INSTANCE_STATUS_PRESENT))
      let recordedTitle = try decoder.optionalText(
        instance.recorded_title,
        present: hasFlag(instance.flags, VIVI_BACKEND_CANVAS_INSTANCE_RECORDED_TITLE_PRESENT))
      let recordedInput = try decoder.optionalJSON(
        instance.recorded_input_json,
        present: hasFlag(instance.flags, VIVI_BACKEND_CANVAS_INSTANCE_RECORDED_INPUT_PRESENT),
        CanvasOpenInputRole.self)
      let declarationID = try CanvasDeclarationID(
        extensionID: decoder.identifier(instance.key.extension_id),
        canvasID: decoder.identifier(instance.key.canvas_id))
      let key = try CanvasInstanceKey(
        declarationID: declarationID,
        instanceID: CanvasInstanceID(
          validating: decoder.identifier(instance.key.instance_id)))
      guard instanceKeys.insert(key).inserted else {
        throw NativeEventDecodingError.malformed
      }

      let generationPresent = hasFlag(
        instance.flags,
        VIVI_BACKEND_CANVAS_INSTANCE_RENDERER_GENERATION_PRESENT)
      let runtime: CanvasRuntime
      switch instance.runtime {
      case VIVI_BACKEND_CANVAS_RUNTIME_CLOSED:
        guard !generationPresent, instance.renderer_generation == 0,
          title == nil, url == nil, status == nil
        else { throw NativeEventDecodingError.malformed }
        runtime = .closed
      case VIVI_BACKEND_CANVAS_RUNTIME_OPENING:
        guard !generationPresent, instance.renderer_generation == 0,
          title == nil, url == nil, status == nil
        else { throw NativeEventDecodingError.malformed }
        runtime = .opening
      case VIVI_BACKEND_CANVAS_RUNTIME_OPENED:
        guard generationPresent,
          let generation = CanvasRendererGeneration(instance.renderer_generation)
        else { throw NativeEventDecodingError.malformed }
        runtime = .opened(
          CanvasOpenedRuntime(generation: generation, title: title, url: url, status: status))
      case VIVI_BACKEND_CANVAS_RUNTIME_CLOSING:
        guard !generationPresent, instance.renderer_generation == 0,
          title == nil, url == nil, status == nil
        else { throw NativeEventDecodingError.malformed }
        runtime = .closing
      case VIVI_BACKEND_CANVAS_RUNTIME_UNAVAILABLE:
        guard !generationPresent, instance.renderer_generation == 0,
          title == nil, url == nil, status == nil
        else { throw NativeEventDecodingError.malformed }
        runtime = .unavailable
      default:
        throw NativeEventDecodingError.malformed
      }

      let record: CanvasRecord
      switch instance.record {
      case VIVI_BACKEND_CANVAS_RECORD_RECORDED:
        record = .recorded(title: recordedTitle, input: recordedInput)
      case VIVI_BACKEND_CANVAS_RECORD_REMOVED:
        guard recordedTitle == nil, recordedInput == nil else {
          throw NativeEventDecodingError.malformed
        }
        record = .removed
      default:
        throw NativeEventDecodingError.malformed
      }
      decodedInstances.append(
        CanvasInstanceSnapshot(
          key: key,
          openInput: openInput,
          runtime: runtime,
          record: record,
          degradation: try degradation(instance.degradation)))
    }
    try decoder.finish()
    return CanvasSnapshot(
      capability: capability,
      registryDegradation: try degradation(raw.registry_degradation),
      operationDegradation: try degradation(raw.operation_degradation),
      shutdownRequested: raw.flags
        & UInt32(VIVI_BACKEND_CANVAS_SNAPSHOT_SHUTDOWN_REQUESTED.rawValue) != 0,
      declarations: decodedDeclarations,
      instances: decodedInstances)
  }

  static func decodeCompletion(
    _ event: vivi_backend_event_t,
    bytes: [UInt8]
  ) throws -> CanvasOperationCompletion {
    try requireCanvasEnvelope(event, contentKind: VIVI_BACKEND_CONTENT_CANVAS_OPERATION)
    let raw = event.canvas_completion
    guard event.model_count == 0, event.semantic_span_count == 0, event.session_count == 0,
      event.transcript_item_count == 0, snapshotIsNeutral(event.canvas_snapshot),
      let id = CanvasOperationID(raw.operation_id),
      raw.flags & ~canvasKnownCompletionFlags == 0, zeroReserved(raw.reserved)
    else {
      throw NativeEventDecodingError.malformed
    }
    let succeeded = raw.outcome == VIVI_BACKEND_CANVAS_OPERATION_SUCCEEDED
    let failed = raw.outcome == VIVI_BACKEND_CANVAS_OPERATION_FAILED
    guard succeeded || failed else { throw NativeEventDecodingError.malformed }
    let failure: CanvasOperationFailure?
    if succeeded {
      guard raw.failure == VIVI_BACKEND_CANVAS_FAILURE_NONE else {
        throw NativeEventDecodingError.malformed
      }
      failure = nil
    } else {
      failure = try operationFailure(raw.failure)
    }

    var decoder = CanvasByteDecoder(bytes: bytes)
    let title = try decoder.optionalText(
      raw.title, present: hasFlag(raw.flags, VIVI_BACKEND_CANVAS_COMPLETION_TITLE_PRESENT))
    let url = try decoder.optionalText(
      raw.url, present: hasFlag(raw.flags, VIVI_BACKEND_CANVAS_COMPLETION_URL_PRESENT))
    let status = try decoder.optionalText(
      raw.status, present: hasFlag(raw.flags, VIVI_BACKEND_CANVAS_COMPLETION_STATUS_PRESENT))
    let actionResultPresent = hasFlag(
      raw.flags,
      VIVI_BACKEND_CANVAS_COMPLETION_ACTION_RESULT_PRESENT)

    let result: CanvasOperationCompletion
    switch raw.kind {
    case VIVI_BACKEND_CANVAS_OPERATION_OPEN:
      guard !actionResultPresent, raw.action_result_json.offset == 0,
        raw.action_result_json.length == 0
      else { throw NativeEventDecodingError.malformed }
      if let failure {
        guard title == nil, url == nil, status == nil else {
          throw NativeEventDecodingError.malformed
        }
        result = .openFailed(id: id, failure: failure)
      } else {
        result = .openSucceeded(
          id: id,
          metadata: CanvasOpenMetadata(title: title, url: url, status: status))
      }
    case VIVI_BACKEND_CANVAS_OPERATION_CLOSE:
      guard title == nil, url == nil, status == nil, !actionResultPresent,
        raw.action_result_json.offset == 0, raw.action_result_json.length == 0
      else { throw NativeEventDecodingError.malformed }
      result =
        if let failure {
          .closeFailed(id: id, failure: failure)
        } else {
          .closeSucceeded(id: id)
        }
    case VIVI_BACKEND_CANVAS_OPERATION_INVOKE_ACTION:
      guard title == nil, url == nil, status == nil else {
        throw NativeEventDecodingError.malformed
      }
      if let failure {
        guard !actionResultPresent, raw.action_result_json.offset == 0,
          raw.action_result_json.length == 0
        else { throw NativeEventDecodingError.malformed }
        result = .actionFailed(id: id, failure: failure)
      } else {
        guard actionResultPresent else { throw NativeEventDecodingError.malformed }
        result = .actionSucceeded(
          id: id,
          result: try decoder.requiredJSON(raw.action_result_json, CanvasActionResultRole.self))
      }
    default:
      throw NativeEventDecodingError.malformed
    }
    try decoder.finish()
    return result
  }

  private static func degradation(
    _ raw: vivi_backend_canvas_degradation_t
  ) throws -> CanvasDegradation? {
    switch raw {
    case VIVI_BACKEND_CANVAS_DEGRADATION_NONE: nil
    case VIVI_BACKEND_CANVAS_DEGRADATION_INVALID_SIGNAL: .invalidSignal
    case VIVI_BACKEND_CANVAS_DEGRADATION_LIMIT_EXCEEDED: .limitExceeded
    case VIVI_BACKEND_CANVAS_DEGRADATION_BACKPRESSURE: .backpressure
    case VIVI_BACKEND_CANVAS_DEGRADATION_HOST_FAILURE: .hostFailure
    default: throw NativeEventDecodingError.malformed
    }
  }

  private static func operationFailure(
    _ raw: vivi_backend_canvas_operation_failure_t
  ) throws -> CanvasOperationFailure {
    switch raw {
    case VIVI_BACKEND_CANVAS_FAILURE_DISABLED: .disabled
    case VIVI_BACKEND_CANVAS_FAILURE_UNSUPPORTED: .unsupported
    case VIVI_BACKEND_CANVAS_FAILURE_UNAVAILABLE: .unavailable
    case VIVI_BACKEND_CANVAS_FAILURE_INVALID_REQUEST: .invalidRequest
    case VIVI_BACKEND_CANVAS_FAILURE_BACKPRESSURE: .backpressure
    case VIVI_BACKEND_CANVAS_FAILURE_HOST_FAILURE: .hostFailure
    case VIVI_BACKEND_CANVAS_FAILURE_INVALID_SDK_RESULT: .invalidSDKResult
    case VIVI_BACKEND_CANVAS_FAILURE_STALE: .stale
    case VIVI_BACKEND_CANVAS_FAILURE_SHUTDOWN: .shutdown
    default: throw NativeEventDecodingError.malformed
    }
  }
}

private func requireCanvasEnvelope(
  _ event: vivi_backend_event_t,
  contentKind: vivi_backend_content_kind_t
) throws {
  guard event.content_kind == contentKind,
    event.content.offset == 0, event.content.length == 0,
    event.selected_model_id.offset == 0, event.selected_model_id.length == 0,
    event.tool_call_id.offset == 0, event.tool_call_id.length == 0,
    event.tool_title.offset == 0, event.tool_title.length == 0,
    event.tool_detail.offset == 0, event.tool_detail.length == 0,
    event.tool_input.offset == 0, event.tool_input.length == 0,
    presentationIsNeutral(event.tool_input_presentation),
    presentationIsNeutral(event.tool_output_presentation),
    event.tool_result == VIVI_BACKEND_TOOL_RESULT_NONE,
    event.selected_reasoning == VIVI_BACKEND_REASONING_NONE,
    event.switch_outcome == VIVI_BACKEND_MODEL_SWITCH_NONE,
    event.history_effect == VIVI_BACKEND_HISTORY_NONE,
    event.session_scope == VIVI_BACKEND_SESSION_SCOPE_NONE,
    event.session_resume_outcome == VIVI_BACKEND_SESSION_RESUME_NONE,
    event.default_saved == 0, event.cleanup_failed == 0,
    event.skipped_invalid_shards == 0, event.session_reserved == 0,
    event.reserved == 0
  else {
    throw NativeEventDecodingError.malformed
  }
}

private func presentationIsNeutral(_ value: vivi_backend_presentation_t) -> Bool {
  value.kind == VIVI_BACKEND_PRESENTATION_NONE
    && value.content.offset == 0 && value.content.length == 0
    && value.language == VIVI_BACKEND_LANGUAGE_NONE
    && value.semantic_span_offset == 0 && value.semantic_span_count == 0
    && value.reserved == 0
}

private func snapshotIsNeutral(_ value: vivi_backend_canvas_snapshot_t) -> Bool {
  value.capability == VIVI_BACKEND_CANVAS_CAPABILITY_NONE
    && value.registry_degradation == VIVI_BACKEND_CANVAS_DEGRADATION_NONE
    && value.operation_degradation == VIVI_BACKEND_CANVAS_DEGRADATION_NONE
    && value.flags == 0 && value.declaration_count == 0 && value.action_count == 0
    && value.instance_count == 0 && value.reserved == 0
}

private func completionIsNeutral(_ value: vivi_backend_canvas_completion_t) -> Bool {
  value.operation_id == 0 && value.kind == VIVI_BACKEND_CANVAS_OPERATION_NONE
    && value.outcome == VIVI_BACKEND_CANVAS_OPERATION_OUTCOME_NONE
    && value.failure == VIVI_BACKEND_CANVAS_FAILURE_NONE && value.flags == 0
    && value.title.offset == 0 && value.title.length == 0
    && value.url.offset == 0 && value.url.length == 0
    && value.status.offset == 0 && value.status.length == 0
    && value.action_result_json.offset == 0 && value.action_result_json.length == 0
    && zeroReserved(value.reserved)
}

private func hasFlag<T: RawRepresentable>(_ flags: UInt32, _ flag: T) -> Bool
where T.RawValue == UInt32 {
  flags & flag.rawValue != 0
}

private func zeroReserved<T>(_ value: T) -> Bool {
  withUnsafeBytes(of: value) { bytes in
    bytes.allSatisfy { $0 == 0 }
  }
}
