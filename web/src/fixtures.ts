import {
  sessionId,
  transcriptItemId,
  workspacePath,
  type HostSnapshot,
  type ProjectSnapshot,
  type SessionSnapshot,
  type SessionSummary,
  type TranscriptItem,
} from "./host/contract";

const ids = {
  alpha: sessionId("0c8f9cc7-4767-4cec-92a3-9d7759e89a01"),
  beta: sessionId("0c8f9cc7-4767-4cec-92a3-9d7759e89a02"),
  gamma: sessionId("0c8f9cc7-4767-4cec-92a3-9d7759e89a03"),
  duplicate: sessionId("0c8f9cc7-4767-4cec-92a3-9d7759e89a04"),
};

const paths = {
  vivi: workspacePath("/Users/mike/GitHub/vivi"),
  sdk: workspacePath("/Users/mike/GitHub/copilot-sdk-zig"),
  long: workspacePath(
    "/Users/mike/GitHub/client-work/extraordinarily-long-enterprise-repository-name",
  ),
};

const baseTranscript: readonly TranscriptItem[] = [
  {
    id: transcriptItemId("user-1"),
    kind: "user",
    text: "Why does selecting a saved conversation move it in the sidebar?",
  },
  {
    id: transcriptItemId("reasoning-1"),
    kind: "reasoning",
    text: "I need to trace whether selection mutates the ordered collection or only the selected identifier.",
    streaming: false,
  },
  {
    id: transcriptItemId("tool-1"),
    kind: "tool",
    title: "Search conversation ordering",
    detail: "Searched NativeApplicationCoordinator.swift",
    input: 'rg "selectedID|records" macos/Vivi',
    output: "ConversationCollection.select(_:) updates selectedID only.",
    state: "succeeded",
  },
  {
    id: transcriptItemId("assistant-1"),
    kind: "assistant",
    markdown:
      "Selection should update only the selected conversation identifier. The ordered project and session arrays remain unchanged, so moving between the **top, middle, and bottom rows** never changes their position.",
    streaming: false,
  },
];

function summary(
  id: SessionSummary["id"],
  projectPath: SessionSummary["projectPath"],
  title: string,
  lifecycle: SessionSummary["lifecycle"] = { kind: "idle" },
): SessionSummary {
  return { id, projectPath, title, lifecycle };
}

const viviSessions = [
  summary(ids.alpha, paths.vivi, "Stabilize native session ordering"),
  summary(ids.beta, paths.vivi, ""),
  summary(ids.duplicate, paths.vivi, ""),
] as const;

const sdkSessions = [
  summary(ids.gamma, paths.sdk, "Review streaming event ownership"),
] as const;

function project(
  path: ProjectSnapshot["path"],
  displayName: string,
  sessions: readonly SessionSummary[],
): ProjectSnapshot {
  return { path, displayName, sessions };
}

function selectedSession(
  value: SessionSummary,
  transcript: readonly TranscriptItem[] = baseTranscript,
): SessionSnapshot {
  return {
    ...value,
    activeWorkspace: value.projectPath,
    transcript,
    error: null,
  };
}

const empty: HostSnapshot = {
  schemaVersion: 1,
  revision: 1,
  projects: [],
  selectedSessionId: null,
  selectedSession: null,
  applicationError: null,
};

const one: HostSnapshot = {
  schemaVersion: 1,
  revision: 1,
  projects: [project(paths.vivi, "vivi", [viviSessions[0]])],
  selectedSessionId: ids.alpha,
  selectedSession: selectedSession(viviSessions[0]),
  applicationError: null,
};

const multiple: HostSnapshot = {
  schemaVersion: 1,
  revision: 1,
  projects: [
    project(paths.vivi, "vivi", viviSessions),
    project(paths.sdk, "copilot-sdk-zig", sdkSessions),
  ],
  selectedSessionId: ids.beta,
  selectedSession: selectedSession(viviSessions[1], []),
  applicationError: null,
};

const longTitles: HostSnapshot = {
  ...multiple,
  projects: [
    project(paths.long, "extraordinarily-long-enterprise-repository-name", [
      summary(
        ids.alpha,
        paths.long,
        "Investigate why a deeply nested workspace with an unusually descriptive conversation title truncates poorly",
      ),
    ]),
  ],
  selectedSessionId: ids.alpha,
  selectedSession: selectedSession(
    summary(
      ids.alpha,
      paths.long,
      "Investigate why a deeply nested workspace with an unusually descriptive conversation title truncates poorly",
    ),
  ),
};

const streamingTranscript: readonly TranscriptItem[] = [
  ...baseTranscript.slice(0, 1),
  {
    id: transcriptItemId("reasoning-stream"),
    kind: "reasoning",
    text: "Comparing the host-provided order with the local selection state…",
    streaming: true,
  },
  {
    id: transcriptItemId("tool-stream"),
    kind: "tool",
    title: "Run focused tests",
    detail: "zig build test",
    input: "zig build test",
    state: "running",
  },
  {
    id: transcriptItemId("assistant-stream"),
    kind: "assistant",
    markdown:
      "The collection order is stable. Selecting another session only changes",
    streaming: true,
  },
];

const streaming: HostSnapshot = {
  ...one,
  selectedSession: selectedSession(
    { ...viviSessions[0], lifecycle: { kind: "responding" } },
    streamingTranscript,
  ),
  projects: [
    project(paths.vivi, "vivi", [
      { ...viviSessions[0], lifecycle: { kind: "responding" } },
    ]),
  ],
};

const error: HostSnapshot = {
  ...one,
  applicationError: {
    code: "host",
    message: "The native host stopped publishing application state.",
    recovery: "retry",
  },
  selectedSession: {
    ...selectedSession(viviSessions[0]),
    error: {
      code: "submission",
      message:
        "The message could not be sent because the conversation is closing.",
      recovery: "newConversation",
    },
    transcript: [
      ...baseTranscript,
      {
        id: transcriptItemId("error-1"),
        kind: "error",
        message: "The response stream ended unexpectedly.",
        recovery: "Start a new conversation and try again.",
      },
    ],
  },
};

export const fixtures = {
  empty,
  one,
  multiple,
  longTitles,
  streaming,
  error,
};

export type FixtureName = keyof typeof fixtures;
