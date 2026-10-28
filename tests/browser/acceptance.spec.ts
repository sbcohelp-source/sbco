import { test, expect, type Page } from "@playwright/test";
import { readFileSync } from "node:fs";
import type { AxeResults } from "axe-core";

const account = JSON.parse(readFileSync("/tmp/sbco-test-session.json", "utf8"));

async function accessible(page: Page) {
  await page.addScriptTag({ path: require.resolve("axe-core/axe.min.js") });
  const result = await page.evaluate(async () => {
    const axe = (window as unknown as { axe: { run: (options: object) => Promise<AxeResults> } })
      .axe;
    return axe.run({ runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21aa"] } });
  });
  expect(
    result.violations.map(({ id, nodes }) => ({ id, targets: nodes.map((n) => n.target) })),
  ).toEqual([]);
}

async function login(page: Page) {
  await page.goto("/");
  await expect(page).toHaveTitle(/SBCO/);
  await page.getByLabel("Email address").fill(account.admin_email);
  await page.getByLabel("Password", { exact: true }).fill(account.admin_password);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Overview", exact: true })).toBeVisible();
}

test("sign-in supports keyboard operation and accessible form labels", async ({ page }, info) => {
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  page.on("console", (message) => {
    // The anonymous session probe intentionally returns 401 before sign-in.
    if (
      message.type() === "error" &&
      !(message.text().includes("401") && message.location().url.endsWith("/api/v1/me"))
    )
      errors.push(message.text() + " " + message.location().url);
  });
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Welcome back" })).toBeVisible();
  await accessible(page);
  await page.getByLabel("Email address").focus();
  await page.keyboard.type(account.admin_email);
  await page.keyboard.press("Tab");
  await expect(page.getByLabel("Password", { exact: true })).toBeFocused();
  await page.keyboard.type(account.admin_password);
  await page.keyboard.press("Tab");
  await expect(page.getByRole("button", { name: "Sign in", exact: true })).toBeFocused();
  await page.keyboard.press("Enter");
  await expect(page.getByRole("heading", { name: "Overview", exact: true })).toBeVisible();
  await page.screenshot({ path: `/tmp/sbco-${info.project.name}-overview.png`, fullPage: true });
  expect(errors).toEqual([]);
});

test("administration and reports are accessible at desktop and mobile sizes", async ({
  page,
}, info) => {
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  page.on("console", (message) => {
    if (
      message.type() === "error" &&
      !(message.text().includes("401") && message.location().url.endsWith("/api/v1/me"))
    )
      errors.push(message.text() + " " + message.location().url);
  });
  await login(page);
  for (const section of [
    "imports",
    "offices",
    "users",
    "verify",
    "incidents",
    "letters",
    "reports",
    "settings",
    "account",
  ]) {
    await page.goto(`/${section}`);
    await expect(page.getByRole("main").getByRole("heading", { level: 1 })).toBeVisible();
    await expect(page.getByText("Loading records…")).toHaveCount(0);
    await expect(page.locator("nextjs-portal [data-nextjs-dialog]")).toHaveCount(0);
    await accessible(page);
  }
  await page.goto("/reports");
  await page.getByLabel("Report", { exact: true }).selectOption("DPR");
  await expect(page.getByRole("table", { name: "Daily Progress Register" })).toBeVisible();
  await accessible(page);
  await page.getByLabel("Report", { exact: true }).selectOption("MPR");
  await expect(page.getByRole("table", { name: "2. Irregularities", exact: true })).toBeVisible();
  const downloadPromise = page.waitForEvent("download");
  await page.getByRole("button", { name: "Download PDF" }).click();
  const download = await downloadPromise;
  expect(download.suggestedFilename()).toMatch(/\.pdf$/);
  await download.saveAs(`/tmp/sbco-${info.project.name}-mpr.pdf`);
  for (const width of [390, 320]) {
    await page.setViewportSize({ width, height: 844 });
    await accessible(page);
    expect(
      await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
    ).toBeTruthy();
  }
  await page.screenshot({
    path: `/tmp/sbco-${info.project.name}-mobile-report.png`,
    fullPage: true,
  });
  const scroller = page.getByRole("region", { name: "2. Irregularities", exact: true });
  await scroller.focus();
  await page.keyboard.press("ArrowRight");
  await expect.poll(() => scroller.evaluate((element) => element.scrollLeft)).toBeGreaterThan(0);
  expect(errors).toEqual([]);
});

test("mobile navigation retains focus, closes with Escape and restores the trigger", async ({
  page,
}) => {
  await login(page);
  await page.setViewportSize({ width: 390, height: 844 });
  const open = page.getByRole("button", { name: "Open navigation" });
  await open.focus();
  await page.keyboard.press("Enter");
  const close = page.getByRole("button", { name: "Close navigation" });
  await expect(close).toBeFocused();
  await accessible(page);
  await page.keyboard.press("Shift+Tab");
  await expect(page.getByRole("link", { name: "My account", exact: true })).toBeFocused();
  await page.keyboard.press("Tab");
  await expect(close).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(page.getByRole("navigation")).not.toBeVisible();
  await expect(open).toBeFocused();
  await open.click();
  await page.getByRole("link", { name: "Reports", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Reports", exact: true })).toBeVisible();
  await expect(page.getByRole("navigation")).not.toBeVisible();
});
