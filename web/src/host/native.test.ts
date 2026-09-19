import { afterEach, describe, expect, it } from "vitest";
import { fixtures } from "../fixtures";
import {
  NativeHostBridgeError,
  NativeViviHostPort,
  nativeHostTesting,
} from "./native";

afterEach(() => {
  delete window.webkit;
  delete window.__viviHostV1Receive;
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
      result: { kind: "rejected", message: "not available" },
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
