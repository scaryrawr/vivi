import { expect, mock, test } from "bun:test";
import type { JoinSessionConfig } from "@github/copilot-sdk/extension";

let joinConfig: JoinSessionConfig | undefined;
mock.module("@github/copilot-sdk/extension", () => ({
  joinSession: async (config: JoinSessionConfig) => {
    joinConfig = config;
    return {};
  },
}));

// @ts-expect-error Generated ESM is built before tests and has no declaration file.
await import("../../dist/extensions/vivi-system-prompt/extension.mjs");

test("applies the lightweight tool policy without checking the selected model", () => {
  expect(joinConfig?.excludedTools).toEqual([
    "builtin:task",
    "builtin:list_agents",
    "builtin:read_agent",
    "builtin:write_agent",
    "builtin:run_factory",
    "builtin:factories_manage",
  ]);
});

test("keeps project and runtime instructions but drops other SDK prompt sections", () => {
  expect(joinConfig?.systemMessage).toMatchObject({
    mode: "customize",
    sections: {
      preamble: { action: "replace" },
      identity: { action: "remove" },
      tone: { action: "remove" },
      tool_efficiency: { action: "remove" },
      environment_context: { action: "preserve" },
      code_change_rules: { action: "remove" },
      guidelines: { action: "remove" },
      safety: { action: "remove" },
      tool_instructions: { action: "replace" },
      custom_instructions: { action: "preserve" },
      runtime_instructions: { action: "preserve" },
      last_instructions: { action: "preserve" },
    },
  });
});
