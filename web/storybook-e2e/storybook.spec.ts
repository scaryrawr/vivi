import { expect, test } from "@playwright/test";

test("built Storybook renders the application story", async ({ page }) => {
  await page.goto(
    "/iframe.html?id=vivi-application--multiple-projects&viewMode=story",
  );

  await expect(
    page.getByRole("complementary", {
      name: "Projects and conversations",
    }),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: /vivi \/Users/ }),
  ).toBeVisible();
});
