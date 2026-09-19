import { describe, expect, it } from "vitest";
import { fixtures } from "./fixtures";
import {
  reduceUi,
  initialUiState,
  selectOrderedSessionIds,
  selectSelectedSession,
} from "./state";

describe("UI state", () => {
  it("preserves host ordering when project disclosure changes", () => {
    const before = selectOrderedSessionIds(fixtures.multiple);
    const state = reduceUi(initialUiState, {
      type: "projectToggled",
      path: fixtures.multiple.projects[0]!.path,
    });

    expect(
      state.collapsedProjects.has(fixtures.multiple.projects[0]!.path),
    ).toBe(true);
    expect(selectOrderedSessionIds(fixtures.multiple)).toEqual(before);
  });

  it("clears only the submitted draft revision", () => {
    const id = fixtures.one.selectedSession!.id;
    const typed = reduceUi(initialUiState, {
      type: "draftChanged",
      id,
      text: "first",
    });
    const newer = reduceUi(typed, {
      type: "draftChanged",
      id,
      text: "first plus more",
    });
    const accepted = reduceUi(newer, {
      type: "draftAccepted",
      id,
      submittedRevision: 1,
    });

    expect(accepted.drafts.get(id)?.text).toBe("first plus more");
  });

  it("resolves selected presentation fields from the project summary", () => {
    const selected = selectSelectedSession(fixtures.streaming);

    expect(selected?.title).toBe("Stabilize native session ordering");
    expect(selected?.lifecycle.kind).toBe("responding");
  });
});
