import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";

test("isolated fixture PA can practise administration, keep created records, export and reset its training", async ({
  page,
  baseURL,
}) => {
  test.skip(
    baseURL !== "http://localhost:3091",
    "Only the isolated fixture application may run this mutating test.",
  );
  const account = JSON.parse(readFileSync("/tmp/sbco-test-session.json", "utf8"));
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto("/");
  await page.getByLabel("Email address").fill(account.pa_email);
  await page.getByLabel("Password", { exact: true }).fill(account.pa_password);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Overview", exact: true })).toBeVisible();
  await page.goto("/training");
  await page.getByRole("button", { name: /^(Enable|Resume) training$/ }).click();
  await expect(page.getByLabel("Practice role", { exact: true })).toHaveValue("Administrator");
  const statusBefore = await (
    await page.request.get("/api/v1/training", { headers: { "X-SBCO-Request": "1" } })
  ).json();
  expect(statusBefore.available).toBe(true);
  expect(statusBefore.counts.transactions).toBe(24);
  const officeId = `TRAINING-UI-${Date.now()}`;
  await page.goto("/offices");
  await page.getByLabel("Office ID", { exact: true }).fill(officeId);
  await page.getByLabel("Office name", { exact: true }).fill("Created during browser practice");
  await page.getByLabel("Office type", { exact: true }).selectOption("SO");
  await page
    .getByLabel("Office ID", { exact: true })
    .locator("xpath=ancestor::form")
    .getByRole("button", { name: "Save", exact: true })
    .click();
  await expect(page.getByRole("cell", { name: officeId, exact: true })).toBeVisible();
  await page.goto("/training");
  await page.getByLabel("Practice role", { exact: true }).selectOption("Supervisor");
  await expect(page.getByLabel("Practice role", { exact: true })).toHaveValue("Supervisor");
  await page.goto("/reports");
  await page.getByLabel("Report", { exact: true }).selectOption("DPR");
  const downloadPromise = page.waitForEvent("download");
  await page.getByRole("button", { name: "Download PDF" }).click();
  const download = await downloadPromise;
  expect(download.suggestedFilename()).toMatch(/^TRAINING-/);
  await download.saveAs("/tmp/sbco-training-browser-DPR.pdf");
  await page.screenshot({ path: "/tmp/sbco-training-report.png", fullPage: true });
  await page.getByRole("button", { name: "Disable training", exact: true }).click();
  await expect(page.getByRole("region", { name: "Workspace mode" })).toContainText(
    "Live workspace",
  );
  const liveMe = await (
    await page.request.get("/api/v1/me", { headers: { "X-SBCO-Request": "1" } })
  ).json();
  expect(liveMe.role).toBe("Pa");
  await page.goto("/training");
  await page.getByRole("button", { name: "Resume training", exact: true }).click();
  await expect(page.getByLabel("Practice role", { exact: true })).toHaveValue("Administrator");
  const statusAfter = await (
    await page.request.get("/api/v1/training", { headers: { "X-SBCO-Request": "1" } })
  ).json();
  expect(statusAfter.generation).toBe(statusBefore.generation);
  expect(statusAfter.counts.offices).toBe(statusBefore.counts.offices + 1);
  await page.getByRole("button", { name: "Review training deletion" }).click();
  await page.getByLabel("Type DELETE TRAINING to confirm").fill("DELETE TRAINING");
  await page.getByRole("button", { name: "Delete all my training data", exact: true }).click();
  await expect(page.getByRole("button", { name: "Enable training", exact: true })).toBeVisible();
  const finalStatus = await (
    await page.request.get("/api/v1/training", { headers: { "X-SBCO-Request": "1" } })
  ).json();
  expect(finalStatus.available).toBe(false);
  expect(finalStatus.generation).toBeNull();
  expect(Object.values(finalStatus.counts).every((count) => count === 0)).toBe(true);
  expect(errors).toEqual([]);
});
