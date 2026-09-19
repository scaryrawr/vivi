import { afterEach, describe, expect, it } from "vitest";
import { fixtures } from "../fixtures";
import {
  NativeHostBridgeError,
  NativeViviHostPort,
  nativeHostTesting,
} from "./native";

afterEach(() => {
  delete window.webkit;
  nativeHostTesting.resetConnectionRouter();
});

describe("NativeViviHostPort", () => {
  it.each([
    ["snapshot, connection, response", ["snapshot", "connection", "response"]],
    ["response, snapshot, connection", ["response", "snapshot", "connection"]],
    ["connection, response, snapshot", ["connection", "response", "snapshot"]],
  ] as const)(
    "connects after %s and not before all handshake publications",
    async (_name, order) => {
      const { connecting, connect } = startConnection();
      let settled = false;
      void connecting.finally(() => {
        settled = true;
      });

      for (const [index, publication] of order.entries()) {
        publishHandshake(connect, publication);
        await Promise.resolve();
        if (index < order.length - 1) expect(settled).toBe(false);
      }
      const host = await connecting;
      expect(host.getSnapshot()).toEqual(fixtures.one);
      expect(host.getConnectionState()).toEqual({ kind: "connected" });
    },
  );

  it("uses a named versioned request and preserves snapshot identity", async () => {
    const posted: unknown[] = [];
    window.webkit = {
      messageHandlers: {
        viviHostV1: { postMessage: (message) => posted.push(message) },
      },
    };
    const connecting = new NativeViviHostPort().connect();
    const connect = posted[0] as Record<string, unknown>;
    expect(connect).toMatchObject({
      protocol: "vivi.host",
      version: 1,
      command: "connect",
      payload: {},
    });

    window.__viviHostV1Receive?.({
      protocol: "vivi.host",
      version: 1,
      bridgeSessionId: connect.bridgeSessionId,
      kind: "snapshot",
      snapshot: fixtures.one,
    });
    window.__viviHostV1Receive?.({
      protocol: "vivi.host",
      version: 1,
      bridgeSessionId: connect.bridgeSessionId,
      kind: "connection",
      connectionState: { kind: "connected" },
    });
    window.__viviHostV1Receive?.({
      protocol: "vivi.host",
      version: 1,
      bridgeSessionId: connect.bridgeSessionId,
      kind: "response",
      requestId: connect.requestId,
      result: { kind: "accepted" },
    });
    const host = await connecting;
    const first = host.getSnapshot();

    window.__viviHostV1Receive?.({
      protocol: "vivi.host",
      version: 1,
      bridgeSessionId: connect.bridgeSessionId,
      kind: "snapshot",
      snapshot: structuredClone(fixtures.one),
    });
    expect(host.getSnapshot()).toBe(first);
  });

  it("installs a valid revision-zero initial snapshot", async () => {
    const { connecting, connect } = startConnection();
    publishHandshake(connect, "snapshot", { ...fixtures.one, revision: 0 });
    publishHandshake(connect, "connection");
    publishHandshake(connect, "response");

    const host = await connecting;
    expect(host.getSnapshot()).toEqual({ ...fixtures.one, revision: 0 });
  });

  it("fails closed on unknown fields and rejects pending commands", async () => {
    const posted: Record<string, unknown>[] = [];
    window.webkit = {
      messageHandlers: {
        viviHostV1: {
          postMessage: (message) =>
            posted.push(message as Record<string, unknown>),
        },
      },
    };
    const connecting = new NativeViviHostPort().connect();
    const connect = posted[0];
    window.__viviHostV1Receive?.({
      protocol: "vivi.host",
      version: 1,
      bridgeSessionId: connect.bridgeSessionId,
      kind: "response",
      requestId: connect.requestId,
      result: { kind: "accepted" },
    });
    window.__viviHostV1Receive?.({
      protocol: "vivi.host",
      version: 1,
      bridgeSessionId: connect.bridgeSessionId,
      kind: "snapshot",
      snapshot: fixtures.one,
    });
    window.__viviHostV1Receive?.({
      protocol: "vivi.host",
      version: 1,
      bridgeSessionId: connect.bridgeSessionId,
      kind: "connection",
      connectionState: { kind: "connected" },
    });
    const host = await connecting;
    const pending = host.selectSession(
      "0c8f9cc7-4767-4cec-92a3-9d7759e89a01" as never,
    );

    window.__viviHostV1Receive?.({
      protocol: "vivi.host",
      version: 1,
      bridgeSessionId: connect.bridgeSessionId,
      kind: "snapshot",
      snapshot: { ...fixtures.one, surprise: true },
    });

    await expect(pending).rejects.toMatchObject({
      code: "invalid-message",
    });
    expect(host.getConnectionState()).toMatchObject({ kind: "failed" });
    expect(posted.at(-1)).toMatchObject({ command: "disconnect" });
    await expect(
      host.createConversation("/test/vivi" as never),
    ).rejects.toMatchObject({ code: "disconnected" });
    expect(window.__viviHostV1Receive).toBeUndefined();
  });

  it("rejects stale bridge sessions", async () => {
    const posted: Record<string, unknown>[] = [];
    window.webkit = {
      messageHandlers: {
        viviHostV1: {
          postMessage: (message) =>
            posted.push(message as Record<string, unknown>),
        },
      },
    };
    const connecting = new NativeViviHostPort().connect();
    window.__viviHostV1Receive?.({
      protocol: "vivi.host",
      version: 1,
      bridgeSessionId: crypto.randomUUID(),
      kind: "response",
      requestId: posted[0].requestId,
      result: { kind: "accepted" },
    });
    await expect(connecting).rejects.toEqual(
      expect.objectContaining<Partial<NativeHostBridgeError>>({
        code: "stale-session",
      }),
    );
  });

  it("rejects connect when the correlated response is malformed", async () => {
    const { connecting, connect } = startConnection();
    window.__viviHostV1Receive?.({
      protocol: "vivi.host",
      version: 1,
      bridgeSessionId: connect.bridgeSessionId,
      kind: "response",
      requestId: connect.requestId,
      result: { kind: "accepted", unexpected: true },
    });

    await expect(connecting).rejects.toMatchObject({
      code: "invalid-message",
    });
  });

  it("disconnects a bridge after a typed connect rejection", async () => {
    const posted: Record<string, unknown>[] = [];
    window.webkit = {
      messageHandlers: {
        viviHostV1: {
          postMessage: (message) =>
            posted.push(message as Record<string, unknown>),
        },
      },
    };
    const connecting = new NativeViviHostPort().connect();
    const connect = posted[0];
    window.__viviHostV1Receive?.({
      protocol: "vivi.host",
      version: 1,
      bridgeSessionId: connect.bridgeSessionId,
      kind: "response",
      requestId: connect.requestId,
      result: { kind: "rejected", reason: "closed", message: "not available" },
    });

    await expect(connecting).rejects.toMatchObject({
      code: "invalid-message",
    });
    expect(window.__viviHostV1Receive).toBeUndefined();
    expect(posted.at(-1)).toMatchObject({
      bridgeSessionId: connect.bridgeSessionId,
      command: "disconnect",
    });
  });

  it("fails closed on unknown native failure codes", async () => {
    const { connecting, connect } = startConnection();
    window.__viviHostV1Receive?.({
      protocol: "vivi.host",
      version: 1,
      bridgeSessionId: connect.bridgeSessionId,
      kind: "failure",
      error: { code: "future_failure", message: "not V1" },
    });

    await expect(connecting).rejects.toMatchObject({
      code: "invalid-message",
    });
  });

  it("retires an active bridge before routing a replacement", async () => {
    const posted: Record<string, unknown>[] = [];
    window.webkit = {
      messageHandlers: {
        viviHostV1: {
          postMessage: (message) =>
            posted.push(message as Record<string, unknown>),
        },
      },
    };

    const firstConnecting = new NativeViviHostPort().connect();
    const firstConnect = posted[0];
    publishCompleteHandshake(firstConnect);
    const first = await firstConnecting;
    const oldPending = first.selectSession(
      "0c8f9cc7-4767-4cec-92a3-9d7759e89a01" as never,
    );
    const oldRequest = posted.at(-1)!;

    const secondConnecting = new NativeViviHostPort().connect();
    const secondConnect = posted.at(-1)!;
    await expect(oldPending).rejects.toMatchObject({ code: "disconnected" });
    expect(first.getConnectionState()).toEqual({ kind: "disconnected" });
    publishCompleteHandshake(secondConnect);
    const second = await secondConnecting;

    window.__viviHostV1Receive?.({
      protocol: "vivi.host",
      version: 1,
      bridgeSessionId: oldRequest.bridgeSessionId,
      kind: "response",
      requestId: oldRequest.requestId,
      result: { kind: "accepted" },
    });
    expect(second.getConnectionState()).toEqual({ kind: "connected" });

    const currentPending = second.selectSession(
      "0c8f9cc7-4767-4cec-92a3-9d7759e89a01" as never,
    );
    const currentRequest = posted.at(-1)!;
    window.__viviHostV1Receive?.({
      protocol: "vivi.host",
      version: 1,
      bridgeSessionId: currentRequest.bridgeSessionId,
      kind: "response",
      requestId: currentRequest.requestId,
      result: { kind: "accepted" },
    });
    await expect(currentPending).resolves.toEqual({ kind: "accepted" });
  });

  it.each([
    [{ kind: "disconnected" }, { kind: "disconnected" }],
    [
      { kind: "failed", message: "native stopped" },
      { kind: "failed", message: "native stopped" },
    ],
  ] as const)(
    "makes post-handshake %j terminal",
    async (publication, expectedState) => {
      const posted: Record<string, unknown>[] = [];
      window.webkit = {
        messageHandlers: {
          viviHostV1: {
            postMessage: (message) =>
              posted.push(message as Record<string, unknown>),
          },
        },
      };
      const connecting = new NativeViviHostPort().connect();
      const connect = posted[0];
      publishCompleteHandshake(connect);
      const host = await connecting;
      const pending = host.selectSession(
        "0c8f9cc7-4767-4cec-92a3-9d7759e89a01" as never,
      );
      window.__viviHostV1Receive?.({
        protocol: "vivi.host",
        version: 1,
        bridgeSessionId: connect.bridgeSessionId,
        kind: "connection",
        connectionState: publication,
      });

      await expect(pending).rejects.toMatchObject({ code: "disconnected" });
      expect(host.getConnectionState()).toEqual(expectedState);
      const postedAfterTerminalState = posted.length;
      await expect(
        host.createConversation("/test/vivi" as never),
      ).rejects.toMatchObject({ code: "disconnected" });
      expect(posted).toHaveLength(postedAfterTerminalState);
      expect(window.__viviHostV1Receive).toBeUndefined();
    },
  );

  it("rejects oversized outbound text without posting it", async () => {
    const posted: Record<string, unknown>[] = [];
    window.webkit = {
      messageHandlers: {
        viviHostV1: {
          postMessage: (message) =>
            posted.push(message as Record<string, unknown>),
        },
      },
    };
    const connecting = new NativeViviHostPort().connect();
    const connect = posted[0];
    publishCompleteHandshake(connect);
    const host = await connecting;
    const postedBeforeCommand = posted.length;

    await expect(
      host.sendMessage({
        sessionId: "0c8f9cc7-4767-4cec-92a3-9d7759e89a01" as never,
        submissionId: crypto.randomUUID() as never,
        text: "é".repeat(500_001),
      }),
    ).resolves.toMatchObject({ kind: "rejected", reason: "invalid" });
    expect(posted).toHaveLength(postedBeforeCommand);
  });
});

