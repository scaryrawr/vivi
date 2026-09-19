import {
  createCliRenderer,
  InputRenderable,
  InputRenderableEvents,
  TextRenderable,
} from "@opentui/core";
import type { ViviApp } from "@vivi/core";

export interface ChatRunOptions {
  readonly app: ViviApp;
}

type CtrlCState = { requested: boolean };

const isCtrlC = (key: { readonly name: string; readonly ctrl: boolean }): boolean =>
  key.ctrl && key.name === "c";

const render = (app: ViviApp, transcript: TextRenderable): void => {
  const view = app.view();
  transcript.content =
    view.phase === "failed" ? `${view.transcript}\n\nError: ${view.error}` : view.transcript;
};

export async function runChat({ app }: ChatRunOptions): Promise<void> {
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
  const ctrlC: CtrlCState = { requested: false };
  let firstError: unknown;
  let resolveStopped!: () => void;
  const stopped = new Promise<void>((resolve) => {
    resolveStopped = resolve;
  });
  const unsubscribe = app.subscribe((state) => {
    render(app, transcript);
    renderer.requestRender();
    if (state.phase === "stopped") resolveStopped();
  });
  const onEnter = (value: string): void => {
    const prompt = value.trim();
    if (prompt.length === 0) return;
    input.value = "";
    void app.dispatch({ type: "submit-prompt", text: prompt }).catch((error) => {
      firstError ??= error;
    });
  };
  const onKeypress = (key: { readonly name: string; readonly ctrl: boolean }): void => {
    if (!isCtrlC(key)) return;
    if (ctrlC.requested) {
      process.exit(130);
    }
    ctrlC.requested = true;
    void app.close().catch((error) => {
      firstError ??= error;
      resolveStopped();
    });
  };
  input.on(InputRenderableEvents.ENTER, onEnter);
  renderer.keyInput.on("keypress", onKeypress);
  render(app, transcript);
  renderer.start();
  try {
    await stopped;
  } finally {
    unsubscribe();
    try {
      await app.close();
    } catch (error) {
      firstError ??= error;
    }
    renderer.keyInput.off("keypress", onKeypress);
    input.off(InputRenderableEvents.ENTER, onEnter);
    renderer.destroy();
  }
  if (firstError) throw firstError;
}
