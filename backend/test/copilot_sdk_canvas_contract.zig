const std = @import("std");
const copilot = @import("copilot_sdk");

const reviewed_sdk_revision = "7695c34cb0ccfc4ec09aaadf91f29e4a12f86379";
const first_typed_canvas_revision = "34283286ec9924b427a17efe571787669634268f";
const upstream_contract_revision = "39c777fe7bf893ba5a4f8b710feeb2172d1d40f9";
const upstream_cli_version = "1.0.84-4";

const canvas_id = "vivi.contract-probe";
const extension_id = "vivi.contract-probe-extension";
const instance_id = "vivi.contract-probe:main";

fn onOpen(
    _: std.mem.Allocator,
    request: copilot.extensibility.CanvasOpenRequest,
    _: ?*anyopaque,
) anyerror!copilot.extensibility.CanvasOpenResult {
    try std.testing.expectEqualStrings(extension_id, request.extension_id);
    try std.testing.expectEqualStrings(canvas_id, request.canvas_id);
    try std.testing.expectEqualStrings(instance_id, request.instance_id);
    return .{
        .url = "https://example.invalid/vivi-contract-probe",
        .title = "Contract probe",
        .status = "ready",
    };
}

fn onClose(
    request: copilot.extensibility.CanvasCloseRequest,
    _: ?*anyopaque,
) anyerror!void {
    try std.testing.expectEqualStrings(extension_id, request.extension_id);
    try std.testing.expectEqualStrings(canvas_id, request.canvas_id);
    try std.testing.expectEqualStrings(instance_id, request.instance_id);
}

fn refresh(
    allocator: std.mem.Allocator,
    request: copilot.extensibility.CanvasActionRequest,
    _: ?*anyopaque,
) anyerror![]u8 {
    try std.testing.expectEqualStrings(extension_id, request.extension_id);
    try std.testing.expectEqualStrings(canvas_id, request.canvas_id);
    try std.testing.expectEqualStrings(instance_id, request.instance_id);
    try std.testing.expectEqualStrings("refresh", request.action_name);
    return allocator.dupe(u8, "{\"refreshed\":true}");
}

const actions = [_]copilot.CanvasAction{.{
    .name = "refresh",
    .description = "Refresh the contract fixture",
    .input_schema_json = "{\"type\":\"object\"}",
    .handler = refresh,
}};

const canvas: copilot.Canvas = .{
    .declaration = .{
        .id = canvas_id,
        .display_name = "Vivi contract probe",
        .description = "Credential-free typed canvas fixture",
        .input_schema_json = "{\"type\":\"object\"}",
    },
    .on_open = onOpen,
    .on_close = onClose,
    .actions = &actions,
};

comptime {
    const declarations = .{
        "Canvas",
        "CanvasAction",
        "CanvasDeclaration",
        "CanvasProviderIdentity",
        "OpenCanvas",
        "OpenCanvasRequest",
        "OpenCanvasResult",
        "OpenCanvasSnapshot",
        "InvokeCanvasActionRequest",
        "Capability",
        "CapabilityState",
        "CapabilitySet",
    };
    for (declarations) |name| {
        if (!@hasDecl(copilot, name))
            @compileError("pinned copilot_sdk no longer exports " ++ name);
    }

    const open_canvas: *const fn (
        copilot.Session,
        std.mem.Allocator,
        copilot.OpenCanvasRequest,
    ) anyerror!copilot.OpenCanvasResult = &copilot.Session.openCanvas;
    const close_canvas: *const fn (
        copilot.Session,
        []const u8,
    ) anyerror!void = &copilot.Session.closeCanvas;
    const invoke_canvas_action: *const fn (
        copilot.Session,
        std.mem.Allocator,
        copilot.InvokeCanvasActionRequest,
    ) anyerror!copilot.OwnedJson = &copilot.Session.invokeCanvasAction;
    const snapshot_open_canvases: *const fn (
        copilot.Session,
        std.mem.Allocator,
    ) anyerror!copilot.OpenCanvasSnapshot = &copilot.Session.snapshotOpenCanvases;
    _ = .{
        open_canvas,
        close_canvas,
        invoke_canvas_action,
        snapshot_open_canvases,
    };

    if (@hasDecl(copilot.Session, "reopenCanvas"))
        @compileError("review the newly public reopenCanvas contract");
    if (@hasField(copilot.CreateExtensions, "open_canvases"))
        @compileError("review newly create-time openCanvases semantics");
    if (!@hasField(copilot.ResumeExtensions, "open_canvases") or
        !@hasField(copilot.JoinExtensions, "open_canvases"))
        @compileError("resume/join openCanvases contract changed");

    const registry = copilot.SessionEventTypes.CanvasRegistryChangedData;
    if (@hasField(registry, "added") or
        @hasField(registry, "removed") or
        @hasField(registry, "operation"))
        @compileError("canvas registry events gained explicit delta semantics");

    const correlated = .{
        copilot.SessionEventTypes.CanvasOpenedData,
        copilot.SessionEventTypes.CanvasClosedData,
        copilot.SessionEventTypes.CanvasRecordedData,
        copilot.SessionEventTypes.CanvasRemovedData,
        copilot.SessionEventTypes.CanvasUnavailableData,
    };
    for (correlated) |EventData| {
        if (@hasField(EventData, "operation_id") or
            @hasField(EventData, "operationId") or
            @hasField(EventData, "request_id"))
            @compileError("canvas lifecycle events gained operation correlation");
    }
}

