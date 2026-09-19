import { expect, test } from "bun:test";
import { createViviApp } from "@vivi/core";
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
