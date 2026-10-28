import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests/browser",
  testMatch: [
    "acceptance.spec.ts",
    "shortcuts.spec.ts",
    "first-run.spec.ts",
    "help-training.spec.ts",
    "connection.spec.ts",
  ],
  outputDir: "/tmp/sbco-acceptance-results",
  timeout: 90_000,
  workers: 1,
  reporter: "list",
  use: {
    baseURL: process.env.SBCO_TEST_WEB || "http://localhost:3091",
    viewport: { width: 1440, height: 1000 },
  },
  projects: [
    { name: "chromium", use: { browserName: "chromium" } },
    { name: "firefox", use: { browserName: "firefox" } },
    { name: "webkit", use: { browserName: "webkit" } },
  ],
});
