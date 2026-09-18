import { expect, test } from "@playwright/test";

const rows = (page: import("@playwright/test").Page) =>
  page.locator("[data-session-row]").allTextContents();

test("selecting bottom, middle, and top sessions preserves order and one selection", async ({
  page,
}) => {
  await page.goto("/?scenario=multiple");
  const original = await rows(page);
  const sessionRows = page.locator("[data-session-row]");

  for (const index of [2, 1, 0]) {
    await sessionRows.nth(index).click();
    await expect(sessionRows.nth(index)).toHaveAttribute(
      "aria-current",
      "page",
    );
    await expect(
      page.locator('[data-session-row][aria-current="page"]'),
    ).toHaveCount(1);
    expect(await rows(page)).toEqual(original);
  }
});

test("project heading has one disclosure and full row toggles without losing selection", async ({
  page,
}) => {
  await page.goto("/?scenario=multiple");
  const heading = page.getByRole("button", { name: /vivi \/Users/ });
  await expect(heading.locator(".disclosure")).toHaveCount(1);
  const original = await rows(page);
  const selectedTitle = await page
    .locator('[data-session-row][aria-current="page"]')
    .textContent();

  await heading.click();
  await expect(heading).toHaveAttribute("aria-expanded", "false");
  await heading.click();
  await expect(heading).toHaveAttribute("aria-expanded", "true");

  expect(await rows(page)).toEqual(original);
  await expect(
    page.locator('[data-session-row][aria-current="page"]'),
  ).toContainText(selectedTitle ?? "");
});

test("session list has no ordinal badges and supports keyboard navigation", async ({
  page,
}) => {
  await page.goto("/?scenario=multiple");
  await expect(page.locator(".ordinal-badge")).toHaveCount(0);
  const first = page.locator("[data-session-row]").first();
  await first.focus();
  await page.keyboard.press("ArrowDown");
  await expect(page.locator("[data-session-row]").nth(1)).toBeFocused();
  await page.keyboard.press("End");
  await expect(page.locator("[data-session-row]").last()).toBeFocused();
  await page.keyboard.press("Home");
  await expect(first).toBeFocused();
});

test("composer accepts multiline text and sends with command enter", async ({
  page,
}) => {
  await page.goto("/?scenario=one");
  const composer = page.getByRole("textbox", { name: "Message" });
  await composer.fill("  First line\nSecond line  ");
  await page.keyboard.press("Meta+Enter");
  const sentMessage = page.locator(".user-message").last();
  expect(
    await sentMessage.evaluate((element) => element.lastChild?.textContent),
  ).toBe("  First line\nSecond line  ");
  await expect(sentMessage).toHaveCSS("white-space", "pre-wrap");
  await expect(composer).toHaveValue("");
});

test("session buttons keep native interactive semantics", async ({ page }) => {
  await page.goto("/?scenario=multiple");
  await expect(
    page.getByRole("button", { name: "Stabilize native session ordering" }),
  ).toBeVisible();
});

test("session lifecycle is visible without relying on color", async ({
  page,
}) => {
  await page.goto("/?scenario=streaming");

  await expect(
    page.locator(".session-row .lifecycle-status", {
      hasText: "Responding",
    }),
  ).toBeVisible();
});

test("captures stable core screenshots", async ({ page }) => {
  await page.goto("/?scenario=multiple");
  await expect(page).toHaveScreenshot("multiple-projects.png");
  await page.goto("/?scenario=streaming");
  await expect(page).toHaveScreenshot("streaming-response.png");
  await page.goto("/?scenario=error");
  await expect(page).toHaveScreenshot("error-state.png");
});
