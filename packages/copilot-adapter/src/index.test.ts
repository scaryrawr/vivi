import { expect, mock, test } from "bun:test";

type Handler = (event: { data: { deltaContent?: string; content?: string; message?: string } }) => void;

class FakeSession {
  readonly handlers = new Map<string, Set<Handler>>();
  readonly calls: string[] = [];
  emitDelta = true;
  response: Promise<{ data: { content: string } } | undefined> = Promise.resolve({
    data: { content: "fallback" },
  });
  abort = async (): Promise<void> => {
    this.calls.push("abort");
  };
  disconnect = async (): Promise<void> => {
    this.calls.push("disconnect");
  };
  on(type: string, handler: Handler): () => void {
    const handlers = this.handlers.get(type) ?? new Set<Handler>();
    handlers.add(handler);
    this.handlers.set(type, handlers);
    return () => handlers.delete(handler);
  }
  emit(type: string, event: { data: { deltaContent?: string; content?: string; message?: string } }): void {
    for (const handler of this.handlers.get(type) ?? []) handler(event);
  }
  sendAndWait = async (): Promise<{ data: { content: string } } | undefined> => {
    if (this.emitDelta) {
      this.emit("assistant.message_delta", { data: { deltaContent: "streamed " } });
    }
    return this.response;
  };
}

class FakeClient {
  readonly session = new FakeSession();
  readonly calls: string[] = [];
  async start(): Promise<void> {
    this.calls.push("start");
  }
  async createSession(): Promise<FakeSession> {
    this.calls.push("createSession");
    return this.session;
  }
  async stop(): Promise<Error[]> {
    this.calls.push("stop");
    return [];
  }
}

const fakeClient = new FakeClient();

mock.module("@github/copilot-sdk", () => ({
  CopilotClient: class {
    constructor() {
      return fakeClient;
    }
  },
}));

const { createSdkCopilotPort } = await import("./index.js");

test("starts lazily and forwards deltas without duplicating the final message", async () => {
  fakeClient.calls.length = 0;
  fakeClient.session.calls.length = 0;
  const port = createSdkCopilotPort({ workingDirectory: process.cwd() });
  expect(fakeClient.calls).toEqual([]);

  const events: string[] = [];
  for await (const event of port.respond("hello")) {
    if (event.type === "assistant-delta") events.push(event.text);
  }

  expect(fakeClient.calls).toEqual(["start", "createSession"]);
  expect(events).toEqual(["streamed "]);
  await port.close();
  expect(fakeClient.session.calls).toEqual(["abort", "disconnect"]);
  expect(fakeClient.calls).toEqual(["start", "createSession", "stop"]);
});

test("uses the final message only when no delta arrived", async () => {
  fakeClient.session.emitDelta = false;
  const port = createSdkCopilotPort({ workingDirectory: process.cwd() });
  const events: string[] = [];
  for await (const event of port.respond("hello")) {
    if (event.type === "assistant-delta") events.push(event.text);
  }
  expect(events).toEqual(["fallback"]);
  await port.close();
  fakeClient.session.emitDelta = true;
});
