import { describe, expect, it } from "vitest";
import { resolveFixtureName } from "./fixtures";

describe("resolveFixtureName", () => {
  it("accepts only fixture-owned scenario names", () => {
    expect(resolveFixtureName("streaming")).toBe("streaming");
    expect(resolveFixtureName("constructor")).toBe("multiple");
    expect(resolveFixtureName("__proto__")).toBe("multiple");
    expect(resolveFixtureName(null)).toBe("multiple");
  });
});
