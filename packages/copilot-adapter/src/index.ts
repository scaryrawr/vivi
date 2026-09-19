import { CopilotClient, type CopilotSession } from "@github/copilot-sdk";
import type { CopilotPort, CopilotPortEvent } from "@vivi/core";

export interface SdkCopilotPortOptions {
  readonly workingDirectory: string;
}

class EventQueue<T> {
  private readonly values: T[] = [];
  private readonly waiters: Array<(result: IteratorResult<T>) => void> = [];
  private ended = false;

  push(value: T): void {
    if (this.ended) return;
    const waiter = this.waiters.shift();
    if (waiter) {
      waiter({ done: false, value });
    } else {
      this.values.push(value);
    }
  }

  end(): void {
    if (this.ended) return;
    this.ended = true;
    while (this.waiters.length > 0) this.waiters.shift()?.({ done: true, value: undefined });
  }

  async next(): Promise<IteratorResult<T>> {
    const value = this.values.shift();
    if (value !== undefined) return { done: false, value };
    if (this.ended) return { done: true, value: undefined };
    return new Promise((resolve) => this.waiters.push(resolve));
  }
}

type Lifecycle = {
  readonly client: CopilotClient;
  readonly workingDirectory: string;
  session?: CopilotSession;
  startPromise?: Promise<void>;
  closePromise?: Promise<void>;
};

const errorMessage = (error: unknown): string =>
  error instanceof Error ? error.message : String(error);

const firstCleanupError = (current: Error | undefined, error: unknown): Error | undefined =>
  current ?? (error instanceof Error ? error : new Error(String(error)));

function ensureStarted(lifecycle: Lifecycle): Promise<void> {
  if (!lifecycle.startPromise) {
    lifecycle.startPromise = lifecycle.client.start();
  }
  return lifecycle.startPromise;
}

async function ensureSession(lifecycle: Lifecycle): Promise<CopilotSession> {
  await ensureStarted(lifecycle);
  if (!lifecycle.session) {
    lifecycle.session = await lifecycle.client.createSession({
      workingDirectory: lifecycle.workingDirectory,
      streaming: true,
    });
  }
  return lifecycle.session;
}

function respondWithSdk(lifecycle: Lifecycle, prompt: string): AsyncIterable<CopilotPortEvent> {
  const queue = new EventQueue<CopilotPortEvent>();
  void (async () => {
    const session = await ensureSession(lifecycle);
    let sawDelta = false;
    let responseError: string | undefined;
    let ended = false;
    const finish = (): void => {
      if (ended) return;
      ended = true;
      queue.end();
    };
    const fail = (message: string): void => {
      if (responseError === undefined) responseError = message;
      queue.push({ type: "response-failed", error: responseError });
      finish();
    };
    const unsubscribeDelta = session.on("assistant.message_delta", (event) => {
      if (ended) return;
      sawDelta = true;
      queue.push({ type: "assistant-delta", text: event.data.deltaContent });
    });
    const unsubscribeError = session.on("session.error", (event) => {
      fail(event.data.message);
    });
    try {
      const response = await session.sendAndWait({ prompt });
      if (responseError === undefined && !sawDelta && response?.data.content) {
        queue.push({ type: "assistant-delta", text: response.data.content });
      }
      if (responseError === undefined) finish();
    } catch (error) {
      fail(errorMessage(error));
    } finally {
      unsubscribeError();
      unsubscribeDelta();
      queue.end();
    }
  })().catch((error) => {
    queue.push({ type: "response-failed", error: errorMessage(error) });
    queue.end();
  });

  return {
    [Symbol.asyncIterator](): AsyncIterator<CopilotPortEvent> {
      return {
        next: () => queue.next(),
      };
    },
  };
}

function closeSdk(lifecycle: Lifecycle): Promise<void> {
  if (!lifecycle.closePromise) {
    lifecycle.closePromise = (async () => {
      let firstError: Error | undefined;
      if (lifecycle.session) {
        try {
          await lifecycle.session.abort();
        } catch (error) {
          firstError = firstCleanupError(firstError, error);
        }
        try {
          await lifecycle.session.disconnect();
        } catch (error) {
          firstError = firstCleanupError(firstError, error);
        }
      }
      try {
        const errors = await lifecycle.client.stop();
        if (errors.length > 0) firstError = firstCleanupError(firstError, errors[0]);
      } catch (error) {
        firstError = firstCleanupError(firstError, error);
      }
      if (firstError) throw firstError;
    })();
  }
  return lifecycle.closePromise;
}

export function createSdkCopilotPort(options: SdkCopilotPortOptions): CopilotPort {
  const lifecycle: Lifecycle = {
    client: new CopilotClient({ workingDirectory: options.workingDirectory }),
    workingDirectory: options.workingDirectory,
  };
  return {
    respond: (prompt) => respondWithSdk(lifecycle, prompt),
    close: () => closeSdk(lifecycle),
  };
}
