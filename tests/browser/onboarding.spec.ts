import { test, expect, type APIRequestContext, type Page } from "@playwright/test";
import { randomBytes, randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import type { AxeResults } from "axe-core";

const operator = JSON.parse(readFileSync("/tmp/sbco-test-session.json", "utf8"));
type Role = "Administrator" | "Pa" | "Supervisor";
type TestAccount = { id: string; email: string; password: string; role: Role };
type Progress = {
  step: string;
  completed: boolean;
  office_count: number;
  assigned_office_count: number;
  user_count: number | null;
  import_count: number | null;
};
const created = new Map<APIRequestContext, TestAccount[]>();
const headers = { "X-SBCO-Request": "1" };

async function command(request: APIRequestContext, kind: string, fields: object) {
  const response = await request.post("/api/v1/command", {
    headers,
    data: { request_id: randomUUID(), command: { kind, ...fields } },
  });
  expect(response.status()).toBe(200);
  return response.json();
}

async function account(request: APIRequestContext, role: Role): Promise<TestAccount> {
  const tag = randomUUID().slice(0, 8);
  const credentials = {
    email: `onboarding-${tag}@example.test`,
    password: randomBytes(24).toString("base64url"),
    role,
  };
  const result = await command(request, "create_user", {
    name: `Onboarding ${role} ${tag}`,
    ...credentials,
  });
  const user = { id: result.id as string, ...credentials };
  created.set(request, [...(created.get(request) || []), user]);
  return user;
}

async function progress(page: Page): Promise<Progress> {
  const response = await page.request.post("/api/v1/query", {
    headers,
    data: { kind: "onboarding" },
  });
  expect(response.status()).toBe(200);
  return response.json();
}

async function login(page: Page, user: TestAccount) {
  await page.goto("/");
  await expect(page).toHaveTitle(/SBCO/);
  await page.getByLabel("Email address").fill(user.email);
  await page.getByLabel("Password", { exact: true }).fill(user.password);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page.getByRole("heading", { level: 2, name: /^Welcome to SBCO,/ })).toBeVisible();
}

async function step(page: Page, name: string) {
  await expect(
    page.getByRole("heading", {
      level: 2,
      name: name === "Welcome" ? /^Welcome to SBCO,/ : name,
      exact: name !== "Welcome",
    }),
  ).toBeVisible();
  await expect(page.locator("nextjs-portal [data-nextjs-dialog]")).toHaveCount(0);
}

async function accessible(page: Page) {
  await page.addScriptTag({ path: require.resolve("axe-core/axe.min.js") });
  const result = await page.evaluate(async () => {
    return (
      window as unknown as { axe: { run: (options: object) => Promise<AxeResults> } }
    ).axe.run({
      runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21aa"] },
    });
  });
  expect(
    result.violations.map(({ id, nodes }) => ({ id, targets: nodes.map((node) => node.target) })),
  ).toEqual([]);
}

test.beforeEach(async ({ request }) => {
  const result = await request.post("/api/v1/login", {
    headers,
    data: { email: operator.admin_email, password: operator.admin_password },
  });
  expect(result.status()).toBe(200);
});

test.afterEach(async ({ request }) => {
  for (const user of created.get(request) || []) {
    await command(request, "update_user", {
      user_id: user.id,
      name: "Completed onboarding test",
      role: user.role,
      active: false,
    });
  }
  created.delete(request);
});

