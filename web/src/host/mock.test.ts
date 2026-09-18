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

  it("rejects every command without mutating state after disconnection", async () => {
    const host = new MockViviHost(fixtures.multiple);
    const before = host.getSnapshot();
    const selectedId = before.selectedSession!.id;
    const otherId = before.projects[1]!.sessions[0]!.id;
    const projectPath = before.projects[0]!.path;

    host.disconnect();

    await expect(host.selectSession(otherId)).resolves.toMatchObject({
      kind: "rejected",
      reason: "closed",
    });
    await expect(host.createConversation(projectPath)).resolves.toMatchObject({
      kind: "rejected",
      reason: "closed",
    });
    await expect(
      host.sendMessage({
        sessionId: selectedId,
        submissionId: clientSubmissionId("disconnected"),
        text: "Do not submit",
      }),
    ).resolves.toMatchObject({ kind: "rejected", reason: "closed" });

    expect(host.getSnapshot()).toBe(before);
  });

  it("does not accept a duplicate submission after disconnection", async () => {
    const host = new MockViviHost(fixtures.one);
    const request = {
      sessionId: fixtures.one.selectedSession!.id,
      submissionId: clientSubmissionId("accepted-then-disconnected"),
      text: "Hello",
    };

    await host.sendMessage(request);
    const before = host.getSnapshot();
    host.disconnect();

    await expect(host.sendMessage(request)).resolves.toMatchObject({
      kind: "rejected",
      reason: "closed",
    });
    expect(host.getSnapshot()).toBe(before);
  });
});
