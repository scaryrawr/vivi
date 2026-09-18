import type {
  HostSnapshot,
  SessionId,
  TranscriptItemId,
  WorkspacePath,
} from "./host/contract";

export interface DraftState {
  readonly text: string;
  readonly revision: number;
}

export interface UiState {
  readonly collapsedProjects: ReadonlySet<WorkspacePath>;
  readonly disclosedItems: ReadonlySet<TranscriptItemId>;
  readonly drafts: ReadonlyMap<SessionId, DraftState>;
}

export type UiAction =
  | { readonly type: "projectToggled"; readonly path: WorkspacePath }
  | { readonly type: "transcriptToggled"; readonly id: TranscriptItemId }
  | {
      readonly type: "draftChanged";
      readonly id: SessionId;
      readonly text: string;
    }
  | {
      readonly type: "draftAccepted";
      readonly id: SessionId;
      readonly submittedRevision: number;
    };

export const initialUiState: UiState = {
  collapsedProjects: new Set(),
  disclosedItems: new Set(),
  drafts: new Map(),
};

const toggled = <T>(values: ReadonlySet<T>, value: T) => {
  const next = new Set(values);
  if (next.has(value)) next.delete(value);
  else next.add(value);
  return next;
};

export function reduceUi(state: UiState, action: UiAction): UiState {
  switch (action.type) {
    case "projectToggled":
      return {
        ...state,
        collapsedProjects: toggled(state.collapsedProjects, action.path),
      };
    case "transcriptToggled":
      return {
        ...state,
        disclosedItems: toggled(state.disclosedItems, action.id),
      };
    case "draftChanged": {
      const drafts = new Map(state.drafts);
      const previous = drafts.get(action.id);
      drafts.set(action.id, {
        text: action.text,
        revision: (previous?.revision ?? 0) + 1,
      });
      return { ...state, drafts };
    }
    case "draftAccepted": {
      const current = state.drafts.get(action.id);
      if (!current || current.revision !== action.submittedRevision)
        return state;
      const drafts = new Map(state.drafts);
      drafts.set(action.id, { text: "", revision: current.revision + 1 });
      return { ...state, drafts };
    }
  }
}

export function selectOrderedSessionIds(
  snapshot: HostSnapshot,
): readonly SessionId[] {
  return snapshot.projects.flatMap((project) =>
    project.sessions.map((session) => session.id),
  );
}

export function selectDraft(state: UiState, id: SessionId): DraftState {
  return state.drafts.get(id) ?? { text: "", revision: 0 };
}

export function selectCanSend(snapshot: HostSnapshot, state: UiState): boolean {
  const selected = snapshot.selectedSession;
  if (!selected || selected.lifecycle.kind !== "idle") return false;
  return selectDraft(state, selected.id).text.trim().length > 0;
}
