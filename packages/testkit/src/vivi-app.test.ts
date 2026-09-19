import { expect, test } from "bun:test";
import { createViviApp, type CopilotPort, type CopilotPortEvent } from "@vivi/core";
import { FakeCopilotPort } from "./index.js";

test("streams one response and stops through ViviApp", async () => {
  const app = createViviApp(new FakeCopilotPort(["hello ", "world"]));

  await app.dispatch({ type: "submit-prompt", text: "greet" });
  expect(app.view()).toEqual({
    phase: "ready",
    transcript: "User: greet\nAssistant: hello world",
  });

  await app.close();
  expect(app.view()).toEqual({
    phase: "stopped",
    transcript: "User: greet\nAssistant: hello world",
  });
});

test("preserves a partial response during reentrant shutdown", async () => {
  let releaseResponse: (() => void) | undefined;
  let responseStarted: (() => void) | undefined;
  const started = new Promise<void>((resolve) => {
    responseStarted = resolve;
  });
  const released = new Promise<void>((resolve) => {
    releaseResponse = resolve;
  });

  let closeCalls = 0;
  const port: CopilotPort = {
    async *respond(): AsyncIterable<CopilotPortEvent> {
      yield { type: "assistant-delta", text: "partial" };
      responseStarted?.();
      await released;
    },
    async close() {
      closeCalls += 1;
      releaseResponse?.();
    },
  };
  const app = createViviApp(port);
  const response = app.dispatch({ type: "submit-prompt", text: "greet" });
  await started;
  let reentrantClose: Promise<void> | undefined;
  app.subscribe((state) => {
    if (state.phase === "shutting-down") reentrantClose = app.close();
  });

  await Promise.all([app.close(), app.close()]);
  expect(reentrantClose).toBeDefined();
  await reentrantClose;
  await response;

  expect(closeCalls).toBe(1);
  expect(app.view()).toEqual({
    phase: "stopped",
    transcript: "User: greet\nAssistant: partial",
  });
});
