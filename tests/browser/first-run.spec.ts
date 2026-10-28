import { test, expect } from "@playwright/test";
import type { AxeResults } from "axe-core";

test("offline setup explains local use, validates credentials and safely retries native setup", async ({
  page,
}) => {
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.addInitScript(() => {
    const state = { calls: 0, created: false };
    Object.assign(window, {
      __SBCO_SETUP_TEST__: state,
      __TAURI_INTERNALS__: {
        invoke: async (command: string) => {
          if (command === "connection_status")
            return { mode: "offline", server_url: null, configured: true };
          if (command === "setup_needed") return !state.created;
          if (command === "setup") {
            state.calls += 1;
            await new Promise((resolve) => setTimeout(resolve, 350));
            if (state.calls === 1) throw "Test setup could not complete. Please retry.";
            state.created = true;
            return;
          }
          throw "Sign in to continue";
        },
      },
    });
  });
  await page.goto("/");
  const heading = page.getByRole("heading", { name: "Set up this offline workspace", exact: true });
  await expect(heading).toBeVisible();
  await expect(heading).toBeFocused();
  await expect(page.getByText(/without an internet connection/)).toBeVisible();
  await expect(page.getByText(/latest 14 daily backups/)).toBeVisible();
  await page.addScriptTag({ path: require.resolve("axe-core/axe.min.js") });
  const accessibility = () =>
    page.evaluate(async () => {
      const axe = (window as unknown as { axe: { run: (options: object) => Promise<AxeResults> } })
        .axe;
      return (
        await axe.run({ runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21aa"] } })
      ).violations.map((item) => item.id);
    });
  expect(await accessibility()).toEqual([]);
  await page.screenshot({ path: "/tmp/sbco-offline-welcome.png", fullPage: true });
  await page.getByRole("button", { name: "Set up this computer" }).click();
  await expect(page.getByRole("status")).toHaveText("Step 2 of 2");
  await expect(heading).toBeFocused();
  await page.getByLabel("Full name", { exact: true }).fill("Fixture administrator");
  await page.getByLabel("Email", { exact: true }).fill("wizard@example.test");
  const password = page.getByLabel("Password (12+ characters)", { exact: true });
  const confirmation = page.getByLabel("Confirm password", { exact: true });
  await password.fill("short");
  await confirmation.fill("short");
  await page.getByRole("button", { name: "Create administrator", exact: true }).click();
  await expect(password).toBeFocused();
  await password.fill("Wizard-test-password-2026");
  await confirmation.fill("different-password-2026");
  await page.getByRole("button", { name: "Create administrator", exact: true }).click();
  await expect(page.getByRole("main").getByRole("alert")).toHaveText(/passwords do not match/);
  await expect(confirmation).toBeFocused();
  await expect(confirmation).toHaveAttribute("aria-invalid", "true");
  await page.getByRole("button", { name: "Back", exact: true }).click();
  await expect(page.getByRole("status")).toHaveText("Step 1 of 2");
  await page.getByRole("button", { name: "Set up this computer" }).click();
  await expect(page.getByLabel("Full name", { exact: true })).toHaveValue("Fixture administrator");
  await expect(password).toBeEmpty();
  await expect(confirmation).toBeEmpty();
  await password.fill("Wizard-test-password-2026");
  await confirmation.fill("Wizard-test-password-2026");
  await page.setViewportSize({ width: 390, height: 844 });
  expect(await accessibility()).toEqual([]);
  await page.screenshot({ path: "/tmp/sbco-offline-account-mobile.png", fullPage: true });
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
  ).toBeTruthy();
  await page.getByRole("button", { name: "Create administrator", exact: true }).click();
  await expect(page.getByRole("button", { name: "Creating administrator…" })).toBeDisabled();
  await expect(page.getByRole("button", { name: "Back", exact: true })).toBeDisabled();
  await page.locator("form").evaluate((form) => {
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
  });
  await expect(page.getByRole("main").getByRole("alert")).toHaveText(
    "Test setup could not complete. Please retry.",
  );
  await expect(page.getByRole("main").getByRole("alert")).toBeFocused();
  expect(
    await page.evaluate(
      () =>
        (window as unknown as { __SBCO_SETUP_TEST__: { calls: number } }).__SBCO_SETUP_TEST__.calls,
    ),
  ).toBe(1);
  await page.getByRole("button", { name: "Create administrator", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Welcome back" })).toBeVisible();
  await expect(page.getByLabel("Password", { exact: true })).toBeEmpty();
  expect(await page.evaluate(() => Object.values(localStorage).join(" "))).not.toContain(
    "Wizard-test-password-2026",
  );
  expect(
    await page.evaluate(
      () =>
        (window as unknown as { __SBCO_SETUP_TEST__: { calls: number } }).__SBCO_SETUP_TEST__.calls,
    ),
  ).toBe(2);
  expect(errors).toEqual([]);
});
