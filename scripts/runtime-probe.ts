import { startAndStopSdkClient } from "../packages/copilot-adapter/src/index.js";
import { createRendererProbe } from "../packages/frontend-opentui/src/index.js";

if (typeof createRendererProbe !== "function") throw new Error("OpenTUI renderer probe failed");
await startAndStopSdkClient();
console.log("runtime probe passed");
