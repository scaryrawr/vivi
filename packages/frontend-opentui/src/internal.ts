import type { AppState, AppViewModel, ViviApp } from "@vivi/core";
import { createCliRenderer } from "@opentui/core";

export interface RendererInput {
  value: string;
  focus(): void;
  on(event: string, handler: (value: string) => void): void;
  off(event: string, handler: (value: string) => void): void;
}

export interface RendererKeyInput {
  on(event: "keypress", handler: (key: { readonly name: string; readonly ctrl: boolean }) => void): void;
  off(event: "keypress", handler: (key: { readonly name: string; readonly ctrl: boolean }) => void): void;
}

export interface ChatRenderer {
  readonly transcript: { content: unknown };
  readonly input: RendererInput;
  readonly keyInput: RendererKeyInput;
  requestRender(): void;
  start(): void;
  destroy(): void;
}

export interface ChatLifecycleOptions {
  readonly app: ViviApp;
  readonly forceExit: (code: number) => never;
  readonly createRenderer: () => Promise<ChatRenderer>;
}

const isCtrlC = (key: { readonly name: string; readonly ctrl: boolean }): boolean =>
  key.ctrl && key.name === "c";

const render = (app: ViviApp, transcript: { content: unknown }): void => {
  const view: AppViewModel = app.view();
  transcript.content =
    view.phase === "failed" ? `${view.transcript}\n\nError: ${view.error}` : view.transcript;
};

export async function runChatLifecycle({
  app,
  forceExit,
  createRenderer,
}: ChatLifecycleOptions): Promise<void> {
  const renderer = await createRenderer();
  const ctrlC = { requested: false };
  let firstError: unknown;
  let resolveStopped!: () => void;
  const stopped = new Promise<void>((resolve) => {
    resolveStopped = resolve;
  });
  const unsubscribe = app.subscribe((state: AppState) => {
    render(app, renderer.transcript);
    renderer.requestRender();
    if (state.phase === "stopped") resolveStopped();
  });
  const onEnter = (value: string): void => {
    const prompt = value.trim();
    if (prompt.length === 0) return;
    renderer.input.value = "";
    void app.dispatch({ type: "submit-prompt", text: prompt }).catch((error) => {
      firstError ??= error;
    });
  };
  const onKeypress = (key: { readonly name: string; readonly ctrl: boolean }): void => {
    if (!isCtrlC(key)) return;
    if (ctrlC.requested) {
      renderer.destroy();
      forceExit(130);
    }
    ctrlC.requested = true;
    void app.close().catch((error) => {
      firstError ??= error;
      resolveStopped();
    });
  };
  renderer.input.on("enter", onEnter);
  renderer.keyInput.on("keypress", onKeypress);
  renderer.input.focus();
  try {
    render(app, renderer.transcript);
    renderer.start();
    await stopped;
  } finally {
    unsubscribe();
    try {
      await app.close();
    } catch (error) {
      firstError ??= error;
    }
    renderer.keyInput.off("keypress", onKeypress);
    renderer.input.off("enter", onEnter);
    renderer.destroy();
  }
  if (firstError) throw firstError;
}

export async function probeRenderer(): Promise<void> {
  const renderer = await createCliRenderer({
    clearOnShutdown: false,
    exitOnCtrlC: false,
    exitSignals: [],
    useKittyKeyboard: null,
    useMouse: false,
  });
  renderer.start();
  renderer.destroy();
}
