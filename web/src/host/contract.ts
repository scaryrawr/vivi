export const VIVI_HOST_PROTOCOL = "vivi.host" as const;
export const VIVI_HOST_VERSION = 1 as const;

declare const workspacePathBrand: unique symbol;
declare const sessionIdBrand: unique symbol;
declare const transcriptItemIdBrand: unique symbol;
declare const submissionIdBrand: unique symbol;

export type WorkspacePath = string & { readonly [workspacePathBrand]: true };
export type SessionId = string & { readonly [sessionIdBrand]: true };
export type TranscriptItemId = string & {
  readonly [transcriptItemIdBrand]: true;
};
export type ClientSubmissionId = string & {
  readonly [submissionIdBrand]: true;
};

export const workspacePath = (value: string) => value as WorkspacePath;
export const sessionId = (value: string) => value as SessionId;
export const transcriptItemId = (value: string) => value as TranscriptItemId;
export const clientSubmissionId = (value: string) =>
  value as ClientSubmissionId;

export type Appearance = "light" | "dark";

export type ConversationLifecycle =
  | { readonly kind: "starting" }
  | { readonly kind: "idle" }
  | { readonly kind: "responding" }
  | { readonly kind: "closing" }
  | { readonly kind: "closed" }
  | { readonly kind: "failed"; readonly message: string };

export type TranscriptItem =
  | {
      readonly id: TranscriptItemId;
      readonly kind: "user";
      readonly text: string;
    }
  | {
      readonly id: TranscriptItemId;
      readonly kind: "assistant";
      readonly markdown: string;
      readonly streaming: boolean;
    }
  | {
      readonly id: TranscriptItemId;
      readonly kind: "reasoning";
      readonly text: string;
      readonly streaming: boolean;
    }
  | {
      readonly id: TranscriptItemId;
      readonly kind: "tool";
      readonly title: string;
      readonly detail: string;
      readonly input?: string;
      readonly output?: string;
      readonly state: "running" | "succeeded" | "failed";
    }
  | {
      readonly id: TranscriptItemId;
      readonly kind: "status";
      readonly text: string;
    }
  | {
      readonly id: TranscriptItemId;
      readonly kind: "error";
      readonly message: string;
      readonly recovery?: string;
    };

export interface SessionSummary {
  readonly id: SessionId;
  readonly projectPath: WorkspacePath;
  readonly title: string;
  readonly lifecycle: ConversationLifecycle;
}

export interface ProjectSnapshot {
  readonly path: WorkspacePath;
  readonly displayName: string;
  readonly sessions: readonly SessionSummary[];
}

export interface SessionSnapshot extends SessionSummary {
  readonly activeWorkspace: WorkspacePath;
  readonly transcript: readonly TranscriptItem[];
  readonly error: HostError | null;
}

export interface HostError {
  readonly code: "startup" | "submission" | "stream" | "host";
  readonly message: string;
  readonly recovery: "retry" | "newConversation" | "none";
}

export interface HostSnapshot {
  readonly schemaVersion: 1;
  readonly revision: number;
  readonly projects: readonly ProjectSnapshot[];
  readonly selectedSessionId: SessionId | null;
  readonly selectedSession: SessionSnapshot | null;
  readonly applicationError: HostError | null;
}

export type HostCommandResult =
  | { readonly kind: "accepted" }
  | {
      readonly kind: "rejected";
      readonly reason: "invalid" | "busy" | "stopping" | "closed" | "failed";
      readonly message: string;
    };

export type ConnectionState =
  | { readonly kind: "connected" }
  | { readonly kind: "failed"; readonly message: string }
  | { readonly kind: "disconnected" };

export interface SendMessageRequest {
  readonly sessionId: SessionId;
  readonly submissionId: ClientSubmissionId;
  readonly text: string;
}

export interface ConnectedViviHost {
  getSnapshot(): HostSnapshot;
  getConnectionState(): ConnectionState;
  subscribe(listener: () => void): () => void;
  selectSession(id: SessionId): Promise<HostCommandResult>;
  createConversation(projectPath: WorkspacePath): Promise<HostCommandResult>;
  sendMessage(request: SendMessageRequest): Promise<HostCommandResult>;
  disconnect(): void;
}

export interface ViviHostPort {
  readonly protocol: typeof VIVI_HOST_PROTOCOL;
  readonly version: typeof VIVI_HOST_VERSION;
  connect(): Promise<ConnectedViviHost>;
}