describe("native host validation", () => {
  it("accepts every existing fixture as HostSnapshot V1", () => {
    for (const snapshot of Object.values(fixtures)) {
      expect(nativeHostTesting.parseSnapshot(snapshot, "snapshot")).toEqual(
        snapshot,
      );
    }
  });

  it("rejects unsafe revisions, malformed paths, oversized UTF-8, and widened V1", () => {
    expect(() =>
      nativeHostTesting.parseSnapshot(
        { ...fixtures.one, revision: Number.MAX_SAFE_INTEGER + 1 },
        "snapshot",
      ),
    ).toThrow(/safe integer/);
    expect(() =>
      nativeHostTesting.parseSnapshot(
        {
          ...fixtures.one,
          projects: [{ ...fixtures.one.projects[0], path: "relative" }],
        },
        "snapshot",
      ),
    ).toThrow(/absolute path/);
    expect(() =>
      nativeHostTesting.parseSnapshot(
        {
          ...fixtures.one,
          projects: [{ ...fixtures.one.projects[0], path: "/test/../vivi" }],
        },
        "snapshot",
      ),
    ).toThrow(/canonical absolute path/);
    expect(() =>
      nativeHostTesting.parseSnapshot(
        {
          ...fixtures.one,
          projects: [
            {
              ...fixtures.one.projects[0],
              displayName: "💥".repeat(129),
            },
          ],
        },
        "snapshot",
      ),
    ).toThrow(/UTF-8 bytes/);
    const selected = fixtures.one.selectedSession!;
    expect(() =>
      nativeHostTesting.parseSnapshot(
        {
          ...fixtures.one,
          selectedSession: {
            ...selected,
            transcript: [
              {
                ...selected.transcript[0],
                spans: [],
              },
            ],
          },
        },
        "snapshot",
      ),
    ).toThrow(/spans.*unknown field/);
    expect(() =>
      nativeHostTesting.parseCommandResult(
        { kind: "accepted", extra: true },
        "result",
      ),
    ).toThrow(/unknown field/);
  });

  it("rejects inconsistent snapshot identity graphs", () => {
    expect(() =>
      nativeHostTesting.parseSnapshot(
        {
          ...fixtures.one,
          projects: [fixtures.one.projects[0], fixtures.one.projects[0]],
        },
        "snapshot",
      ),
    ).toThrow(/duplicate project path/);
    expect(() =>
      nativeHostTesting.parseSnapshot(
        {
          ...fixtures.one,
          selectedSession: {
            ...fixtures.one.selectedSession!,
            id: crypto.randomUUID(),
          },
        },
        "snapshot",
      ),
    ).toThrow(/reference exactly one session summary/);
    expect(() =>
      nativeHostTesting.parseSnapshot(
        {
          ...fixtures.one,
          selectedSession: {
            ...fixtures.one.selectedSession!,
            transcript: [
              fixtures.one.selectedSession!.transcript[0],
              fixtures.one.selectedSession!.transcript[0],
            ],
          },
        },
        "snapshot",
      ),
    ).toThrow(/duplicate transcript item ID/);
  });
});

