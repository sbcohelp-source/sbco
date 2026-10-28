import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import ts from "typescript";
const source = await readFile(new URL("../packages/client/src/index.ts", import.meta.url), "utf8");
const compiled = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext },
}).outputText;
const { client, ApiError, fileBase64 } = await import(
  `data:text/javascript;base64,${Buffer.from(compiled).toString("base64")}`
);
const originalFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = originalFetch;
});
test("commands carry an explicit replay identifier and same-origin session protection", async () => {
  let captured;
  globalThis.fetch = async (url, options) => {
    captured = { url, options };
    return Response.json({ id: "record" });
  };
  const command = {
    kind: "verify",
    id: "record",
    revision: 3,
    status: "Matched",
    reason: "",
    notes: "",
  };
  await client.command(command, "retry-id");
  assert.equal(captured.url, "/api/v1/command");
  assert.equal(captured.options.credentials, "same-origin");
  assert.equal(captured.options.headers["X-SBCO-Request"], "1");
  assert.deepEqual(JSON.parse(captured.options.body), { request_id: "retry-id", command });
});
test("stale decisions retain the server conflict and message", async () => {
  globalThis.fetch = async () =>
    Response.json({ error: "Record changed; reload before deciding" }, { status: 409 });
  await assert.rejects(
    client.command({ kind: "issue_letter", id: "record" }),
    (e) => e instanceof ApiError && e.status === 409 && e.message.includes("reload"),
  );
});
test("oversized workbooks are rejected before the browser allocates encoded content", async () => {
  await assert.rejects(fileBase64({ size: 20_000_001 }), /20 MB/);
});

const originalWindow = globalThis.window;
const originalDocument = globalThis.document;
afterEach(() => {
  if (originalWindow === undefined) delete globalThis.window;
  else globalThis.window = originalWindow;
  if (originalDocument === undefined) delete globalThis.document;
  else globalThis.document = originalDocument;
});
async function workspaceClient(raw) {
  const values = new Map(raw ? [["sbco.training.v1", raw]] : []);
  globalThis.window = {
    sessionStorage: {
      getItem: (key) => values.get(key) ?? null,
      setItem: (key, value) => values.set(key, value),
      removeItem: (key) => values.delete(key),
    },
    location: { reload() {} },
  };
  return import(
    `data:text/javascript;base64,${Buffer.from(compiled).toString("base64")}#${crypto.randomUUID()}`
  );
}
const training = { generation: "fd727604-6dbd-4499-a28d-cd38ed6c1702", role: "Pa" };
test("training context accompanies queries, commands, identity and PDF exports", async () => {
  const { client: isolated } = await workspaceClient(JSON.stringify(training));
  const calls = [];
  let download;
  globalThis.document = { createElement: () => (download = { click() {} }) };
  globalThis.fetch = async (url, options) => {
    calls.push({ url, options });
    return url.endsWith("export") ? new Response("PDF") : Response.json({});
  };
  await isolated.me();
  await isolated.query({ kind: "offices" });
  await isolated.command({ kind: "save_onboarding", step: "work", completed: false });
  await isolated.export({ report: "DPR", letter_id: null });
  assert.equal(calls.length, 4);
  for (const call of calls)
    assert.deepEqual(JSON.parse(call.options.headers["X-SBCO-Training"]), training);
  assert.match(download.download, /^TRAINING-/);
});
test("mode changes cannot redirect an already mounted form into live data", async () => {
  const {
    client: isolated,
    getTrainingContext,
    setTrainingContext,
  } = await workspaceClient(JSON.stringify(training));
  assert.deepEqual(getTrainingContext(), training);
  setTrainingContext(null);
  assert.deepEqual(getTrainingContext(), training);
  let header;
  globalThis.fetch = async (_, options) => {
    header = options.headers["X-SBCO-Training"];
    return Response.json({ error: "Training workspace expired" }, { status: 409 });
  };
  await assert.rejects(isolated.query({ kind: "offices" }), /expired/);
  assert.deepEqual(JSON.parse(header), training);
  await assert.rejects(
    isolated.command({ kind: "save_onboarding", step: "work", completed: false }),
    /expired/,
  );
  assert.deepEqual(JSON.parse(header), training);
});
test("training lifecycle controls always use live authentication without a training context", async () => {
  const { client: isolated } = await workspaceClient(JSON.stringify(training));
  const calls = [];
  globalThis.fetch = async (url, options) => {
    calls.push({ url, options });
    return Response.json({ available: false });
  };
  await isolated.trainingStatus();
  await isolated.enableTraining();
  await isolated.resetTraining({
    generation: training.generation,
    confirmation: "DELETE TRAINING",
  });
  assert.equal(calls.length, 3);
  for (const call of calls) assert.equal(call.options.headers["X-SBCO-Training"], undefined);
  assert.equal(JSON.parse(calls[2].options.body).generation, training.generation);
});
test("corrupted training selection fails closed instead of silently using live data", async () => {
  const { client: isolated, hasTrainingContext } = await workspaceClient(
    '{"generation":"public","role":"Administrator"}',
  );
  let calls = 0;
  globalThis.fetch = async () => {
    calls++;
    return Response.json({});
  };
  assert.equal(hasTrainingContext(), true);
  await assert.rejects(isolated.command({ kind: "save_settings" }), /training selection/);
  await assert.rejects(isolated.query({ kind: "offices" }), /training selection/);
  assert.equal(calls, 0);
});
