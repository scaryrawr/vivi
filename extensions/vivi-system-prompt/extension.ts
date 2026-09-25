import { joinSession } from "@github/copilot-sdk/extension";

await joinSession({
  excludedTools: [
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
  ],
  systemMessage: {
    mode: "customize",
    sections: {
      preamble: {
        action: "replace",
        content:
          "You are GitHub Copilot configured by Vivi, a focused coding agent. " +
          "Inspect relevant repository files before changing them. Follow the user's request " +
          "and project instructions, make the smallest correct change, preserve existing " +
          "behavior unless asked to change it, run relevant checks, and report results concisely.",
      },
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
  },
});
