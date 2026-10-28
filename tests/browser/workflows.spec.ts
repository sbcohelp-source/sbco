import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";
const account = JSON.parse(readFileSync("/tmp/sbco-test-session.json", "utf8"));
test("PA logs in, finds a transaction beyond row 200, verifies it, and uses mobile navigation", async ({
  page,
}) => {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto("/");
  await expect(page).toHaveTitle(/SBCO/);
  await page.getByLabel("Email address").fill(account.pa_email);
  await page.getByLabel("Password", { exact: true }).fill(account.pa_password);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Overview", exact: true })).toBeVisible();
  await page.screenshot({ path: "/tmp/sbco-dashboard.png", fullPage: true });
  await page.getByRole("link", { name: "Verification", exact: true }).click();
  await page.getByLabel("Account or transaction").fill("00000250");
  await expect(page.getByRole("heading", { name: "Account 00000250" })).toBeVisible();
  await page.getByRole("button", { name: "Mark matched", exact: true }).click();
  await expect(page.getByText("No records match this view.")).toBeVisible();
  await page.getByLabel("Primary status").selectOption("Matched");
  await expect(page.getByRole("heading", { name: "Account 00000250" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Request correction", exact: true })).toBeVisible();
  await page.screenshot({ path: "/tmp/sbco-verification.png", fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.getByRole("button", { name: "Open navigation" }).click();
  await expect(page.getByRole("navigation")).toBeVisible();
  await page.getByRole("button", { name: "Close navigation" }).click();
  await page.screenshot({ path: "/tmp/sbco-mobile.png", fullPage: true });
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth),
  ).toBeTruthy();
  expect(errors).toEqual([]);
});
test("administrator screens render and complete report totals differ from preview length", async ({
  page,
}) => {
  await page.goto("/");
  await page.getByLabel("Email address").fill(account.admin_email);
  await page.getByLabel("Password", { exact: true }).fill(account.admin_password);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Overview", exact: true })).toBeVisible();
  for (const section of [
    "imports",
    "offices",
    "users",
    "reverify",
    "corrections",
    "incidents",
    "letters",
    "settings",
    "audit",
  ]) {
    await page.goto("/" + section);
    await expect(page.getByRole("main")).toBeVisible();
    await expect(page.getByRole("main").getByRole("alert")).toHaveCount(0);
    await expect(page.locator("nextjs-portal [data-nextjs-dialog]")).toHaveCount(0);
  }
  await page.goto("/reports");
  await page.getByLabel("Report", { exact: true }).selectOption("Transactions");
  await page.getByLabel("Office", { exact: true }).selectOption(account.office);
  await expect(page.getByText("251", { exact: true }).first()).toBeVisible();
  await expect(
    page
      .getByRole("table", { name: account.office + " - Fixture SO", exact: true })
      .locator("tbody tr"),
  ).toHaveCount(100);
  await page.getByLabel("Report", { exact: true }).selectOption("DPR");
  await expect(
    page.getByRole("table", { name: "Daily Progress Register" }).locator("tbody tr"),
  ).toHaveCount(31);
  await page.getByLabel("Report", { exact: true }).selectOption("MPR");
  await expect(page.getByRole("heading", { name: "2. Irregularities", exact: true })).toBeVisible();
  await expect(
    page.getByRole("table", { name: "2. Irregularities", exact: true }).locator("tbody tr"),
  ).toHaveCount(3);
  await page.screenshot({ path: "/tmp/sbco-report-screen.png", fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth),
  ).toBeTruthy();
  const download = page.waitForEvent("download");
  await page.getByRole("button", { name: "Download PDF" }).click();
  expect((await download).suggestedFilename()).toMatch(/\.pdf$/);
});
