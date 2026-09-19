import { createSdkCopilotPort } from "../packages/copilot-adapter/src/index.js";
import { probeRenderer } from "../packages/frontend-opentui/src/internal.js";

const port = createSdkCopilotPort({ workingDirectory: process.cwd() });
const events = [];
for await (const event of port.respond("Reply with exactly RUNTIME_PROBE_OK")) {
  events.push(event);
}
const responseText = events
  .filter((event): event is { type: "assistant-delta"; text: string } => event.type === "assistant-delta")
  .map((event) => event.text)
  .join("");
if (!responseText.includes("RUNTIME_PROBE_OK")) {
  throw new Error("runtime probe did not receive the expected response");
}
await port.close();
await probeRenderer();
console.log("runtime probe passed");