test("administrator can leave, resume, reload, finish and review setup", async ({
  page,
  request,
}, info) => {
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const user = await account(request, "Administrator");
  await login(page, user);
  await accessible(page);
  await page.screenshot({
    path: `/tmp/sbco-onboarding-${info.project.name}-desktop.png`,
    fullPage: true,
  });
  expect(await progress(page)).toMatchObject({ step: "welcome", completed: false });
  await page.getByRole("button", { name: "Do this later", exact: true }).click();
  await expect(
    page.getByRole("heading", { level: 1, name: "Overview", exact: true }),
  ).toBeVisible();
  await page.getByRole("link", { name: "Get started", exact: true }).click();
  await step(page, "Welcome");
  await page.getByRole("button", { name: "Continue", exact: true }).click();
  await step(page, "Offices");
  const office = "ONBOARD-" + randomUUID().slice(0, 8);
  await page.getByLabel("Office ID", { exact: true }).fill(office);
  await page.getByLabel("Office name", { exact: true }).fill("Onboarding acceptance office");
  await page.getByRole("button", { name: "Save office", exact: true }).click();
  await expect
    .poll(async () => {
      const response = await page.request.post("/api/v1/query", {
        headers,
        data: { kind: "offices" },
      });
      return (await response.json()).some((row: { id: string }) => row.id === office);
    })
    .toBeTruthy();
  await page.getByRole("button", { name: "Continue", exact: true }).click();
  await step(page, "Your team");
  await page.reload();
  await step(page, "Your team");
  expect(await progress(page)).toMatchObject({ step: "team", completed: false });
  await page.getByRole("button", { name: "Do this later", exact: true }).click();
  await page.getByRole("button", { name: "Resume setup", exact: true }).click();
  await step(page, "Your team");
  expect(await progress(page)).toMatchObject({ step: "team", completed: false });
  await page.getByRole("button", { name: "Back", exact: true }).click();
  await step(page, "Offices");
  await page.getByRole("button", { name: "Continue", exact: true }).click();
  await step(page, "Your team");
  for (const title of ["Preferences", "First import", "Ready"]) {
    await page.getByRole("button", { name: "Continue", exact: true }).click();
    await step(page, title);
    await accessible(page);
  }
  await page.setViewportSize({ width: 390, height: 844 });
  await accessible(page);
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
  ).toBeTruthy();
  await page.screenshot({
    path: `/tmp/sbco-onboarding-${info.project.name}-mobile.png`,
    fullPage: true,
  });
  await page.getByRole("button", { name: "Finish setup", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Your introduction is complete", exact: true }),
  ).toBeVisible();
  expect(await progress(page)).toMatchObject({ step: "ready", completed: true });
  await page.getByRole("link", { name: "Go to overview", exact: true }).click();
  await expect(page).toHaveURL(/:\d+\/$/);
  await expect(page.getByRole("heading", { name: "Amounts in scope", exact: true })).toBeVisible();
  await expect(page.getByRole("main").getByText("INR —", { exact: true })).toHaveCount(0);
  await page.reload();
  await expect(
    page.getByRole("heading", { level: 1, name: "Overview", exact: true }),
  ).toBeVisible();
  await expect(page.getByRole("heading", { name: "Amounts in scope", exact: true })).toBeVisible();
  await expect(page.getByRole("main").getByText("INR —", { exact: true })).toHaveCount(0);
  await page.getByRole("button", { name: "Open navigation", exact: true }).click();
  await page.getByRole("link", { name: "Get started", exact: true }).click();
  await page.getByRole("button", { name: "Review setup", exact: true }).click();
  await step(page, "Welcome");
  expect(errors).toEqual([]);
});

for (const role of ["Pa", "Supervisor"] as const) {
  test(`${role} sees personal guidance without administrator setup controls`, async ({
    page,
    request,
  }) => {
    const errors: string[] = [];
    page.on("pageerror", (error) => errors.push(error.message));
    const user = await account(request, role);
    const other = await account(request, role);
    await login(page, user);
    const initial = await progress(page);
    if (role === "Pa") {
      expect(initial.user_count).toBeNull();
      expect(initial.import_count).toBeNull();
      expect(initial.office_count).toBe(0);
      expect(initial.assigned_office_count).toBe(0);
    } else {
      expect(initial.user_count).toBeGreaterThan(0);
      expect(initial.import_count).not.toBeNull();
    }
    for (const title of ["Your work", "Daily routine", "Ready"]) {
      await page.getByRole("button", { name: "Continue", exact: true }).click();
      await step(page, title);
      await expect(page.getByRole("button", { name: "Save office", exact: true })).toHaveCount(0);
      await expect(page.getByRole("button", { name: "Create user", exact: true })).toHaveCount(0);
      await accessible(page);
    }
    await page.getByRole("button", { name: "Finish setup", exact: true }).click();
    await expect.poll(async () => (await progress(page)).completed).toBe(true);
    expect(await progress(page)).toMatchObject({ step: "ready", completed: true });
    await page.getByRole("button", { name: "Sign out", exact: true }).click();
    await login(page, other);
    expect(await progress(page)).toMatchObject({ step: "welcome", completed: false });
    expect(errors).toEqual([]);
  });
}

