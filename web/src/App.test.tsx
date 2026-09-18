import {
  act,
  cleanup,
  fireEvent,
  render,
  screen,
} from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ViviApp } from "./App";
import { fixtures } from "./fixtures";
import { MockViviHost } from "./host/mock";

afterEach(cleanup);

describe("ViviApp", () => {
  it("preserves the draft but disables sending after disconnection", () => {
    const host = new MockViviHost(fixtures.one);
    render(<ViviApp host={host} />);

    const composer = screen.getByLabelText("Message");
    fireEvent.change(composer, { target: { value: "Keep this draft" } });
    expect(screen.getByRole("button", { name: "Send message" })).toBeEnabled();

    act(() => host.disconnect());

    expect(composer).toHaveValue("Keep this draft");
    expect(screen.getByRole("button", { name: "Send message" })).toBeDisabled();
    expect(screen.getByText("Host bridge disconnected")).toBeVisible();
  });

  it("disables host-backed sidebar commands after disconnection", () => {
    const host = new MockViviHost(fixtures.multiple);
    render(<ViviApp host={host} />);

    act(() => host.disconnect());

    for (const row of screen.getAllByRole("button", {
      name: /Stabilize native session ordering|New conversation|Review streaming event ownership/,
    })) {
      expect(row).toBeDisabled();
    }
  });

  it("prevents duplicate conversation creation while a request is pending", async () => {
    const host = new MockViviHost(fixtures.one);
    let complete: (() => void) | undefined;
    const pending = new Promise<{
      readonly kind: "accepted";
    }>((resolve) => {
      complete = () => resolve({ kind: "accepted" });
    });
    const create = vi
      .spyOn(host, "createConversation")
      .mockReturnValue(pending);
    render(<ViviApp host={host} />);

    const button = screen.getByRole("button", { name: "New conversation" });
    fireEvent.click(button);
    fireEvent.click(button);

    expect(create).toHaveBeenCalledTimes(1);
    expect(button).toBeDisabled();
    await act(async () => complete?.());
  });

  it("surfaces the failed conversation lifecycle message", () => {
    const message = "The conversation process exited unexpectedly.";
    const host = new MockViviHost({
      ...fixtures.one,
      selectedSession: {
        ...fixtures.one.selectedSession!,
        lifecycle: { kind: "failed", message },
      },
    });
    render(<ViviApp host={host} />);

    expect(screen.getByText("Conversation failed")).toBeVisible();
    expect(screen.getByText(message)).toBeVisible();
  });
});
