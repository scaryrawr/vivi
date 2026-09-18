import {
  sessionId,
  transcriptItemId,
  VIVI_HOST_PROTOCOL,
  VIVI_HOST_VERSION,
  type ClientSubmissionId,
  type ConnectedViviHost,
  type ConnectionState,
  type HostCommandResult,
  type HostSnapshot,
  type SendMessageRequest,
  type SessionId,
  type SessionSnapshot,
  type ViviHostPort,
  type WorkspacePath,
} from "./contract";

export class MockViviHost implements ViviHostPort, ConnectedViviHost {
  readonly protocol = VIVI_HOST_PROTOCOL;
  readonly version = VIVI_HOST_VERSION;
  private snapshot: HostSnapshot;
  private connectionState: ConnectionState = { kind: "connected" };
  private listeners = new Set<() => void>();
  private acceptedSubmissions = new Set<ClientSubmissionId>();
  private sessions = new Map<SessionId, SessionSnapshot>();
  private nextId = 100;

  constructor(snapshot: HostSnapshot) {
    this.snapshot = structuredClone(snapshot);
    if (this.snapshot.selectedSession) {
      this.sessions.set(
        this.snapshot.selectedSession.id,
        this.snapshot.selectedSession,
      );
    }
  }

  async connect(): Promise<ConnectedViviHost> {
    return this;
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

  async selectSession(id: SessionId): Promise<HostCommandResult> {
    if (this.connectionState.kind !== "connected") return disconnected();
    const summary = this.snapshot.projects
      .flatMap((project) => project.sessions)
      .find((session) => session.id === id);
    if (!summary)
      return rejected("invalid", "That conversation is no longer available.");
    const existing = this.sessions.get(id);
    const selected =
      existing ??
      ({
        ...summary,
        activeWorkspace: summary.projectPath,
        transcript: [],
        error: null,
      } satisfies SessionSnapshot);
    this.sessions.set(id, selected);
    this.publish({
      ...this.snapshot,
      revision: this.snapshot.revision + 1,
      selectedSession: selected,
    });
    return { kind: "accepted" };
  }

  async createConversation(
    projectPath: WorkspacePath,
  ): Promise<HostCommandResult> {
    if (this.connectionState.kind !== "connected") return disconnected();
    const projectIndex = this.snapshot.projects.findIndex(
      (project) => project.path === projectPath,
    );
    if (projectIndex < 0)
      return rejected("invalid", "That project is no longer available.");
    const id = sessionId(`0c8f9cc7-4767-4cec-92a3-9d7759e8${this.nextId++}`);
    const created: SessionSnapshot = {
      id,
      projectPath,
      activeWorkspace: projectPath,
      title: "",
      lifecycle: { kind: "idle" },
      transcript: [],
      error: null,
    };
    this.sessions.set(id, created);
    const projects = this.snapshot.projects.map((project, index) =>
      index === projectIndex
        ? { ...project, sessions: [...project.sessions, created] }
        : project,
    );
    this.publish({
      ...this.snapshot,
      revision: this.snapshot.revision + 1,
      projects,
      selectedSession: created,
    });
    return { kind: "accepted" };
  }

  async sendMessage(request: SendMessageRequest): Promise<HostCommandResult> {
    if (this.connectionState.kind !== "connected") return disconnected();
    if (this.acceptedSubmissions.has(request.submissionId))
      return { kind: "accepted" };
    const selected = this.snapshot.selectedSession;
    if (!selected || selected.id !== request.sessionId)
      return rejected("invalid", "Select the conversation before sending.");
    if (selected.lifecycle.kind !== "idle")
      return rejected("busy", "Wait for the current response to finish.");
    if (!request.text.trim())
      return rejected("invalid", "Enter a message first.");

    this.acceptedSubmissions.add(request.submissionId);
    const suffix = this.nextId++;
    const transcript = [
      ...selected.transcript,
      {
        id: transcriptItemId(`user-${suffix}`),
        kind: "user" as const,
        text: request.text,
      },
      {
        id: transcriptItemId(`assistant-${suffix}`),
        kind: "assistant" as const,
        markdown:
          "The browser mock accepted the message through the versioned host port. A native host will replace this deterministic response in layer 2.",
        streaming: false,
      },
    ];
    const updated = { ...selected, transcript };
    this.sessions.set(selected.id, updated);
    this.publish({
      ...this.snapshot,
      revision: this.snapshot.revision + 1,
      selectedSession: updated,
    });
    return { kind: "accepted" };
  }

  disconnect() {
    if (this.connectionState.kind === "disconnected") return;
    this.connectionState = { kind: "disconnected" };
    this.listeners.forEach((listener) => listener());
    this.listeners.clear();
  }

  private publish(snapshot: HostSnapshot) {
    this.snapshot = snapshot;
    this.listeners.forEach((listener) => listener());
  }
}

function rejected(
  reason: Extract<HostCommandResult, { kind: "rejected" }>["reason"],
  message: string,
): HostCommandResult {
  return { kind: "rejected", reason, message };
}

function disconnected(): HostCommandResult {
  return rejected("closed", "The host is disconnected.");
}
