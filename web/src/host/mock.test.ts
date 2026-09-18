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

    expect(host.getSnapshot().selectedSession?.id).toBe(target);
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
      sessionId: fixtures.one.selectedSession!.id,
      submissionId: clientSubmissionId("repeatable"),
      text: "Hello",
    };

    await host.sendMessage(request);
    await host.sendMessage(request);

    expect(listener).toHaveBeenCalledTimes(1);
  });

  it("preserves a session transcript across selection changes", async () => {
    const host = new MockViviHost(fixtures.multiple);
    const originalId = fixtures.multiple.selectedSession!.id;
    const otherId = fixtures.multiple.projects[1]!.sessions[0]!.id;
    await host.sendMessage({
      sessionId: originalId,
      submissionId: clientSubmissionId("preserve-transcript"),
      text: "Keep this message",
    });

    await host.selectSession(otherId);
    await host.selectSession(originalId);

    expect(host.getSnapshot().selectedSession?.transcript.at(-2)).toMatchObject(
      {
        kind: "user",
        text: "Keep this message",
      },
    );
  });

  it("publishes disconnection before removing subscribers", () => {
    const host = new MockViviHost(fixtures.one);
    const states: string[] = [];
    host.subscribe(() => states.push(host.getConnectionState().kind));

    host.disconnect();

    expect(states).toEqual(["disconnected"]);
  });
});
