import {
  createCliRenderer,
  InputRenderable,
  TextRenderable,
} from "@opentui/core";
import type { ViviApp } from "@vivi/core";
import { runChatLifecycle } from "./internal.js";

export interface ChatRunOptions {
  readonly app: ViviApp;
  readonly forceExit: (code: number) => never;
}

export async function runChat({ app, forceExit }: ChatRunOptions): Promise<void> {
  return runChatLifecycle({
    app,
    forceExit,
    createRenderer: async () => {
      const renderer = await createCliRenderer({
        clearOnShutdown: false,
        exitOnCtrlC: false,
        exitSignals: [],
        useKittyKeyboard: null,
        useMouse: false,
      });
      const transcript = new TextRenderable(renderer, { content: "" });
      const input = new InputRenderable(renderer, { placeholder: "Ask Vivi..." });
      renderer.root.add(transcript);
      renderer.root.add(input);
      return {
        transcript,
        input,
        keyInput: renderer.keyInput,
        requestRender: () => renderer.requestRender(),
        start: () => renderer.start(),
        destroy: () => renderer.destroy(),
      };
    },
  });
}
