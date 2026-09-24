import { joinSession } from "@github/copilot-sdk/extension";

await joinSession({
  excludedTools: [
    "builtin:task",
    "builtin:list_agents",
    "builtin:read_agent",
    "builtin:write_agent",
    "builtin:run_factory",
    "builtin:factories_manage",
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
