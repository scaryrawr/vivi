import {
  useMemo,
  useReducer,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import Markdown from "react-markdown";
import type {
  Appearance,
  ConnectedViviHost,
  HostCommandResult,
  SessionId,
  TranscriptItem,
  WorkspacePath,
} from "./host/contract";
import { createClientSubmissionId } from "./host/contract";
import {
  initialUiState,
  reduceUi,
  selectCanSend,
  selectDraft,
  selectOrderedSessionIds,
} from "./state";
import "./styles.css";

export interface ViviAppProps {
  readonly host: ConnectedViviHost;
  readonly appearance?: Appearance;
  readonly initiallyCollapsed?: readonly WorkspacePath[];
}

const displayTitle = (title: string) => title.trim() || "New conversation";

export function ViviApp({
  host,
  appearance = "light",
  initiallyCollapsed = [],
}: ViviAppProps) {
  const snapshot = useSyncExternalStore(
    host.subscribe.bind(host),
    host.getSnapshot.bind(host),
    host.getSnapshot.bind(host),
  );
  const connectionState = useSyncExternalStore(
    host.subscribe.bind(host),
    host.getConnectionState.bind(host),
    host.getConnectionState.bind(host),
  );
  const [ui, dispatch] = useReducer(reduceUi, {
    ...initialUiState,
    collapsedProjects: new Set(initiallyCollapsed),
  });
  const [commandError, setCommandError] = useState<string | null>(null);
  const [sendPending, setSendPending] = useState(false);
  const sendPendingRef = useRef(false);
  const sessionIds = useMemo(
    () => selectOrderedSessionIds(snapshot),
    [snapshot],
  );
  const selected = snapshot.selectedSession;
  const draft = selected ? selectDraft(ui, selected.id) : null;
  const canSend =
    connectionState.kind === "connected" &&
    selectCanSend(snapshot, ui) &&
    !sendPending;
  const sidebarRef = useRef<HTMLElement>(null);

  const handleResult = (result: HostCommandResult) => {
    if (result.kind === "rejected") setCommandError(result.message);
    else setCommandError(null);
    return result;
  };

  const selectSession = async (id: SessionId) => {
    setCommandError(null);
    handleResult(await host.selectSession(id));
  };

  const createConversation = async (path: WorkspacePath) => {
    setCommandError(null);
    handleResult(await host.createConversation(path));
  };

  const send = async () => {
    if (!selected || !draft || !canSend || sendPendingRef.current) return;
    sendPendingRef.current = true;
    setSendPending(true);
    const submittedRevision = draft.revision;
    try {
      const result = handleResult(
        await host.sendMessage({
          sessionId: selected.id,
          submissionId: createClientSubmissionId(),
          text: draft.text.trim(),
        }),
      );
      if (result.kind === "accepted") {
        dispatch({ type: "draftAccepted", id: selected.id, submittedRevision });
      }
    } finally {
      sendPendingRef.current = false;
      setSendPending(false);
    }
  };

  const handleSidebarKey = (event: React.KeyboardEvent) => {
    if (!["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) return;
    const rows = Array.from(
      sidebarRef.current?.querySelectorAll<HTMLButtonElement>(
        "[data-session-row]",
      ) ?? [],
    );
    if (!rows.length) return;
    event.preventDefault();
    const current = rows.indexOf(document.activeElement as HTMLButtonElement);
    const next =
      event.key === "Home"
        ? 0
        : event.key === "End"
          ? rows.length - 1
          : event.key === "ArrowDown"
            ? Math.min((current < 0 ? -1 : current) + 1, rows.length - 1)
            : Math.max((current < 0 ? rows.length : current) - 1, 0);
    rows[next]?.focus();
  };

  return (
    <main className="vivi-app" data-appearance={appearance}>
      <aside
        className="sidebar"
        aria-label="Projects and conversations"
        ref={sidebarRef}
        onKeyDown={handleSidebarKey}
      >
        <div className="sidebar-titlebar">
          <div className="app-mark" aria-hidden="true">
            V
          </div>
          <div>
            <strong>Vivi</strong>
            <span>Project conversations</span>
          </div>
        </div>

        <div className="project-list">
          {snapshot.projects.map((project) => {
            const collapsed = ui.collapsedProjects.has(project.path);
            return (
              <section className="project" key={project.path}>
                <button
                  className="project-heading"
                  type="button"
                  aria-expanded={!collapsed}
                  onClick={() =>
                    dispatch({ type: "projectToggled", path: project.path })
                  }
                  title={project.path}
                >
                  <span className="disclosure" aria-hidden="true">
                    {collapsed ? "›" : "⌄"}
                  </span>
                  <span className="project-label">
                    <strong>{project.displayName}</strong>
                    <span>{project.path}</span>
                  </span>
                </button>
                {!collapsed && (
                  <div
                    className="session-list"
                    aria-label={`${project.displayName} conversations`}
                  >
                    {project.sessions.map((session) => {
                      const isSelected = session.id === selected?.id;
                      return (
                        <button
                          type="button"
                          data-session-row
                          className="session-row"
                          aria-current={isSelected ? "page" : undefined}
                          key={session.id}
                          onClick={() => void selectSession(session.id)}
                        >
                          <span className="session-title">
                            {displayTitle(session.title)}
                          </span>
                          <LifecycleStatus lifecycle={session.lifecycle.kind} />
                        </button>
                      );
                    })}
                    <button
                      className="new-conversation"
                      type="button"
                      onClick={() => void createConversation(project.path)}
                    >
                      <span aria-hidden="true">＋</span> New conversation
                    </button>
                  </div>
                )}
              </section>
            );
          })}
          {!snapshot.projects.length && (
            <div className="sidebar-empty">
              <strong>No projects yet</strong>
              <span>A native host will add projects here.</span>
            </div>
          )}
        </div>
      </aside>

      <section className="workspace" aria-label="Conversation">
        <header className="toolbar">
          <div className="toolbar-title">
            <strong>
              {selected
                ? displayTitle(selected.title)
                : "No conversation selected"}
            </strong>
            <span>
              {selected?.activeWorkspace ??
                "Choose a project conversation to begin."}
            </span>
          </div>
          {selected && <LifecyclePill lifecycle={selected.lifecycle.kind} />}
        </header>

        {(snapshot.applicationError ||
          commandError ||
          connectionState.kind !== "connected") && (
          <div className="status-region">
            {snapshot.applicationError && (
              <div className="application-error" role="alert">
                <strong>Host connection issue</strong>
                <span>{snapshot.applicationError.message}</span>
              </div>
            )}
            {connectionState.kind !== "connected" && (
              <div className="connection-error" role="alert">
                <strong>
                  {connectionState.kind === "failed"
                    ? "Host bridge failed"
                    : "Host bridge disconnected"}
                </strong>
                {connectionState.kind === "failed" && (
                  <span>{connectionState.message}</span>
                )}
              </div>
            )}
            {commandError && (
              <div className="command-error" role="alert">
                <strong>Command not completed</strong>
                <span>{commandError}</span>
              </div>
            )}
          </div>
        )}

        {selected ? (
          <>
            <div
              className="transcript"
              aria-live="polite"
              aria-busy={selected.lifecycle.kind === "responding"}
            >
              {selected.transcript.length ? (
                selected.transcript.map((item) => (
                  <TranscriptRow
                    item={item}
                    disclosed={ui.disclosedItems.has(item.id)}
                    onToggle={() =>
                      dispatch({ type: "transcriptToggled", id: item.id })
                    }
                    key={item.id}
                  />
                ))
              ) : (
                <div className="conversation-empty">
                  <div className="empty-symbol" aria-hidden="true">
                    ✦
                  </div>
                  <h1>Start with the work in front of you.</h1>
                  <p>
                    Ask about this project, inspect a failure, or continue a
                    decision. Vivi keeps the conversation attached to its
                    workspace.
                  </p>
                </div>
              )}
            </div>

            <div className="composer-zone">
              {selected.error && (
                <div className="composer-error" role="alert">
                  {selected.error.message}
                </div>
              )}
              <form
                className="composer"
                onSubmit={(event) => {
                  event.preventDefault();
                  void send();
                }}
              >
                <textarea
                  aria-label="Message"
                  placeholder="Ask Vivi about this project…"
                  value={draft?.text ?? ""}
                  disabled={selected.lifecycle.kind !== "idle" || sendPending}
                  rows={3}
                  onChange={(event) =>
                    dispatch({
                      type: "draftChanged",
                      id: selected.id,
                      text: event.currentTarget.value,
                    })
                  }
                  onKeyDown={(event) => {
                    if (
                      event.key === "Enter" &&
                      (event.metaKey || event.ctrlKey)
                    ) {
                      event.preventDefault();
                      void send();
                    }
                  }}
                />
                <div className="composer-footer">
                  <span>⌘↵ to send</span>
                  <button
                    type="submit"
                    disabled={!canSend}
                    aria-label="Send message"
                  >
                    <span aria-hidden="true">{sendPending ? "…" : "↑"}</span>
                  </button>
                </div>
              </form>
            </div>
          </>
        ) : (
          <div className="no-selection">
            <div className="empty-symbol" aria-hidden="true">
              V
            </div>
            <h1>Choose a conversation</h1>
            <p>Your projects and conversations stay in host-provided order.</p>
          </div>
        )}
      </section>
      <span className="sr-only">Session count: {sessionIds.length}</span>
    </main>
  );
}

function TranscriptRow({
  item,
  disclosed,
  onToggle,
}: {
  readonly item: TranscriptItem;
  readonly disclosed: boolean;
  readonly onToggle: () => void;
}) {
  switch (item.kind) {
    case "user":
      return <div className="user-message">{item.text}</div>;
    case "assistant":
      return (
        <article className="assistant-message">
          <div className="speaker">Vivi</div>
          <Markdown>{item.markdown}</Markdown>
          {item.streaming && (
            <span className="streaming-caret" aria-label="Response streaming" />
          )}
        </article>
      );
    case "reasoning":
      return (
        <Disclosure
          title={item.streaming ? "Reasoning…" : "Reasoning"}
          disclosed={disclosed}
          onToggle={onToggle}
          className="reasoning"
        >
          <p>{item.text}</p>
        </Disclosure>
      );
    case "tool":
      return (
        <Disclosure
          title={item.title}
          detail={item.detail}
          status={item.state}
          disclosed={disclosed}
          onToggle={onToggle}
          className="tool-activity"
        >
          {item.input && (
            <div className="tool-block">
              <strong>Input</strong>
              <pre>{item.input}</pre>
            </div>
          )}
          {item.output && (
            <div className="tool-block">
              <strong>Output</strong>
              <pre>{item.output}</pre>
            </div>
          )}
        </Disclosure>
      );
    case "status":
      return <div className="status-row">{item.text}</div>;
    case "error":
      return (
        <div className="transcript-error" role="alert">
          <strong>{item.message}</strong>
          {item.recovery && <span>{item.recovery}</span>}
        </div>
      );
  }
}

function Disclosure({
  title,
  detail,
  status,
  disclosed,
  onToggle,
  className,
  children,
}: React.PropsWithChildren<{
  readonly title: string;
  readonly detail?: string;
  readonly status?: string;
  readonly disclosed: boolean;
  readonly onToggle: () => void;
  readonly className: string;
}>) {
  return (
    <section className={`activity ${className}`}>
      <button type="button" aria-expanded={disclosed} onClick={onToggle}>
        <span className="activity-disclosure" aria-hidden="true">
          {disclosed ? "⌄" : "›"}
        </span>
        <span className="activity-copy">
          <strong>{title}</strong>
          {detail && <span>{detail}</span>}
        </span>
        {status && (
          <span className={`activity-status ${status}`}>{status}</span>
        )}
      </button>
      {disclosed && <div className="activity-detail">{children}</div>}
    </section>
  );
}

function LifecycleStatus({ lifecycle }: { readonly lifecycle: string }) {
  if (lifecycle === "idle") return null;
  const label =
    lifecycle === "responding"
      ? "Responding"
      : lifecycle === "starting"
        ? "Starting"
        : lifecycle === "closing"
          ? "Closing"
          : lifecycle === "closed"
            ? "Closed"
            : "Failed";
  return <span className={`lifecycle-status ${lifecycle}`}>{label}</span>;
}

function LifecyclePill({ lifecycle }: { readonly lifecycle: string }) {
  const label =
    lifecycle === "idle"
      ? "Ready"
      : lifecycle === "responding"
        ? "Responding"
        : lifecycle;
  return <span className={`lifecycle-pill ${lifecycle}`}>{label}</span>;
}
