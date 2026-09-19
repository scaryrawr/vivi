import { createCliRenderer, type CliRenderer } from "@opentui/core";

export async function createRendererProbe(): Promise<CliRenderer> {
  return createCliRenderer();
}
