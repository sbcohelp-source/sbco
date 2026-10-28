import { test, expect, type Page } from "@playwright/test";
import type { AxeResults } from "axe-core";

type NativeCall = { command: string; args?: Record<string, unknown> };
async function connected(page: Page, initialAddress: string | null = null) {
  const state = {
    address: initialAddress,
    signedIn: false,
    failure: "",
    delay: 0,
    calls: [] as NativeCall[],
  };
  await page.exposeFunction("__connectionMock", async ({ command, args }: NativeCall) => {
    state.calls.push({ command, args });
    const status = () => ({
      mode: "connected",
      server_url: state.address,
      configured: !!state.address,
    });
    if (command === "connection_status") return status();
    if (command === "configure_connection") {
      if (state.delay) await new Promise((resolve) => setTimeout(resolve, state.delay));
      if (state.failure) throw new Error(state.failure);
      state.address = String(args?.serverUrl);
      state.signedIn = false;
      return status();
    }
    if (command === "logout") {
      state.signedIn = false;
      return;
    }
    if (command === "login") state.signedIn = true;
    if (command === "me" || command === "login") {
      if (!state.signedIn) throw new Error("Sign in to continue");
      return { id: "connected-admin", name: "Server administrator", role: "Administrator" };
    }
    if (command === "query") {
      const query = args?.query as { kind: string };
      if (query.kind === "onboarding")
        return {
          completed: true,
          step: "ready",
          office_count: 1,
          assigned_office_count: 1,
          user_count: 1,
          import_count: 0,
          transaction_count: 0,
        };
      if (query.kind === "dashboard")
        return { total: 0, matched: 0, mismatch: 0, pending: 0, credit: "0", debit: "0" };
      if (query.kind === "settings")
        return {
          id: 1,
          signatory: "Fixture office",
          random_percent: 5,
          reminder_days: 7,
          reasons: ["Fixture reason"],
        };
      return [];
    }
    throw new Error(`Unexpected native command: ${command}`);
  });
  await page.addInitScript(() => {
    Object.assign(window, {
      __TAURI_INTERNALS__: {
        invoke: (command: string, args?: Record<string, unknown>) =>
          (window as unknown as { __connectionMock: (call: NativeCall) => Promise<unknown> })
            .__connectionMock({ command, args })
            .catch((cause: Error) => Promise.reject(cause.message)),
      },
    });
  });
  return state;
}
async function accessible(page: Page) {
  await page.addScriptTag({ path: require.resolve("axe-core/axe.min.js") });
  const ids = await page.evaluate(async () => {
    const axe = (window as unknown as { axe: { run: (options: object) => Promise<AxeResults> } })
      .axe;
    return (
      await axe.run({ runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21aa"] } })
    ).violations.map((item) => item.id);
  });
  expect(ids).toEqual([]);
}

test("connected setup validates server origins, explains errors and retries without local setup", async ({
  page,
}) => {
  const state = await connected(page);
  await page.goto("/");
  const heading = page.getByRole("heading", { name: "Connect to your SBCO server", exact: true });
  await expect(heading).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "Set up this offline workspace", exact: true }),
  ).toHaveCount(0);
  const address = page.getByLabel("Server address", { exact: true });
  const connect = page.getByRole("button", { name: "Connect to server", exact: true });
  for (const value of [
    "http://office.example",
    "https://user:password@office.example",
    "https://office.example/path",
    "https://office.example?key=value",
  ]) {
    await address.fill(value);
    await connect.click();
    expect(state.calls.filter((call) => call.command === "configure_connection")).toHaveLength(0);
  }
  await address.fill("https://office.example");
  state.failure = "The server is unavailable. Check the address and try again.";
  await connect.click();
  await expect(page.getByRole("main").getByRole("alert")).toContainText("server is unavailable");
  await expect(address).toHaveValue("https://office.example");
  state.failure = "This server uses an incompatible SBCO version. Contact your administrator.";
  await connect.click();
  await expect(page.getByRole("main").getByRole("alert")).toContainText(
    "incompatible SBCO version",
  );
  expect(state.address).toBeNull();
  await page.setViewportSize({ width: 390, height: 844 });
  await accessible(page);
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
  ).toBeTruthy();
  await page.screenshot({ path: "/tmp/sbco-connection-mobile.png", fullPage: true });
  state.failure = "";
  state.delay = 250;
  const before = state.calls.filter((call) => call.command === "configure_connection").length;
  await connect.click();
  await page.locator("form").evaluate((form) => {
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
  });
  await expect(page.getByRole("heading", { name: "Welcome back", exact: true })).toBeVisible();
  expect(state.calls.filter((call) => call.command === "configure_connection")).toHaveLength(
    before + 1,
  );
  expect(state.address).toBe("https://office.example");
  await page.reload();
  await expect(page.getByRole("heading", { name: "Welcome back", exact: true })).toBeVisible();
  await expect(page.getByText("Server: https://office.example", { exact: true })).toBeVisible();
  expect(
    state.calls.some((call) => call.command === "setup_needed" || call.command === "setup"),
  ).toBe(false);
});

