import { defineConfig } from "@playwright/test";

const baseURL = process.env.SBCO_TEST_WEB || "http://localhost:3091";
const endpoint = new URL(baseURL);
if (!["localhost", "127.0.0.1"].includes(endpoint.hostname) || endpoint.port !== "3091") {
  throw new Error(
    "Onboarding acceptance must use the isolated local test web server on port 3091.",
  );
}

export default defineConfig({
  testDir: "./tests/browser",
  testMatch: "onboarding.spec.ts",
  outputDir: "/tmp/sbco-onboarding-results",
  timeout: 90_000,
  workers: 1,
  reporter: "list",
  use: {
    baseURL,
    viewport: { width: 1440, height: 1000 },
    trace: "retain-on-failure",
  },
  projects: [
    { name: "chromium", use: { browserName: "chromium" } },
    { name: "firefox", use: { browserName: "firefox" } },
    { name: "webkit", use: { browserName: "webkit" } },
  ],
});
