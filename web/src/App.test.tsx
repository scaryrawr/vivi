import {
  act,
  cleanup,
  fireEvent,
  render,
  screen,
} from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
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
});
