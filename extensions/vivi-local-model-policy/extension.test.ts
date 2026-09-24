import { expect, mock, test } from "bun:test";
import type { JoinSessionConfig } from "@github/copilot-sdk/extension";
import { parseLocalModelIds } from "./model-ids.ts";

let joinConfig: JoinSessionConfig | undefined;

mock.module("@github/copilot-sdk/extension", () => ({
  joinSession: async (config: JoinSessionConfig) => {
    joinConfig = config;
    return {};
  },
}));

process.env.VIVI_LOCAL_MODEL_IDS = '["omlx/local-model"]';
process.env.VIVI_SELECTED_MODEL_ID = "omlx/local-model";
// @ts-expect-error Generated ESM is built before tests and has no declaration file.
await import("../../dist/extensions/vivi-local-model-policy/extension.mjs");

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

test("parses local IDs and rejects malformed configuration", () => {
  expect(parseLocalModelIds('["omlx/local-model"]')).toEqual(["omlx/local-model"]);
  expect(parseLocalModelIds(undefined)).toEqual([]);
  expect(() => parseLocalModelIds('["omlx/local-model", 42]')).toThrow(
    "VIVI_LOCAL_MODEL_IDS must be an array of model IDs",
  );
  expect(() => parseLocalModelIds("{")).toThrow("Invalid VIVI_LOCAL_MODEL_IDS JSON");
});
