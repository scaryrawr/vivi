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
    "builtin:fetch_copilot_cli_documentation",
    "builtin:context_board",
    "builtin:create_pull_request",
    "builtin:read_inbox",
    "builtin:reply_to_comment",
    "builtin:manage_schedule",
    "builtin:apply_patch",
    "builtin:str_replace_editor",
    "builtin:send_inbox",
    "builtin:sql",
    "builtin:session_store_sql",
    "builtin:task_complete",
    "builtin:update_todo",
    "builtin:grep",
    "builtin:glob",
  ]);
  expect(joinConfig?.availableTools).toBeUndefined();
  const excludedTools = joinConfig?.excludedTools;
  if (!Array.isArray(excludedTools)) throw new Error("expected excluded tool names");
  const names: string[] = excludedTools;
  expect(names.every((name) => name.startsWith("builtin:"))).toBe(true);
  for (const name of ["ask_user", "skill", "web_fetch", "view", "bash", "edit", "create"]) {
    expect(names).not.toContain(`builtin:${name}`);
  }
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
      tool_instructions: { action: "remove" },
      custom_instructions: { action: "preserve" },
      runtime_instructions: { action: "preserve" },
      last_instructions: { action: "preserve" },
    },
  });
});
