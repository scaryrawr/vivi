import {
  sessionId,
  transcriptItemId,
  VIVI_HOST_PROTOCOL,
  VIVI_HOST_VERSION,
  workspacePath,
  type ConnectedViviHost,
  type ConnectionState,
  type ConversationLifecycle,
  type HostCommandResult,
  type HostError,
  type HostSnapshot,
  type ProjectSnapshot,
  type SendMessageRequest,
  type SessionSnapshot,
  type SessionSummary,
  type TranscriptItem,
  type ViviHostPort,
} from "./contract";

const handlerName = "viviHostV1";
const bridgeFailureCodes = new Set([
  "invalid_message",
  "protocol_mismatch",
  "stale_session",
  "duplicate_request",
  "handshake_required",
  "already_connected",
  "disconnected",
  "capacity_exceeded",
]);
const maximumRetiredBridgeSessions = 64;
const retiredBridgeSessions = new Set<string>();
const retiredBridgeSessionOrder: string[] = [];
let activeConnection: NativeConnectedViviHost | undefined;

function registerConnection(connection: NativeConnectedViviHost) {
  activeConnection = connection;
  retiredBridgeSessions.delete(connection.bridgeSessionId);
  window.__viviHostV1Receive = routeNativeMessage;
}

function retireConnection(connection: NativeConnectedViviHost) {
  rememberRetiredBridgeSession(connection.bridgeSessionId);
  if (activeConnection !== connection) return;
  activeConnection = undefined;
  delete window.__viviHostV1Receive;
}

function rememberRetiredBridgeSession(bridgeSessionId: string) {
  if (retiredBridgeSessions.has(bridgeSessionId)) return;
  retiredBridgeSessions.add(bridgeSessionId);
  retiredBridgeSessionOrder.push(bridgeSessionId);
  if (retiredBridgeSessionOrder.length <= maximumRetiredBridgeSessions) return;
  const expired = retiredBridgeSessionOrder.shift();
  if (expired) retiredBridgeSessions.delete(expired);
}

function routeNativeMessage(message: unknown) {
  let bridgeSessionId: string | undefined;
  if (
    typeof message === "object" &&
    message !== null &&
    !Array.isArray(message)
  ) {
    const candidate = (message as Record<string, unknown>).bridgeSessionId;
    if (typeof candidate === "string") bridgeSessionId = candidate;
  }
  if (bridgeSessionId && retiredBridgeSessions.has(bridgeSessionId)) return;
  activeConnection?.receiveFromNative(message);
}

function resetConnectionRouter() {
  activeConnection = undefined;
  retiredBridgeSessions.clear();
  retiredBridgeSessionOrder.length = 0;
  delete window.__viviHostV1Receive;
}
const maximumSafeInteger = Number.MAX_SAFE_INTEGER;

type CommandName =
  | "connect"
  | "selectSession"
  | "createConversation"
  | "sendMessage"
  | "disconnect";

interface WireRequest {
  readonly protocol: typeof VIVI_HOST_PROTOCOL;
  readonly version: typeof VIVI_HOST_VERSION;
  readonly bridgeSessionId: string;
  readonly requestId: string;
  readonly command: CommandName;
  readonly payload: Record<string, unknown>;
}

type PendingRequest = {
  readonly command: CommandName;
  readonly resolve: (value: HostCommandResult) => void;
  readonly reject: (reason: NativeHostBridgeError) => void;
};

export type NativeHostBridgeErrorCode =
  | "unavailable"
  | "invalid-message"
  | "protocol-mismatch"
  | "stale-session"
  | "duplicate-response"
  | "disconnected";

export class NativeHostBridgeError extends Error {
  readonly code: NativeHostBridgeErrorCode;

  constructor(code: NativeHostBridgeErrorCode, message: string) {
    super(message);
    this.code = code;
    this.name = "NativeHostBridgeError";
  }
}

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: Record<
        string,
        { postMessage(message: unknown): void } | undefined
      >;
    };
    __viviHostV1Receive?: (message: unknown) => void;
  }
}

export class NativeViviHostPort implements ViviHostPort {
  readonly protocol = VIVI_HOST_PROTOCOL;
  readonly version = VIVI_HOST_VERSION;