test("configured clients sign in on the server, hide local backups and explicitly change servers", async ({
  page,
}) => {
  const state = await connected(page, "https://first.example");
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Welcome back", exact: true })).toBeVisible();
  await page.getByLabel("Email address").fill("fixture@example.test");
  await page.getByLabel("Password", { exact: true }).fill("Synthetic-password-only-2026");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Overview", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Back up", exact: true })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Restore", exact: true })).toHaveCount(0);
  await page.goto("/settings");
  await expect(page.getByRole("heading", { name: "Settings", exact: true })).toBeVisible();
  expect(
    state.calls.some((call) => ["backup_status", "backup", "restore"].includes(call.command)),
  ).toBe(false);
  await page.getByRole("button", { name: "Change server", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Connect to your SBCO server", exact: true }),
  ).toBeVisible();
  expect(state.signedIn).toBe(false);
  expect(state.calls.some((call) => call.command === "logout")).toBe(true);
  await expect(page.getByLabel("Server address", { exact: true })).toHaveValue(
    "https://first.example",
  );
  await page.getByLabel("Server address", { exact: true }).fill("https://second.example");
  await page.getByRole("button", { name: "Connect to server", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Welcome back", exact: true })).toBeVisible();
  await expect(page.getByText("Server: https://second.example", { exact: true })).toBeVisible();
  await expect(page.getByLabel("Password", { exact: true })).toBeEmpty();
  expect(
    state.calls.some((call) => call.command === "setup_needed" || call.command === "setup"),
  ).toBe(false);
  expect(
    await page.evaluate(() =>
      [...Object.values(localStorage), ...Object.values(sessionStorage)].join(" "),
    ),
  ).not.toContain("Synthetic-password-only-2026");
  expect(errors).toEqual([]);
});

test("changing server from training exits practice and keeps the connection wizard open", async ({
  page,
}) => {
  const state = await connected(page, "https://first.example");
  state.signedIn = true;
  await page.addInitScript(() => {
    if (!sessionStorage.getItem("connection-training-initialized")) {
      sessionStorage.setItem("connection-training-initialized", "1");
      sessionStorage.setItem(
        "sbco.training.v1",
        JSON.stringify({
          generation: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
          role: "Administrator",
        }),
      );
    }
  });
  await page.goto("/help");
  await expect(page.getByRole("region", { name: "Workspace mode" })).toContainText("TRAINING MODE");
  await page.getByRole("button", { name: "Change server", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Connect to your SBCO server", exact: true }),
  ).toBeVisible();
  await expect(page.getByLabel("Server address", { exact: true })).toHaveValue(
    "https://first.example",
  );
  expect(await page.evaluate(() => sessionStorage.getItem("sbco.training.v1"))).toBeNull();
  expect(state.signedIn).toBe(false);
  await page.getByLabel("Server address", { exact: true }).fill("https://second.example");
  await page.getByRole("button", { name: "Connect to server", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Welcome back", exact: true })).toBeVisible();
  await expect(page.getByRole("region", { name: "Workspace mode" })).toContainText(
    "Live workspace",
  );
  await expect(page.getByText("Server: https://second.example", { exact: true })).toBeVisible();
});
