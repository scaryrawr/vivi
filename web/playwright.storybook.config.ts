import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./storybook-e2e",
  use: {
    baseURL: "http://127.0.0.1:4174",
  },
  webServer: {
    command:
      "pnpm exec vite preview --outDir storybook-static --host 127.0.0.1 --port 4174",
    port: 4174,
    reuseExistingServer: !process.env.CI,
  },
  projects: [{ name: "chromium" }],
});
