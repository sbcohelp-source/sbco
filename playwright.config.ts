import { defineConfig } from "@playwright/test";
export default defineConfig({
  testDir: "./tests/browser",
  outputDir: "/tmp/sbco-playwright-results",
  workers: 1,
  use: {
    baseURL: process.env.SBCO_TEST_WEB || "http://localhost:3091",
    viewport: { width: 1440, height: 1000 },
  },
  reporter: "list",
});