test "reviewed evidence matches the sole SDK pin" {
    const manifest = @embedFile("build_zig_zon");
    try std.testing.expect(std.mem.indexOf(u8, manifest, reviewed_sdk_revision) != null);
    try std.testing.expectEqual(@as(usize, 40), first_typed_canvas_revision.len);
    try std.testing.expectEqual(@as(usize, 40), upstream_contract_revision.len);
    try std.testing.expectEqualStrings("1.0.84-4", upstream_cli_version);
}

test "declaration callbacks and renderer opt-ins compose through public types" {
    try copilot.extensibility.validate(.{
        .canvases = &.{canvas},
        .request_canvas_renderer = true,
        .request_extensions = true,
    });

    const config: copilot.CreateSessionConfig = .{
        .extensions = .{
            .common = .{
                .canvases = &.{canvas},
                .request_canvas_renderer = true,
                .request_extensions = true,
            },
            .canvas_provider = .{
                .id = extension_id,
                .name = "Vivi contract probe",
            },
        },
    };
    try std.testing.expect(config.extensions.common.request_canvas_renderer);
    try std.testing.expect(config.extensions.common.request_extensions);
    try std.testing.expectEqualStrings(
        extension_id,
        config.extensions.canvas_provider.?.id,
    );

    const opened = try canvas.on_open(std.testing.allocator, .{
        .extension_id = extension_id,
        .canvas_id = canvas_id,
        .instance_id = instance_id,
        .input_json = "{\"topic\":\"contract\"}",
        .host_json = "{\"renderer\":\"fixture\"}",
        .session_json = "{\"id\":\"fixture\"}",
    }, canvas.context);
    try std.testing.expectEqualStrings("ready", opened.status.?);

    try canvas.on_close.?(.{
        .extension_id = extension_id,
        .canvas_id = canvas_id,
        .instance_id = instance_id,
    }, canvas.context);

    const result = try actions[0].handler(std.testing.allocator, .{
        .extension_id = extension_id,
        .canvas_id = canvas_id,
        .instance_id = instance_id,
        .action_name = "refresh",
        .input_json = "{}",
    }, canvas.context);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"refreshed\":true}", result);
}

test "runtime identity is explicit while operation correlation is absent" {
    const open_request: copilot.OpenCanvasRequest = .{
        .extension_id = extension_id,
        .canvas_id = canvas_id,
        .instance_id = instance_id,
        .input_json = "{}",
    };
    try std.testing.expectEqualStrings(extension_id, open_request.extension_id.?);
    try std.testing.expectEqualStrings(canvas_id, open_request.canvas_id);
    try std.testing.expectEqualStrings(instance_id, open_request.instance_id);

    const action_request: copilot.InvokeCanvasActionRequest = .{
        .instance_id = instance_id,
        .action_name = "refresh",
        .input_json = "{}",
    };
    try std.testing.expectEqualStrings(instance_id, action_request.instance_id);
    try std.testing.expect(!@hasField(copilot.InvokeCanvasActionRequest, "operation_id"));
    try std.testing.expect(!@hasField(copilot.OpenCanvasRequest, "operation_id"));
}