  async connect(): Promise<ConnectedViviHost> {
    const handler = window.webkit?.messageHandlers?.[handlerName];
    if (!handler) {
      throw new NativeHostBridgeError(
        "unavailable",
        "The native Vivi host bridge is unavailable.",
      );
    }
    const connection = new NativeConnectedViviHost(
      handler,
      crypto.randomUUID(),
    );
    await connection.start();
    return connection;
  }
}

class NativeConnectedViviHost implements ConnectedViviHost {
  private readonly handler: { postMessage(message: unknown): void };
  readonly bridgeSessionId: string;
  private snapshot: HostSnapshot = {
    schemaVersion: 1,
    revision: 0,
    projects: [],
    selectedSession: null,
    applicationError: null,
  };
  private connectionState: ConnectionState = { kind: "disconnected" };
  private readonly listeners = new Set<() => void>();
  private readonly pending = new Map<string, PendingRequest>();
  private readonly readyPromise: Promise<void>;
  private readyResolve!: () => void;
  private readyReject!: (reason: NativeHostBridgeError) => void;
  private connectResponseAccepted = false;
  private initialSnapshotReceived = false;
  private connectedStateReceived = false;
  private ready = false;
  private disconnected = false;

  constructor(
    handler: { postMessage(message: unknown): void },
    bridgeSessionId: string,
  ) {
    this.handler = handler;
    this.bridgeSessionId = bridgeSessionId;
    this.readyPromise = new Promise((resolve, reject) => {
      this.readyResolve = resolve;
      this.readyReject = reject;
    });
  }

  async start() {
    registerConnection(this);
    const result = await this.command("connect", {});
    if (result.kind !== "accepted") {
      const error = new NativeHostBridgeError(
        "invalid-message",
        `The native host rejected the connection: ${result.message}`,
      );
      this.fail(error);
      throw error;
    }
    await this.readyPromise;
  }

  getSnapshot() {
    return this.snapshot;
  }

  getConnectionState() {
    return this.connectionState;
  }

