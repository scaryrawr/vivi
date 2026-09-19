export type RequestId = string & { readonly __brand: "RequestId" };

export type Message =
  | { readonly role: "user"; readonly content: string }
  | { readonly role: "assistant"; readonly content: string };

export type InputIntent =
  | { readonly type: "submit-prompt"; readonly text: string }
  | { readonly type: "shutdown" };

export type DomainEvent =
  | { readonly type: "prompt-accepted"; readonly requestId: RequestId; readonly text: string }
  | { readonly type: "assistant-delta"; readonly requestId: RequestId; readonly text: string }
  | { readonly type: "response-completed"; readonly requestId: RequestId }
  | { readonly type: "response-failed"; readonly requestId: RequestId; readonly error: string }
  | { readonly type: "shutdown-completed" };

type AssistantMessage = Extract<Message, { readonly role: "assistant" }>;

export type AppState =
  | { readonly phase: "ready"; readonly messages: readonly Message[] }
  | {
      readonly phase: "responding";
      readonly messages: readonly Message[];
      readonly requestId: RequestId;
      readonly assistantMessage: AssistantMessage;
    }
  | { readonly phase: "failed"; readonly messages: readonly Message[]; readonly error: string }
  | { readonly phase: "shutting-down"; readonly messages: readonly Message[] }
  | { readonly phase: "stopped"; readonly messages: readonly Message[] };

export type AppViewModel =
  | { readonly phase: "ready"; readonly transcript: string }
  | { readonly phase: "responding"; readonly transcript: string }
  | { readonly phase: "failed"; readonly transcript: string; readonly error: string }
  | { readonly phase: "shutting-down"; readonly transcript: string }
  | { readonly phase: "stopped"; readonly transcript: string };

export type CoreEffect =
  | {
      readonly type: "request-response";
      readonly requestId: RequestId;
      readonly prompt: string;
    }
  | { readonly type: "stop-port" };

export type CopilotPortEvent =
  | { readonly type: "assistant-delta"; readonly text: string }
  | { readonly type: "response-failed"; readonly error: string };

export interface CopilotPort {
  respond(prompt: string): AsyncIterable<CopilotPortEvent>;
  close(): Promise<void>;
}

const unreachable = (value: never): never => {
  throw new Error(`Unhandled variant: ${JSON.stringify(value)}`);
};

export function reduce(state: AppState, event: DomainEvent): AppState {
  switch (event.type) {
    case "prompt-accepted":
      return state.phase === "ready"
        ? {
            phase: "responding",
            messages: [...state.messages, { role: "user", content: event.text }],
            requestId: event.requestId,
            assistantMessage: { role: "assistant", content: "" },
          }
        : state;
    case "assistant-delta":
      return state.phase === "responding" && state.requestId === event.requestId
        ? {
            ...state,
            assistantMessage: {
              ...state.assistantMessage,
              content: state.assistantMessage.content + event.text,
            },
          }
        : state;
    case "response-completed":
      return state.phase === "responding" && state.requestId === event.requestId
        ? { phase: "ready", messages: [...state.messages, state.assistantMessage] }
        : state;
    case "response-failed":
      return state.phase === "responding" && state.requestId === event.requestId
        ? { phase: "failed", messages: [...state.messages, state.assistantMessage], error: event.error }
        : state;
    case "shutdown-completed":
      return { phase: "stopped", messages: state.messages };
    default:
      return unreachable(event);
  }
}

export interface ViviApp {
  readonly state: AppState;
  dispatch(intent: InputIntent): Promise<void>;
  subscribe(listener: (state: AppState) => void): () => void;
  view(): AppViewModel;
  close(): Promise<void>;
}

const messageText = (message: Message): string =>
  `${message.role === "user" ? "User" : "Assistant"}: ${message.content}`;

const displayContent = (state: AppState): string => {
  const messages =
    state.phase === "responding"
      ? [...state.messages, state.assistantMessage]
      : state.messages;
  return messages.map(messageText).join("\n");
};

export function createViviApp(port: CopilotPort): ViviApp {
  let current: AppState = { phase: "ready", messages: [] };
  let nextRequest = 0;
  let closePromise: Promise<void> | undefined;
  const listeners = new Set<(state: AppState) => void>();
  const makeRequestId = (value: string): RequestId => value as RequestId;

  const publish = (event: DomainEvent): void => {
    current = reduce(current, event);
    for (const listener of listeners) listener(current);
  };

  const effectsFor = (intent: InputIntent): CoreEffect[] => {
    switch (intent.type) {
      case "submit-prompt":
        if (current.phase !== "ready") return [];
        return [
          {
            type: "request-response",
            requestId: makeRequestId(String(++nextRequest)),
            prompt: intent.text,
          },
        ];
      case "shutdown":
        return [{ type: "stop-port" }];
      default:
        return unreachable(intent);
    }
  };

  const stopPort = (): Promise<void> => {
    if (closePromise) return closePromise;

    const messages =
      current.phase === "responding"
        ? [...current.messages, current.assistantMessage]
        : current.messages;
    current = { phase: "shutting-down", messages };
    for (const listener of listeners) listener(current);

    closePromise = (async () => {
      await port.close();
      publish({ type: "shutdown-completed" });
    })();
    return closePromise;
  };

  const dispatch = async (intent: InputIntent): Promise<void> => {
    for (const effect of effectsFor(intent)) {
      switch (effect.type) {
        case "request-response":
          publish({ type: "prompt-accepted", requestId: effect.requestId, text: effect.prompt });
          try {
            for await (const event of port.respond(effect.prompt)) {
              publish(
                event.type === "assistant-delta"
                  ? { type: event.type, requestId: effect.requestId, text: event.text }
                  : { type: event.type, requestId: effect.requestId, error: event.error },
              );
            }
            if (current.phase === "responding" && current.requestId === effect.requestId) {
              publish({ type: "response-completed", requestId: effect.requestId });
            }
          } catch (error) {
            publish({
              type: "response-failed",
              requestId: effect.requestId,
              error: error instanceof Error ? error.message : String(error),
            });
          }
          break;
        case "stop-port":
          await stopPort();
          break;
        default:
          unreachable(effect);
      }
    }
  };

  return {
    get state() {
      return current;
    },
    dispatch,
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    view() {
      const transcript = displayContent(current);
      return current.phase === "failed"
        ? { phase: current.phase, transcript, error: current.error }
        : { phase: current.phase, transcript };
    },
    close: () => dispatch({ type: "shutdown" }),
  };
}