test "canvas registry event is a typed list without declared delta semantics" {
    var event = try parseEvent(
        \\{"type":"session.canvas.registry_changed","data":{"canvases":[{"extensionId":"fixture.extension","extensionName":"Fixture","canvasId":"review","displayName":"Review","description":"Review changes","inputSchema":{"type":"object"},"actions":[{"name":"refresh","description":"Refresh","inputSchema":{"type":"object"}}]}]}}
    );
    defer event.deinit(std.testing.allocator);

    try std.testing.expectEqual(
        copilot.SessionEventTag.session_canvas_registry_changed,
        std.meta.activeTag(event),
    );
    const registry = event.session_canvas_registry_changed.data;
    try std.testing.expectEqual(@as(usize, 1), registry.canvases.len);
    try std.testing.expectEqualStrings(
        "fixture.extension",
        registry.canvases[0].extension_id,
    );
    try std.testing.expectEqualStrings("review", registry.canvases[0].canvas_id);
    try std.testing.expectEqualStrings(
        "refresh",
        registry.canvases[0].actions.?[0].name,
    );
}

test "canvas lifecycle event variants preserve their public payloads" {
    var opened = try parseEvent(
        \\{"type":"session.canvas.opened","data":{"instanceId":"vivi.contract-probe:main","extensionId":"vivi.contract-probe-extension","extensionName":"Fixture","canvasId":"review","title":"Review","status":"ready","url":"https://example.invalid/review","input":{"selection":"src/main.zig"}}}
    );
    defer opened.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        copilot.SessionEventTag.session_canvas_opened,
        std.meta.activeTag(opened),
    );
    try expectIdentity(opened.session_canvas_opened.data);
    try std.testing.expectEqualStrings(
        "ready",
        opened.session_canvas_opened.data.status.?,
    );

    var recorded = try parseEvent(
        \\{"type":"session.canvas.recorded","data":{"instanceId":"vivi.contract-probe:main","extensionId":"vivi.contract-probe-extension","canvasId":"review","title":"Review","input":{"selection":"src/main.zig"}}}
    );
    defer recorded.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        copilot.SessionEventTag.session_canvas_recorded,
        std.meta.activeTag(recorded),
    );
    try expectIdentity(recorded.session_canvas_recorded.data);
    try std.testing.expect(recorded.session_canvas_recorded.data.input != null);

    var closed = try parseEvent(
        \\{"type":"session.canvas.closed","data":{"instanceId":"vivi.contract-probe:main","extensionId":"vivi.contract-probe-extension","canvasId":"review"}}
    );
    defer closed.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        copilot.SessionEventTag.session_canvas_closed,
        std.meta.activeTag(closed),
    );
    try expectIdentity(closed.session_canvas_closed.data);

    var removed = try parseEvent(
        \\{"type":"session.canvas.removed","data":{"instanceId":"vivi.contract-probe:main","extensionId":"vivi.contract-probe-extension","canvasId":"review"}}
    );
    defer removed.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        copilot.SessionEventTag.session_canvas_removed,
        std.meta.activeTag(removed),
    );
    try expectIdentity(removed.session_canvas_removed.data);

    var unavailable = try parseEvent(
        \\{"type":"session.canvas.unavailable","data":{"instanceId":"vivi.contract-probe:main","extensionId":"vivi.contract-probe-extension","canvasId":"review"}}
    );
    defer unavailable.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        copilot.SessionEventTag.session_canvas_unavailable,
        std.meta.activeTag(unavailable),
    );
    try expectIdentity(unavailable.session_canvas_unavailable.data);
}

test "capability and openCanvases resume semantics fail closed and preserve presence" {
    const capabilities = copilot.CapabilitySet{};
    try std.testing.expectEqual(
        copilot.CapabilityState.unknown,
        capabilities.state(.canvases),
    );
    try std.testing.expect(!capabilities.supports(.canvases));

    const omitted_resume: copilot.ResumeExtensions = .{};
    const empty_resume: copilot.ResumeExtensions = .{ .open_canvases = &.{} };
    const omitted_join: copilot.JoinExtensions = .{};
    const empty_join: copilot.JoinExtensions = .{ .open_canvases = &.{} };
    try std.testing.expect(omitted_resume.open_canvases == null);
    try std.testing.expectEqual(@as(usize, 0), empty_resume.open_canvases.?.len);
    try std.testing.expect(omitted_join.open_canvases == null);
    try std.testing.expectEqual(@as(usize, 0), empty_join.open_canvases.?.len);
}

fn parseEvent(json: []const u8) !copilot.SessionEvent {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        json,
        .{},
    );
    defer parsed.deinit();
    return copilot.session.parseEvent(std.testing.allocator, parsed.value);
}

fn expectIdentity(value: anytype) !void {
    try std.testing.expectEqualStrings(instance_id, value.instance_id);
    try std.testing.expectEqualStrings(extension_id, value.extension_id);
    try std.testing.expectEqualStrings("review", value.canvas_id);
}
