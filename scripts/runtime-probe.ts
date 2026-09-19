import { startAndStopSdkClient } from "../packages/copilot-adapter/src/index.js";
import { startAndStopRenderer } from "../packages/frontend-opentui/src/index.js";

await startAndStopSdkClient();
await startAndStopRenderer();
console.log("runtime probe passed");
