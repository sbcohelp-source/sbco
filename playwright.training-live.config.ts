import { defineConfig } from "@playwright/test";
export default defineConfig({
  testDir: "./tests/browser",
  testMatch: "training-live.spec.ts",
  outputDir: "/tmp/sbco-training-live-results",
  timeout: 120_000,
  workers: 1,
  reporter: "list",
  use: { baseURL: "http://localhost:3091", viewport: { width: 1440, height: 1000 } },
  projects: [{ name: "chromium", use: { browserName: "chromium" } }],
});