test("team step creates staff and assigns only the selected office", async ({ page, request }) => {
  const user = await account(request, "Administrator");
  const tag = randomUUID().slice(0, 8);
  const office = `ONBOARD-TEAM-${tag}`;
  await command(request, "save_office", {
    id: office,
    name: `Team office ${tag}`,
    office_type: "SO",
    parent_id: null,
  });
  await login(page, user);
  await command(page.request, "save_onboarding", { step: "team", completed: false });
  await page.goto("/onboarding");
  await step(page, "Your team");
  const staff = {
    email: `onboarding-staff-${tag}@example.test`,
    password: randomBytes(24).toString("base64url"),
    role: "Pa" as const,
  };
  await page.getByLabel("Full name", { exact: true }).fill(`Onboarding PA ${tag}`);
  await page.getByLabel("Email", { exact: true }).fill(staff.email);
  await page
    .getByLabel("Initial password (at least 12 characters)", { exact: true })
    .fill(staff.password);
  await page.getByLabel("Role", { exact: true }).selectOption("Pa");
  await page.getByRole("button", { name: "Add staff member", exact: true }).click();
  let staffId = "";
  await expect
    .poll(async () => {
      const response = await request.post("/api/v1/query", { headers, data: { kind: "users" } });
      const found = (await response.json()).find(
        (row: { email: string }) => row.email === staff.email,
      );
      staffId = found?.id || "";
      return !!staffId;
    })
    .toBe(true);
  created.set(request, [...(created.get(request) || []), { id: staffId, ...staff }]);
  await page.getByLabel("Pool name", { exact: true }).fill(`Onboarding pool ${tag}`);
  await page.getByLabel("Office", { exact: true }).selectOption(office);
  await page.getByLabel("Postal Assistant", { exact: true }).selectOption(staffId);
  await page.getByRole("button", { name: "Assign office", exact: true }).click();
  await expect
    .poll(async () => {
      const response = await request.post("/api/v1/query", { headers, data: { kind: "pools" } });
      return (await response.json()).some(
        (row: { pa_user: string; offices: string[] }) =>
          row.pa_user === staffId && row.offices.length === 1 && row.offices[0] === office,
      );
    })
    .toBe(true);
  await page.getByRole("button", { name: "Sign out", exact: true }).click();
  await login(page, { id: staffId, ...staff });
  expect(await progress(page)).toMatchObject({ office_count: 1, assigned_office_count: 1 });
  await page.getByRole("button", { name: "Continue", exact: true }).click();
  await expect(
    page.getByText("You currently have 1 allocated offices", { exact: false }),
  ).toBeVisible();
});

test("failed progress save stays on the current step and can be retried", async ({
  page,
  request,
}) => {
  const user = await account(request, "Administrator");
  await login(page, user);
  let fail = true;
  await page.route("**/api/v1/command", async (route) => {
    const request = route.request().postDataJSON();
    if (request?.command?.kind === "save_onboarding" && fail) {
      fail = false;
      await route.fulfill({
        status: 503,
        contentType: "application/json",
        body: JSON.stringify({ error: "Temporary test interruption" }),
      });
    } else await route.continue();
  });
  await page.getByRole("button", { name: "Continue", exact: true }).click();
  await expect(page.getByRole("main").getByRole("alert")).toContainText(
    "Temporary test interruption",
  );
  await step(page, "Welcome");
  expect(await progress(page)).toMatchObject({ step: "welcome", completed: false });
  await page.getByRole("button", { name: "Continue", exact: true }).click();
  await step(page, "Offices");
  expect(await progress(page)).toMatchObject({ step: "offices", completed: false });
});

test("mocked empty-workspace readiness disables Finish setup and explains the required office", async ({
  page,
  request,
}) => {
  const user = await account(request, "Administrator");
  await login(page, user);
  await page.route("**/api/v1/query", async (route) => {
    if (route.request().postDataJSON()?.kind !== "onboarding") {
      await route.continue();
      return;
    }
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        step: "ready",
        completed: false,
        office_count: 0,
        assigned_office_count: 0,
        user_count: 1,
        import_count: 0,
        transaction_count: 0,
      }),
    });
  });
  await page.goto("/onboarding");
  await step(page, "Ready");
  await expect(page.getByRole("button", { name: "Finish setup", exact: true })).toBeDisabled();
  await expect(page.getByRole("main").getByRole("alert")).toContainText("Add at least one office");
  await expect(page.getByText("No transactions yet.", { exact: false })).toBeVisible();
  await accessible(page);
});