  subscribe(listener: () => void) {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  selectSession(id: SessionSummary["id"]) {
    return this.command("selectSession", { id });
  }

  createConversation(projectPath: ProjectSnapshot["path"]) {
    return this.command("createConversation", { projectPath });
  }

  sendMessage(request: SendMessageRequest) {
    if (new TextEncoder().encode(request.text).length > 1_000_000) {
      return Promise.resolve<HostCommandResult>({
        kind: "rejected",
        reason: "invalid",
        message: "Messages must not exceed 1,000,000 UTF-8 bytes.",
      });
    }
    return this.command("sendMessage", {
      sessionId: request.sessionId,
      submissionId: request.submissionId,
      text: request.text,
    });
  }

  disconnect() {
    if (this.disconnected) return;
    const error = new NativeHostBridgeError(
      "disconnected",
      "The native host bridge disconnected.",
    );
    this.terminate(error, { kind: "disconnected" }, true);
  }

  private command(
    command: CommandName,
    payload: Record<string, unknown>,
  ): Promise<HostCommandResult> {
    if (this.disconnected) {
      return Promise.reject(
        new NativeHostBridgeError(
          "disconnected",
          "The native host bridge is disconnected.",
        ),
      );
    }
    const request = this.request(command, payload);
    return new Promise((resolve, reject) => {
      this.pending.set(request.requestId, { command, resolve, reject });
      this.handler.postMessage(request);
    });
  }

  private request(
    command: CommandName,
    payload: Record<string, unknown>,
  ): WireRequest {
    return {
      protocol: VIVI_HOST_PROTOCOL,
      version: VIVI_HOST_VERSION,
      bridgeSessionId: this.bridgeSessionId,
      requestId: crypto.randomUUID(),
      command,
      payload,
    };
  }

  receiveFromNative(message: unknown) {
    this.receive(message);
  }

  private receive(input: unknown) {
    try {
      const message = record(input, "message");
      exactKeys(
        message,
        [
          "protocol",
          "version",
          "bridgeSessionId",
          "kind",
          "requestId",
          "result",
          "snapshot",
          "connectionState",
          "error",
        ],
        "message",
      );
      if (message.protocol !== VIVI_HOST_PROTOCOL || message.version !== 1) {
        throw new NativeHostBridgeError(
          "protocol-mismatch",
          "The native host protocol or version does not match.",
        );
      }

      if (message.bridgeSessionId !== this.bridgeSessionId) {
        throw new NativeHostBridgeError(
          "stale-session",
          "The native host message belongs to another bridge session.",
        );
      }
      switch (string(message.kind, "message.kind")) {
        case "response":
          exactKeys(
            message,
            [
              "protocol",
              "version",
              "bridgeSessionId",
              "kind",
              "requestId",
              "result",
            ],
            "message",
          );
          this.receiveResponse(message);
          return;
        case "snapshot":
          exactKeys(
            message,
            ["protocol", "version", "bridgeSessionId", "kind", "snapshot"],
            "message",
          );
          this.receiveSnapshot(message);
          return;
        case "connection":
          exactKeys(
            message,
            [
              "protocol",
              "version",
              "bridgeSessionId",
              "kind",
              "connectionState",
            ],
            "message",
          );
          this.connectionState = parseConnectionState(
            message.connectionState,
            "message.connectionState",
          );
          if (this.connectionState.kind === "connected") {
            this.connectedStateReceived = true;
            this.checkReady();
          } else if (!this.ready) {
            throw new NativeHostBridgeError(
              "disconnected",
              "The native host disconnected during the handshake.",
            );
          } else {
            const message =
              this.connectionState.kind === "failed"
                ? this.connectionState.message
                : "The native host bridge disconnected.";
            this.terminate(
              new NativeHostBridgeError("disconnected", message),
              this.connectionState,
              false,
            );
            return;
          }
          this.emit();
          return;
        case "failure":
          exactKeys(
            message,
            ["protocol", "version", "bridgeSessionId", "kind", "error"],
            "message",
          );
          this.fail(
            new NativeHostBridgeError(
              "invalid-message",
              parseBridgeFailure(message.error),
            ),
          );
          return;
        default:
          invalid("message.kind", "unknown message kind");
      }
    } catch (error) {
      this.fail(
        error instanceof NativeHostBridgeError
          ? error
          : new NativeHostBridgeError(
              "invalid-message",
              "The native host sent an invalid message.",
            ),
      );
    }
  }

  private receiveResponse(message: Record<string, unknown>) {
    const requestId = uuid(message.requestId, "message.requestId");
    const pending = this.pending.get(requestId);
    if (!pending) {
      throw new NativeHostBridgeError(
        "duplicate-response",
        "The native host returned an unknown or duplicate response.",
      );
    }
    const result = parseCommandResult(message.result, "message.result");
    this.pending.delete(requestId);
    if (pending.command === "connect" && result.kind === "accepted") {
      this.connectResponseAccepted = true;
      this.checkReady();
    }
    pending.resolve(result);
  }

  private receiveSnapshot(message: Record<string, unknown>) {
    const next = parseSnapshot(message.snapshot, "message.snapshot");
    const isInitialSnapshot = !this.initialSnapshotReceived;
    this.initialSnapshotReceived = true;
    if (!isInitialSnapshot && next.revision <= this.snapshot.revision) return;
    this.snapshot = next;
    this.emit();
    this.checkReady();
  }

  private fail(error: NativeHostBridgeError) {
    this.terminate(error, { kind: "failed", message: error.message }, true);
  }

  private terminate(
    error: NativeHostBridgeError,
    state: ConnectionState,
    notifyHost: boolean,
  ) {
    if (this.disconnected) return;
    this.disconnected = true;
    this.connectionState = state;
    if (this.connectResponseAccepted) this.readyReject(error);
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
    this.emit();
    this.listeners.clear();
    retireConnection(this);
    if (notifyHost) this.handler.postMessage(this.request("disconnect", {}));
  }

  private emit() {
    this.listeners.forEach((listener) => listener());
  }

  private checkReady() {
    if (
      this.connectResponseAccepted &&
      this.initialSnapshotReceived &&
      this.connectedStateReceived
    ) {
      this.ready = true;
      this.readyResolve();
    }
  }
}

function parseSnapshot(input: unknown, path: string): HostSnapshot {
  const value = record(input, path);
  exactKeys(
    value,
    [
      "schemaVersion",
      "revision",
      "projects",
      "selectedSession",
      "applicationError",
    ],
    path,
  );
  if (value.schemaVersion !== 1) invalid(`${path}.schemaVersion`, "must be 1");
  const snapshot: HostSnapshot = {
    schemaVersion: 1,
    revision: safeInteger(value.revision, `${path}.revision`, 0),
    projects: array(value.projects, `${path}.projects`, 100).map(
      (project, index) => parseProject(project, `${path}.projects[${index}]`),
    ),
    selectedSession:
      value.selectedSession === null
        ? null
        : parseSession(value.selectedSession, `${path}.selectedSession`),
    applicationError:
      value.applicationError === null
        ? null
        : parseHostError(value.applicationError, `${path}.applicationError`),
  };
  validateSnapshotIdentity(snapshot, path);
  return snapshot;
}

function validateSnapshotIdentity(snapshot: HostSnapshot, path: string) {
  const projectPaths = new Set<string>();
  const sessionIDs = new Set<string>();
  for (const [projectIndex, project] of snapshot.projects.entries()) {
    if (projectPaths.has(project.path)) {
      invalid(
        `${path}.projects[${projectIndex}].path`,
        "duplicate project path",
      );
    }
    projectPaths.add(project.path);
    for (const [sessionIndex, session] of project.sessions.entries()) {
      if (session.projectPath !== project.path) {
        invalid(
          `${path}.projects[${projectIndex}].sessions[${sessionIndex}].projectPath`,
          "must match its containing project path",
        );
      }
      if (sessionIDs.has(session.id)) {
        invalid(
          `${path}.projects[${projectIndex}].sessions[${sessionIndex}].id`,
          "duplicate session ID",
        );
      }
      sessionIDs.add(session.id);
    }
  }
  const selected = snapshot.selectedSession;
  if (!selected) return;
  if (!sessionIDs.has(selected.id)) {
    invalid(
      `${path}.selectedSession.id`,
      "must reference exactly one session summary",
    );
  }
  if (selected.activeWorkspace !== sessionWorkspace(snapshot, selected.id)) {
    invalid(
      `${path}.selectedSession.activeWorkspace`,
      "must match the selected session project path",
    );
  }
  const transcriptIDs = new Set<string>();
  for (const [index, item] of selected.transcript.entries()) {
    if (transcriptIDs.has(item.id)) {
      invalid(
        `${path}.selectedSession.transcript[${index}].id`,
        "duplicate transcript item ID",
      );
    }
    transcriptIDs.add(item.id);
  }
}

function sessionWorkspace(snapshot: HostSnapshot, id: string) {
  for (const project of snapshot.projects) {
    if (project.sessions.some((session) => session.id === id))
      return project.path;
  }
  return undefined;
}

function parseProject(input: unknown, path: string): ProjectSnapshot {
  const value = record(input, path);
  exactKeys(value, ["path", "displayName", "sessions"], path);
  return {
    path: workspacePath(absolutePath(value.path, `${path}.path`)),
    displayName: boundedString(value.displayName, `${path}.displayName`, 512),
    sessions: array(value.sessions, `${path}.sessions`, 1_000).map(
      (session, index) =>
        parseSessionSummary(session, `${path}.sessions[${index}]`),
    ),
  };
}

function parseSessionSummary(input: unknown, path: string): SessionSummary {
  const value = record(input, path);
  exactKeys(value, ["id", "projectPath", "title", "lifecycle"], path);
  return {
    id: sessionId(uuid(value.id, `${path}.id`)),
    projectPath: workspacePath(
      absolutePath(value.projectPath, `${path}.projectPath`),
    ),
    title: boundedString(value.title, `${path}.title`, 4_096),
    lifecycle: parseLifecycle(value.lifecycle, `${path}.lifecycle`),
  };
}

function parseLifecycle(input: unknown, path: string): ConversationLifecycle {
  const value = record(input, path);
  const kind = string(value.kind, `${path}.kind`);
  if (kind === "failed") {
    exactKeys(value, ["kind", "message"], path);
    return {
      kind,
      message: boundedString(value.message, `${path}.message`, 16_384),
    };
  }
  exactKeys(value, ["kind"], path);
  if (
    kind === "starting" ||
    kind === "idle" ||
    kind === "responding" ||
    kind === "closing" ||
    kind === "closed"
  ) {
    return { kind };
  }
  invalid(`${path}.kind`, "unknown lifecycle");
}

function parseSession(input: unknown, path: string): SessionSnapshot {
  const value = record(input, path);
  exactKeys(value, ["id", "activeWorkspace", "transcript", "error"], path);
  return {
    id: sessionId(uuid(value.id, `${path}.id`)),
    activeWorkspace: workspacePath(
      absolutePath(value.activeWorkspace, `${path}.activeWorkspace`),
    ),
    transcript: array(value.transcript, `${path}.transcript`, 10_000).map(
      (item, index) => parseTranscript(item, `${path}.transcript[${index}]`),
    ),
    error:
      value.error === null
        ? null
        : parseHostError(value.error, `${path}.error`),
  };
}

function parseTranscript(input: unknown, path: string): TranscriptItem {
  const value = record(input, path);
  const id = transcriptItemId(
    boundedString(value.id, `${path}.id`, 256, false),
  );
  const kind = string(value.kind, `${path}.kind`);
  switch (kind) {
    case "user":
      exactKeys(value, ["id", "kind", "text"], path);
      return {
        id,
        kind,
        text: boundedString(value.text, `${path}.text`, 1_000_000),
      };
    case "assistant":
      exactKeys(value, ["id", "kind", "markdown", "streaming"], path);
      return {
        id,
        kind,
        markdown: boundedString(value.markdown, `${path}.markdown`, 1_000_000),
        streaming: boolean(value.streaming, `${path}.streaming`),
      };
    case "reasoning":
      exactKeys(value, ["id", "kind", "text", "streaming"], path);
      return {
        id,
        kind,
        text: boundedString(value.text, `${path}.text`, 1_000_000),
        streaming: boolean(value.streaming, `${path}.streaming`),
      };
    case "tool": {
      exactKeys(
        value,
        ["id", "kind", "title", "detail", "input", "output", "state"],
        path,
      );
      const state = string(value.state, `${path}.state`);
      if (state !== "running" && state !== "succeeded" && state !== "failed")
        invalid(`${path}.state`, "unknown tool state");
      return {
        id,
        kind,
        title: boundedString(value.title, `${path}.title`, 16_384),
        detail: boundedString(value.detail, `${path}.detail`, 65_536),
        ...(value.input === undefined
          ? {}
          : { input: boundedString(value.input, `${path}.input`, 1_000_000) }),
        ...(value.output === undefined
          ? {}
          : {
              output: boundedString(value.output, `${path}.output`, 1_000_000),
            }),
        state,
      };
    }
    case "status":
      exactKeys(value, ["id", "kind", "text"], path);
      return {
        id,
        kind,
        text: boundedString(value.text, `${path}.text`, 65_536),
      };
    case "error":
      exactKeys(value, ["id", "kind", "message", "recovery"], path);
      return {
        id,
        kind,
        message: boundedString(value.message, `${path}.message`, 65_536),
        ...(value.recovery === undefined
          ? {}
          : {
              recovery: boundedString(
                value.recovery,
                `${path}.recovery`,
                65_536,
              ),
            }),
      };
    default:
      invalid(`${path}.kind`, "unknown transcript item");
  }
}

function parseHostError(input: unknown, path: string): HostError {
  const value = record(input, path);
  exactKeys(value, ["code", "message"], path);
  const code = string(value.code, `${path}.code`);
  if (
    code !== "startup" &&
    code !== "submission" &&
    code !== "stream" &&
    code !== "host"
  ) {
    invalid(`${path}.code`, "unknown host error");
  }
  return {
    code,
    message: boundedString(value.message, `${path}.message`, 65_536),
  };
}

function parseCommandResult(input: unknown, path: string): HostCommandResult {
  const value = record(input, path);
  const kind = string(value.kind, `${path}.kind`);
  if (kind === "accepted") {
    exactKeys(value, ["kind"], path);
    return { kind };
  }
  if (kind !== "rejected") invalid(`${path}.kind`, "unknown command result");
  exactKeys(value, ["kind", "reason", "message"], path);
  const reason = string(value.reason, `${path}.reason`);
  if (
    reason !== "invalid" &&
    reason !== "busy" &&
    reason !== "stopping" &&
    reason !== "closed" &&
    reason !== "failed"
  ) {
    invalid(`${path}.reason`, "unknown rejection reason");
  }
  return {
    kind,
    reason,
    message: boundedString(value.message, `${path}.message`, 65_536),
  };
}

function parseConnectionState(input: unknown, path: string): ConnectionState {
  const value = record(input, path);
  const kind = string(value.kind, `${path}.kind`);
  if (kind === "failed") {
    exactKeys(value, ["kind", "message"], path);
    return {
      kind,
      message: boundedString(value.message, `${path}.message`, 65_536),
    };
  }
  exactKeys(value, ["kind"], path);
  if (kind === "connected" || kind === "disconnected") return { kind };
  invalid(`${path}.kind`, "unknown connection state");
}

function parseBridgeFailure(input: unknown): string {
  const value = record(input, "message.error");
  exactKeys(value, ["code", "message"], "message.error");
  const code = boundedString(value.code, "message.error.code", 128, false);
  if (!bridgeFailureCodes.has(code)) {
    invalid("message.error.code", "unknown failure code");
  }
  return boundedString(value.message, "message.error.message", 65_536);
}

function record(input: unknown, path: string): Record<string, unknown> {
  if (
    typeof input !== "object" ||
    input === null ||
    Array.isArray(input) ||
    Object.getPrototypeOf(input) !== Object.prototype
  ) {
    invalid(path, "must be an object");
  }
  return input as Record<string, unknown>;
}

function exactKeys(
  value: Record<string, unknown>,
  allowed: readonly string[],
  path: string,
) {
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) invalid(`${path}.${key}`, "unknown field");
  }
}

