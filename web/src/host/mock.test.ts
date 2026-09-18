import { describe, expect, it, vi } from "vitest";
import { fixtures } from "../fixtures";
import { clientSubmissionId } from "./contract";
import { MockViviHost } from "./mock";

describe("MockViviHost", () => {
  it("changes selection without changing host order", async () => {
    const host = new MockViviHost(fixtures.multiple);
    const before = host
      .getSnapshot()
      .projects.flatMap((project) =>
        project.sessions.map((session) => session.id),
      );
    const target = fixtures.multiple.projects[1]!.sessions[0]!.id;

    await host.selectSession(target);

    expect(host.getSnapshot().selectedSessionId).toBe(target);
    expect(
      host
        .getSnapshot()
        .projects.flatMap((project) =>
          project.sessions.map((session) => session.id),
        ),
    ).toEqual(before);
  });

  it("deduplicates accepted submission identifiers", async () => {
    const host = new MockViviHost(fixtures.one);
    const listener = vi.fn();
    host.subscribe(listener);
    const request = {
      sessionId: fixtures.one.selectedSessionId!,
      submissionId: clientSubmissionId("repeatable"),
      text: "Hello",
    };

    await host.sendMessage(request);
    await host.sendMessage(request);

    expect(listener).toHaveBeenCalledTimes(1);
  });
});
