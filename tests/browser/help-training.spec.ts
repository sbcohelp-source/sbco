import { test, expect, type Page } from "@playwright/test";
import type { AxeResults } from "axe-core";

const generation = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
const counts = {
  offices: 4,
  users: 3,
  pools: 1,
  imports: 2,
  transactions: 24,
  incidents: 3,
  letters: 1,
};
async function mock(page: Page, role = "Pa", active = false) {
  const state = {
    available: active,
    generation: active ? generation : (null as string | null),
    counts: { ...counts },
    failReset: false,
    requests: [] as { path: string; training?: string; body?: unknown }[],
  };
  if (active)
    await page.addInitScript(
      (value) => {
        if (!sessionStorage.getItem("test-initialized")) {
          sessionStorage.setItem("test-initialized", "1");
          sessionStorage.setItem("sbco.training.v1", JSON.stringify(value));
        }
      },
      { generation, role: "Administrator" },
    );
  await page.route("**/api/v1/**", async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname.replace("/api/v1/", "");
    const training = request.headers()["x-sbco-training"];
    state.requests.push({ path, training, body: request.postDataJSON() });
    let result: unknown = {};
    if (path === "me")
      result = {
        id: "mock-user",
        name: "Fixture user",
        role: training ? JSON.parse(training).role : role,
      };
    else if (path === "training/enable") {
      state.available = true;
      state.generation = generation;
    } else if (path === "training/reset") {
      if (state.failReset)
        return route.fulfill({
          status: 503,
          json: { error: "Training deletion could not complete. Please retry." },
        });
      state.available = false;
      state.generation = null;
    } else if (path === "query") result = [];
    if (path.startsWith("training"))
      result = { available: state.available, generation: state.generation, counts: state.counts };
    await route.fulfill({ json: result });
  });
  return state;
}
async function axe(page: Page) {
  await page.addScriptTag({ path: require.resolve("axe-core/axe.min.js") });
  const violations = await page.evaluate(async () => {
    const axe = (window as unknown as { axe: { run: (options: object) => Promise<AxeResults> } })
      .axe;
    return (
      await axe.run({ runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21aa"] } })
    ).violations.map((v) => v.id);
  });
  expect(violations).toEqual([]);
}

test("Help searches offline, exposes support and respects role links on a narrow screen", async ({
  page,
  context,
}) => {
  const state = await mock(page);
  await page.goto("/help");
  await expect(page.getByRole("heading", { name: "How can we help?" })).toBeVisible();
  await expect(page.getByRole("status")).toContainText("15 help topics");
  await expect(page.getByRole("link", { name: "Open Users", exact: true })).toHaveCount(0);
  await expect(page.getByRole("link", { name: "Open Supervisor review", exact: true })).toHaveCount(
    0,
  );
  await expect(page.getByRole("link", { name: "Open Training mode", exact: true })).toHaveAttribute(
    "href",
    "/training",
  );
  await page.getByLabel("Search help").fill("S K Singh");
  await expect(page.getByRole("heading", { name: "About SBCO and support" })).toBeVisible();
  await expect(page.getByText("Author: S K Singh", { exact: true })).toBeVisible();
  await expect(page.getByRole("link", { name: "Email sbcohelp@gmail.com" })).toHaveAttribute(
    "href",
    "mailto:sbcohelp@gmail.com",
  );
  await page.getByLabel("Search help").fill("leading zeros");
  await expect(page.getByRole("status")).toContainText("1 help topic");
  await expect(
    page.getByRole("heading", { name: "Import setup and transaction workbooks" }),
  ).toBeVisible();
  await context.setOffline(true);
  await page.getByLabel("Search help").fill("unfindableword");
  await expect(page.getByRole("heading", { name: "No matching help topics" })).toBeVisible();
  await page.getByRole("button", { name: "Show all help topics" }).click();
  await expect(page.getByRole("status")).toContainText("15 help topics");
  await context.setOffline(false);
  await page.setViewportSize({ width: 390, height: 844 });
  await axe(page);
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
  ).toBeTruthy();
  await page.screenshot({ path: "/tmp/sbco-help-mobile.png", fullPage: true });
  expect(state.requests.filter((r) => r.path !== "me")).toEqual([]);
});

test("explicit training switches reload, preserve practice and never attach practice context to controls", async ({
  page,
}) => {
  const state = await mock(page);
  await page.goto("/training");
  await expect(page.getByRole("button", { name: "Enable training", exact: true })).toBeEnabled();
  expect(state.requests.some((r) => r.path === "training/enable")).toBeFalsy();
  await page.getByRole("button", { name: "Enable training", exact: true }).click();
  await expect(page.getByRole("region", { name: "Workspace mode" })).toContainText(
    "TRAINING MODE — practice data only",
  );
  await expect(page.getByLabel("Practice role", { exact: true })).toHaveValue("Administrator");
  await page.getByLabel("Practice role", { exact: true }).selectOption("Supervisor");
  await expect(page.getByLabel("Practice role", { exact: true })).toHaveValue("Supervisor");
  await expect
    .poll(() => state.requests.filter((r) => r.path === "me").at(-1)?.training)
    .toBe(JSON.stringify({ generation, role: "Supervisor" }));
  await page.setViewportSize({ width: 390, height: 844 });
  await axe(page);
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
  ).toBeTruthy();
  await page.screenshot({ path: "/tmp/sbco-training-mobile.png", fullPage: true });
  await page.getByRole("button", { name: "Disable training", exact: true }).click();
  await expect(page.getByRole("region", { name: "Workspace mode" })).toContainText(
    "Live workspace",
  );
  await expect(page.getByRole("button", { name: "Resume training", exact: true })).toBeVisible();
  expect(state.available).toBeTruthy();
  expect(state.requests.some((r) => r.path === "training/reset")).toBeFalsy();
  expect(
    state.requests.filter((r) => r.path.startsWith("training")).every((r) => !r.training),
  ).toBeTruthy();
  expect(await page.evaluate(() => sessionStorage.getItem("sbco.training.v1"))).toBeNull();
});

