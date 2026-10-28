import { test, expect, type Page } from "@playwright/test";
import { readFileSync } from "node:fs";

const account = JSON.parse(readFileSync("/tmp/sbco-test-session.json", "utf8"));

async function login(page: Page, role: "pa" | "admin" = "admin") {
  await page.goto("/");
  await page.getByLabel("Email address").fill(account[`${role}_email`]);
  await page.getByLabel("Password", { exact: true }).fill(account[`${role}_password`]);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Overview", exact: true })).toBeVisible();
}

test("keyboard settings persist per user and reject unsafe or duplicate bindings", async ({
  page,
}) => {
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await login(page);
  // Use client navigation between sections; keep full reloads below to prove persistence.
  await page.getByRole("navigation").getByRole("link", { name: "My account", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Keyboard preferences" })).toBeVisible();
  await page.getByLabel("Focus account search shortcut").fill("Ctrl+L");
  await page.getByRole("button", { name: "Save keyboard preferences" }).click();
  await expect(page.getByRole("main").getByRole("alert")).toContainText(
    "Browser Ctrl/Cmd shortcuts",
  );
  await page.getByLabel("Focus account search shortcut").fill("Alt+Shift+S");
  await page.getByRole("button", { name: "Save keyboard preferences" }).click();
  await expect(page.getByRole("main").getByRole("alert")).toContainText("assigned more than once");
  await page.getByLabel("Focus account search shortcut").fill("Alt+Shift+X");
  await page.getByRole("button", { name: "Save keyboard preferences" }).click();
  await expect(page.getByRole("status")).toContainText("Keyboard preferences saved");
  await page.reload();
  await expect(page.getByLabel("Focus account search shortcut")).toHaveValue("Alt+Shift+X");
  await page.getByRole("navigation").locator('a[href="/verify"]').click();
  await expect(page.getByLabel("Account or transaction")).toHaveAttribute(
    "aria-keyshortcuts",
    "Alt+Shift+X",
  );
  await page.getByRole("main").focus();
  await page.keyboard.press("Alt+Shift+F");
  await expect(page.getByLabel("Account or transaction")).not.toBeFocused();
  await page.keyboard.press("Alt+Shift+X");
  await expect(page.getByLabel("Account or transaction")).toBeFocused();
  await page.getByRole("navigation").getByRole("link", { name: "My account", exact: true }).click();
  await page.getByLabel("Keyboard shortcuts", { exact: true }).selectOption("disabled");
  await page.getByRole("button", { name: "Save keyboard preferences" }).click();
  await page.reload();
  await expect(page.getByLabel("Keyboard shortcuts", { exact: true })).toHaveValue("disabled");
  await page.getByRole("navigation").locator('a[href="/verify"]').click();
  await page.getByRole("main").focus();
  await page.keyboard.press("Alt+Shift+X");
  await expect(page.getByLabel("Account or transaction")).not.toBeFocused();
  await expect(page.getByLabel("Account or transaction")).not.toHaveAttribute("aria-keyshortcuts");
  await page.getByRole("button", { name: "Sign out", exact: true }).click();
  await login(page, "pa");
  await page.getByRole("navigation").getByRole("link", { name: "My account", exact: true }).click();
  await expect(page.getByLabel("Focus account search shortcut")).toHaveValue("Alt+Shift+F");
  await expect(page.getByLabel("Keyboard shortcuts", { exact: true })).toHaveValue("enabled");
  await page.getByLabel("Focus account search shortcut").fill("Alt+Shift+X");
  await page.getByRole("button", { name: "Save keyboard preferences" }).click();
  await page.getByRole("button", { name: "Restore default shortcuts" }).click();
  await expect(page.getByRole("status")).toContainText("Default keyboard preferences restored");
  await expect(page.getByLabel("Focus account search shortcut")).toHaveValue("Alt+Shift+F");
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: "/tmp/sbco-keyboard-preferences.png", fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: "/tmp/sbco-keyboard-preferences-mobile.png", fullPage: true });
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
  ).toBeTruthy();
  expect(errors).toEqual([]);
});

test("save shortcut targets only a focused marked form and honors native validation and busy state", async ({
  page,
}) => {
  await login(page);
  const commands: Record<string, unknown>[] = [];
  await page.route("**/api/v1/command", async (route) => {
    commands.push(route.request().postDataJSON().command);
    await new Promise((resolve) => setTimeout(resolve, 250));
    await route.fulfill({ json: {} });
  });
  await page.getByRole("navigation").locator('a[href="/offices"]').click();
  await page.getByLabel("Office ID", { exact: true }).focus();
  await page.keyboard.press("Alt+Shift+S");
  await expect(page.getByLabel("Office ID", { exact: true })).toBeFocused();
  expect(commands).toHaveLength(0);
  await page.getByLabel("Office ID", { exact: true }).fill("SHORTCUT-TEST");
  await page.keyboard.press("Alt+Shift+S");
  await expect(page.getByLabel("Office name", { exact: true })).toBeFocused();
  expect(commands).toHaveLength(0);
  await page.getByLabel("Office name", { exact: true }).fill("Shortcut test office");
  await page.getByRole("main").focus();
  await page.keyboard.press("Alt+Shift+S");
  expect(commands).toHaveLength(0);
  await page.getByLabel("Office name", { exact: true }).focus();
  await page.keyboard.press("Alt+Shift+S");
  await expect(page.getByRole("button", { name: "Saving…" })).toBeDisabled();
  await page.keyboard.press("Alt+Shift+S");
  await expect(page.getByRole("status")).toContainText("Saved successfully");
  expect(commands).toEqual([
    {
      kind: "save_office",
      id: "SHORTCUT-TEST",
      name: "Shortcut test office",
      office_type: "SO",
      parent_id: null,
    },
  ]);
  await page.getByRole("navigation").getByRole("link", { name: "My account", exact: true }).click();
  await page.getByLabel("Current password").fill("not-submitted");
  await page.getByLabel("New password (12+ characters)").fill("also-not-submitted");
  await page.keyboard.press("Alt+Shift+S");
  expect(commands).toHaveLength(1);
  await page.getByLabel("Focus account search shortcut").fill("Alt+Shift+X");
  await page.keyboard.press("Alt+Shift+S");
  await expect(page.getByText("Keyboard preferences saved", { exact: true })).toHaveCount(0);
  expect(commands).toHaveLength(1);
});

