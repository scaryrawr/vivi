import { joinSession } from "@github/copilot-sdk/extension";
import { parseLocalModelIds } from "./model-ids.ts";

const LOCAL_MODEL_EXCLUDED_TOOLS = [
  "builtin:task",
  "builtin:list_agents",
  "builtin:read_agent",
  "builtin:write_agent",
  "builtin:run_factory",
  "builtin:factories_manage",
];

const localModelIds = new Set(parseLocalModelIds(process.env.VIVI_LOCAL_MODEL_IDS));
const selectedModelId = process.env.VIVI_SELECTED_MODEL_ID;
const localModelActive = selectedModelId !== undefined && localModelIds.has(selectedModelId);

await joinSession({
  excludedTools: localModelActive ? LOCAL_MODEL_EXCLUDED_TOOLS : [],
});