function array(input: unknown, path: string, maximumLength: number): unknown[] {
  if (!Array.isArray(input) || input.length > maximumLength)
    invalid(path, `must be an array of at most ${maximumLength} items`);
  return input;
}

function string(input: unknown, path: string): string {
  if (typeof input !== "string") invalid(path, "must be a string");
  return input;
}

function boundedString(
  input: unknown,
  path: string,
  maximumLength: number,
  allowEmpty = true,
): string {
  const value = string(input, path);
  const byteLength = new TextEncoder().encode(value).byteLength;
  if ((!allowEmpty && byteLength === 0) || byteLength > maximumLength)
    invalid(path, `must contain at most ${maximumLength} UTF-8 bytes`);
  return value;
}

function boolean(input: unknown, path: string): boolean {
  if (typeof input !== "boolean") invalid(path, "must be a boolean");
  return input;
}

function safeInteger(input: unknown, path: string, minimum: number): number {
  if (
    typeof input !== "number" ||
    !Number.isSafeInteger(input) ||
    input < minimum ||
    input > maximumSafeInteger
  ) {
    invalid(path, `must be a safe integer greater than or equal to ${minimum}`);
  }
  return input;
}

function uuid(input: unknown, path: string): string {
  const value = string(input, path);
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
      value,
    )
  ) {
    invalid(path, "must be a UUID");
  }
  return value;
}

function absolutePath(input: unknown, path: string): string {
  const value = boundedString(input, path, 32_768, false);
  if (!value.startsWith("/") || value.includes("\0"))
    invalid(path, "must be an absolute path");
  if (
    value !== "/" &&
    value
      .slice(1)
      .split("/")
      .some(
        (component) =>
          component === "" || component === "." || component === "..",
      )
  ) {
    invalid(
      path,
      "must be a canonical absolute path without dot or empty components",
    );
  }
  return value;
}

function invalid(path: string, reason: string): never {
  throw new NativeHostBridgeError(
    "invalid-message",
    `Invalid native host message at ${path}: ${reason}.`,
  );
}

export const nativeHostTesting = {
  parseSnapshot,
  parseCommandResult,
  resetConnectionRouter,
};
