import { createCliRenderer, type CliRenderer } from "@opentui/core";

export async function createRendererProbe(): Promise<CliRenderer> {
  return createCliRenderer({
    bufferedOutput: "memory",
    clearOnShutdown: false,
    exitOnCtrlC: false,
    exitSignals: [],
    height: 24,
    useKittyKeyboard: null,
    useMouse: false,
    width: 80,
  });
}

export async function startAndStopRenderer(): Promise<void> {
  const renderer = await createRendererProbe();
  renderer.destroy();
}