test("training deletion requires fresh counts and exact confirmation, and failure retains training", async ({
  page,
}) => {
  const state = await mock(page, "Pa", true);
  await page.goto("/training");
  await page.getByRole("button", { name: "Review training deletion" }).click();
  const confirmation = page.getByLabel("Type DELETE TRAINING to confirm");
  await expect(confirmation).toBeFocused();
  const remove = page.getByRole("button", { name: "Delete all my training data", exact: true });
  await expect(remove).toBeDisabled();
  await confirmation.fill("DELETE");
  await expect(remove).toBeDisabled();
  state.counts.transactions = 25;
  await confirmation.fill("DELETE TRAINING");
  await remove.click();
  await expect(page.getByRole("status")).toContainText("Training records changed");
  await expect(confirmation).toBeEmpty();
  expect(state.requests.some((r) => r.path === "training/reset")).toBeFalsy();
  state.failReset = true;
  await confirmation.fill("DELETE TRAINING");
  await remove.click();
  await expect(page.getByRole("main").getByRole("alert")).toContainText(
    "Training deletion could not complete",
  );
  await expect(page.getByRole("region", { name: "Workspace mode" })).toContainText("TRAINING MODE");
  expect(await page.evaluate(() => sessionStorage.getItem("sbco.training.v1"))).toContain(
    generation,
  );
  state.failReset = false;
  await page.getByRole("button", { name: "Review training deletion" }).click();
  await confirmation.fill("DELETE TRAINING");
  await remove.click();
  await expect(page.getByRole("button", { name: "Enable training", exact: true })).toBeVisible();
  await expect(page.getByRole("region", { name: "Workspace mode" })).toContainText(
    "Live workspace",
  );
  const reset = state.requests.filter((r) => r.path === "training/reset").at(-1)!;
  expect(reset.training).toBeUndefined();
  expect(reset.body).toEqual({ generation, confirmation: "DELETE TRAINING" });
  expect(state.requests.at(state.requests.lastIndexOf(reset) - 1)?.path).toBe("training");
});

test("stale and invalid training selections fail closed, with explicit return to live", async ({
  page,
}) => {
  const state = await mock(page, "Administrator", true);
  await page.goto("/training");
  await expect(page.getByRole("button", { name: "Review training deletion" })).toBeVisible();
  state.generation = "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee";
  await page.getByRole("button", { name: "Review training deletion" }).click();
  await expect(page.getByRole("main").getByRole("alert")).toContainText("no longer matches");
  await expect(page.getByLabel("Type DELETE TRAINING to confirm")).toHaveCount(0);
  expect(state.requests.some((r) => r.path === "training/reset")).toBeFalsy();
  expect(await page.evaluate(() => sessionStorage.getItem("sbco.training.v1"))).toContain(
    generation,
  );
  await page.evaluate(() => sessionStorage.setItem("sbco.training.v1", "invalid-json"));
  const meCount = state.requests.filter((r) => r.path === "me").length;
  await page.reload();
  await expect(page.getByRole("region", { name: "Workspace mode" })).toContainText(
    "Training selection needs attention",
  );
  expect(state.requests.filter((r) => r.path === "me").length).toBe(meCount);
  await page.getByRole("button", { name: "Return to live mode", exact: true }).click();
  await expect(page.getByRole("region", { name: "Workspace mode" })).toContainText(
    "Live workspace",
  );
});

test("changing session storage cannot redirect the current page's workspace requests", async ({
  page,
}) => {
  const state = await mock(page, "Pa", true);
  await page.goto("/training");
  await expect(page.getByLabel("Practice role", { exact: true })).toBeVisible();
  await page.evaluate(() => sessionStorage.removeItem("sbco.training.v1"));
  await page
    .getByRole("navigation", { name: "Main navigation" })
    .getByRole("link", { name: "Help", exact: true })
    .click();
  await expect(page.getByRole("heading", { name: "How can we help?" })).toBeVisible();
  await expect(page.getByRole("region", { name: "Workspace mode" })).toContainText("TRAINING MODE");
  await page
    .getByRole("navigation", { name: "Main navigation" })
    .getByRole("link", { name: "Training", exact: true })
    .click();
  await expect(page.getByLabel("Practice role", { exact: true })).toBeVisible();
  // A client-side navigation remounts the app and invokes me, using the frozen context.
  expect(state.requests.filter((r) => r.path === "me").length).toBeGreaterThan(1);
  expect(
    state.requests
      .filter((r) => r.path === "me")
      .every((r) => r.training === JSON.stringify({ generation, role: "Administrator" })),
  ).toBeTruthy();
});
