import { expect, mock, test } from "bun:test";
import type { JoinSessionConfig } from "@github/copilot-sdk/extension";

let joinConfig: JoinSessionConfig | undefined;

mock.module("@github/copilot-sdk/extension", () => ({
  joinSession: async (config: JoinSessionConfig) => {
    joinConfig = config;
    return {};
  },
}));

process.env.VIVI_LOCAL_MODEL_IDS = '["omlx/local-model"]';
process.env.VIVI_SELECTED_MODEL_ID = "omlx/local-model";
await import("./extension.mjs");

test("declares local-model built-in exclusions when joining the session", () => {
  expect(joinConfig?.hooks).toBeUndefined();
  expect(joinConfig?.excludedTools).toEqual([
    "builtin:task",
    "builtin:list_agents",
    "builtin:read_agent",
    "builtin:write_agent",
    "builtin:run_factory",
    "builtin:factories_manage",
  ]);
});
