import { createSdkCopilotPort } from "../packages/copilot-adapter/src/index.js";
import { probeRenderer } from "../packages/frontend-opentui/src/internal.js";

const port = createSdkCopilotPort({ workingDirectory: process.cwd() });
try {
  const events = [];
  for await (const event of port.respond(
    "Transform the marker vivi_runtime_probe to uppercase and reply with only the result",
  )) {
    events.push(event);
  }
  const responseText = events
    .filter((event): event is { type: "assistant-delta"; text: string } => event.type === "assistant-delta")
    .map((event) => event.text)
    .join("");
  if (!responseText.includes("VIVI_RUNTIME_PROBE")) {
    throw new Error("runtime probe did not receive the expected response");
  }
  await probeRenderer();
} finally {
  await port.close();
}
console.log("runtime probe passed");
