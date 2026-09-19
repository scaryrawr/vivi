import { createSdkCopilotPort } from "../packages/copilot-adapter/src/index.js";

const port = createSdkCopilotPort({ workingDirectory: process.cwd() });
await port.close();
console.log("runtime probe passed");
