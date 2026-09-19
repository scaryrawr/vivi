import { CopilotClient } from "@github/copilot-sdk";

export function createSdkClient(): CopilotClient {
  return new CopilotClient();
}

export async function startAndStopSdkClient(): Promise<void> {
  const client = createSdkClient();
  await client.start();
  await client.stop();
}