test("verification shortcuts preserve typing and composition, navigate and record exactly the current voucher", async ({
  page,
}) => {
  await login(page, "pa");
  const rows = [1, 2, 3].map((number) => ({
    id: `shortcut-${number}`,
    revision: number,
    account_number: `KEY000${number}`,
    office_name: "Shortcut fixture",
    report_date: "2026-10-28",
    credit: "100.00",
    debit: "0.00",
    primary_status: "Pending",
    final_status: "Pending",
    transaction_id: `KEYTX${number}`,
    source_sheet: "LongBook",
    source_row: number + 5,
  }));
  const commands: Record<string, unknown>[] = [];
  await page.route("**/api/v1/query", async (route) => {
    if (route.request().postDataJSON().kind !== "transactions") return route.continue();
    await route.fulfill({
      json: { rows: rows.filter((row) => row.primary_status === "Pending"), next_cursor: null },
    });
  });
  await page.route("**/api/v1/command", async (route) => {
    const command = route.request().postDataJSON().command;
    commands.push(command);
    const row = rows.find((row) => row.id === command.id);
    if (row) row.primary_status = command.status;
    await route.fulfill({ json: {} });
  });
  await page.getByRole("navigation").locator('a[href="/verify"]').click();
  await expect(page.getByRole("heading", { name: "Account KEY0001", exact: true })).toBeVisible();
  await page.getByLabel("Account or transaction").focus();
  for (const binding of ["Alt+Shift+N", "Alt+Shift+M", "Alt+Shift+R"])
    await page.keyboard.press(binding);
  await expect(page.getByLabel("Account or transaction")).toBeFocused();
  expect(commands).toHaveLength(0);
  await expect(page.getByRole("heading", { name: "Account KEY0001", exact: true })).toBeVisible();
  await page.getByRole("main").focus();
  for (const key of ["m", "r", "s", "ArrowRight"]) await page.keyboard.press(key);
  await expect(page.getByRole("heading", { name: "Account KEY0001", exact: true })).toBeVisible();
  expect(commands).toHaveLength(0);
  await page.evaluate(() => {
    for (const options of [{ repeat: true }, { isComposing: true }, { keyCode: 229 }]) {
      document.activeElement?.dispatchEvent(
        new KeyboardEvent("keydown", {
          key: "M",
          altKey: true,
          shiftKey: true,
          bubbles: true,
          ...options,
        }),
      );
    }
    const event = new KeyboardEvent("keydown", {
      key: "M",
      altKey: true,
      shiftKey: true,
      bubbles: true,
    });
    Object.defineProperty(event, "getModifierState", {
      value: (key: string) => key === "AltGraph",
    });
    document.activeElement?.dispatchEvent(event);
  });
  expect(commands).toHaveLength(0);
  await page.keyboard.press("Alt+Shift+N");
  await expect(page.getByRole("heading", { name: "Account KEY0002", exact: true })).toBeVisible();
  await page.keyboard.press("Alt+Shift+P");
  await expect(page.getByRole("heading", { name: "Account KEY0001", exact: true })).toBeVisible();
  await page.keyboard.press("Alt+Shift+R");
  await expect(page.getByLabel("Mismatch reason", { exact: true })).toBeFocused();
  await page.keyboard.press("Alt+Shift+M");
  expect(commands).toHaveLength(0);
  await page.getByRole("main").focus();
  await page.keyboard.press("Alt+Shift+N");
  await page.keyboard.press("Alt+Shift+M");
  await expect.poll(() => commands.length).toBe(1);
  expect(commands[0]).toEqual({
    kind: "verify",
    id: "shortcut-2",
    revision: 2,
    status: "Matched",
    reason: "",
    notes: "",
  });
  await expect(page.getByRole("heading", { name: "Account KEY0001", exact: true })).toBeVisible();
  await page.getByRole("main").focus();
  await page.keyboard.press("Alt+Shift+K");
  await expect(page.locator("details")).toHaveAttribute("open", "");
  await expect(page.locator("summary")).toBeFocused();
  await page.screenshot({ path: "/tmp/sbco-shortcut-reference.png", fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.getByRole("button", { name: "Open navigation" }).click();
  await page.keyboard.press("Alt+Shift+M");
  await page.keyboard.press("Alt+Shift+F");
  expect(commands).toHaveLength(1);
  await expect(page.getByLabel("Account or transaction")).not.toBeFocused();
  await expect(page.getByRole("dialog", { name: "Main navigation" })).toBeVisible();
});
