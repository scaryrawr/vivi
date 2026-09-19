import { expect, test } from "bun:test";
import type { AppState, AppViewModel, RequestId, ViviApp } from "@vivi/core";
import {
  runChatLifecycle,
  type ChatRenderer,
  type RendererInput,
  type RendererKeyInput,
} from "./internal.js";

type Key = { readonly name: string; readonly ctrl: boolean };

class FakeInput implements RendererInput {
  value = "";
  focused = false;
  private handler?: (value: string) => void;
  on(_event: string, handler: (value: string) => void): void {
    this.handler = handler;
  }
  off(_event: string, handler: (value: string) => void): void {
    if (this.handler === handler) this.handler = undefined;
  }
  emit(value: string): void {
    this.value = value;
    this.handler?.(value);
  }
  focus(): void {
    this.focused = true;
  }
}

class FakeKeyInput implements RendererKeyInput {
  private handler?: (key: Key) => void;
  on(_event: "keypress", handler: (key: Key) => void): void {
    this.handler = handler;
  }
  off(_event: "keypress", handler: (key: Key) => void): void {
    if (this.handler === handler) this.handler = undefined;
  }
  emit(key: Key): void {
    this.handler?.(key);
  }
}

class FakeApp implements ViviApp {
  state: AppState = { phase: "ready", messages: [] };
  dispatches: string[] = [];
  closeCalls = 0;
  private readonly listeners = new Set<(state: AppState) => void>();
  private closePromise: Promise<void> | undefined;
  private releaseClose: (() => void) | undefined;
  constructor(private readonly rejectClose = false, private readonly blockClose = false) {}
  dispatch = async (intent: { type: "submit-prompt"; text: string } | { type: "shutdown" }): Promise<void> => {
    if (intent.type === "submit-prompt") {
      this.dispatches.push(intent.text);
      this.state = {
        phase: "responding",
        messages: [{ role: "user", content: intent.text }],
        requestId: "1" as RequestId,
        assistantMessage: { role: "assistant", content: "" },
      };
      this.publish();
    }
  };
  subscribe(listener: (state: AppState) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }
  view(): AppViewModel {
    switch (this.state.phase) {
      case "responding":
        return { phase: "responding", transcript: "User: " + this.state.messages[0]?.content };
      case "failed":
        return { phase: "failed", transcript: "", error: this.state.error };
      default:
        return { phase: this.state.phase, transcript: "" };
    }
  }
  close = (): Promise<void> => {
    this.closeCalls += 1;
    if (!this.closePromise) {
      this.closePromise = new Promise<void>((resolve, reject) => {
        this.releaseClose = () => {
          if (this.rejectClose) reject(new Error("close failed"));
          else {
            this.state = { phase: "stopped", messages: [] };
            this.publish();
            resolve();
          }
        };
        if (!this.blockClose) this.releaseClose?.();
      });
    }
    return this.closePromise;
  };
  release(): void {
    this.releaseClose?.();
  }
  private publish(): void {
    for (const listener of this.listeners) listener(this.state);
  }
}

function makeRenderer(): {
  readonly renderer: ChatRenderer;
  readonly input: FakeInput;
  readonly keys: FakeKeyInput;
  readonly counts: { renders: number; starts: number; destroys: number };
} {
  const input = new FakeInput();
  const keys = new FakeKeyInput();
  const counts = { renders: 0, starts: 0, destroys: 0 };
  return {
    input,
    keys,
    counts,
    renderer: {
      transcript: { content: "" },
      input,
      keyInput: keys,
      requestRender: () => counts.renders++,
      start: () => counts.starts++,
      destroy: () => {
        if (counts.destroys === 0) counts.destroys++;
      },
    },
  };
}

test("dispatches trimmed Enter input, clears the input, and renders state updates", async () => {
  const app = new FakeApp();
  const { renderer, input, keys, counts } = makeRenderer();
  const run = runChatLifecycle({
    app,
    forceExit: (code): never => {
      throw new Error(`unexpected force exit ${code}`);
    },
    createRenderer: async () => renderer,
  });
  await Promise.resolve();
  input.emit("  hello  ");
  expect(app.dispatches).toEqual(["hello"]);
  expect(input.value).toBe("");
  expect(counts.starts).toBe(1);
  expect(input.focused).toBe(true);
  expect(counts.renders).toBeGreaterThan(0);
  expect(renderer.transcript.content).toBe("User: hello");
  keys.emit({ name: "c", ctrl: true });
  app.release();
  await run;
});

test("first Ctrl-C starts cooperative close and second Ctrl-C forces exit immediately", async () => {
  const app = new FakeApp(false, true);
  const { renderer, keys, counts } = makeRenderer();
  let forced = 0;
  const run = runChatLifecycle({
    app,
    forceExit: (code): never => {
      forced = code;
      throw new Error("forced");
    },
    createRenderer: async () => renderer,
  });
  await Promise.resolve();
  keys.emit({ name: "c", ctrl: true });
  expect(app.closeCalls).toBe(1);
  expect(forced).toBe(0);
  expect(() => keys.emit({ name: "c", ctrl: true })).toThrow("forced");
  expect(forced).toBe(130);
  expect(counts.destroys).toBe(1);
  app.release();
  await run;
  expect(counts.destroys).toBe(1);
});

test("destroys the renderer when app close rejects", async () => {
  const app = new FakeApp(true);
  const { renderer, keys, counts } = makeRenderer();
  const run = runChatLifecycle({
    app,
    forceExit: (code): never => {
      throw new Error(`unexpected force exit ${code}`);
    },
    createRenderer: async () => renderer,
  });
  await Promise.resolve();
  keys.emit({ name: "c", ctrl: true });
  app.release();
  await expect(run).rejects.toThrow("close failed");
  expect(counts.destroys).toBe(1);
});