function startConnection() {
  const posted: Record<string, unknown>[] = [];
  window.webkit = {
    messageHandlers: {
      viviHostV1: {
        postMessage: (message) =>
          posted.push(message as Record<string, unknown>),
      },
    },
  };
  const connecting = new NativeViviHostPort().connect();
  return { connecting, connect: posted[0] };
}

function publishHandshake(
  connect: Record<string, unknown>,
  publication: "snapshot" | "connection" | "response",
  snapshot = fixtures.one,
) {
  const base = {
    protocol: "vivi.host",
    version: 1,
    bridgeSessionId: connect.bridgeSessionId,
  };
  switch (publication) {
    case "snapshot":
      window.__viviHostV1Receive?.({
        ...base,
        kind: "snapshot",
        snapshot,
      });
      return;
    case "connection":
      window.__viviHostV1Receive?.({
        ...base,
        kind: "connection",
        connectionState: { kind: "connected" },
      });
      return;
    case "response":
      window.__viviHostV1Receive?.({
        ...base,
        kind: "response",
        requestId: connect.requestId,
        result: { kind: "accepted" },
      });
  }
}

function publishCompleteHandshake(connect: Record<string, unknown>) {
  publishHandshake(connect, "snapshot");
  publishHandshake(connect, "connection");
  publishHandshake(connect, "response");
}
