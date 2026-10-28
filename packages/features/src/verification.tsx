"use client";
import { useRef, useState } from "react";
import { client, emptyFilter, type Filter, type Queue, type Row } from "@sbco/client";
import { Button } from "@sbco/ui/button";
import { Input } from "@sbco/ui/input";
import { Field, FieldGroup, FieldLabel } from "@sbco/ui/field";
import { Panel, Form, Grid, Loading, useData, value, text, asOptions } from "./shared";
import { useShortcutAction, useShortcutBinding } from "./shortcuts";

export function Verification({
  queue = "standard",
  manager,
}: {
  queue?: string;
  manager: boolean;
}) {
  const [filter, setFilter] = useState<Filter>({ ...emptyFilter, status: "Pending", queue });
  const [cursor, setCursor] = useState<string | null>(null);
  const [history, setHistory] = useState<(string | null)[]>([]);
  const [refresh, setRefresh] = useState(0);
  const [selected, setSelected] = useState<Row | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const reasonRef = useRef<HTMLSelectElement>(null);
  const searchRef = useRef<HTMLInputElement>(null);
  const verifying = useRef(false);
  const searchShortcut = useShortcutBinding("search");
  const nextShortcut = useShortcutBinding("next");
  const previousShortcut = useShortcutBinding("previous");
  const matchShortcut = useShortcutBinding("match");
  const reasonShortcut = useShortcutBinding("reason");
  const [reason, setReason] = useState("");
  const { data, error: loadError } = useData<Queue>(
    { kind: "transactions", filter, cursor, limit: 50 },
    refresh,
  );
  const { data: offices } = useData<Row[]>({ kind: "offices" });
  const { data: settings } = useData<{ reasons: string[] }>({ kind: "settings" });
  const current = data?.rows.find((r) => r.id === selected?.id) ?? data?.rows[0];
  async function verify(status: string) {
    if (!current || busy || verifying.current || manager || current.primary_status !== "Pending")
      return;
    if (status === "Mismatch" && !reason) {
      reasonRef.current?.focus();
      return;
    }
    setBusy(true);
    verifying.current = true;
    setError("");
    try {
      await client.command({
        kind: "verify",
        id: value(current, "id"),
        revision: Number(current.revision),
        status,
        reason: status === "Mismatch" ? reason : "",
        notes: "",
      });
      setSelected(null);
      setRefresh((r) => r + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Verification failed");
    } finally {
      verifying.current = false;
      setBusy(false);
    }
  }
  function move(delta: number) {
    if (busy) return false;
    const rows = data?.rows || [];
    const index = rows.findIndex((r) => r.id === current?.id);
    if (!rows[index + delta]) return false;
    setSelected(rows[index + delta]);
    return true;
  }
  useShortcutAction("search", () => {
    searchRef.current?.focus();
    return Boolean(searchRef.current);
  });
  useShortcutAction("next", () => move(1));
  useShortcutAction("previous", () => move(-1));
  useShortcutAction("match", () => {
    if (!current || current.primary_status !== "Pending" || busy || manager) return false;
    void verify("Matched");
    return true;
  });
  useShortcutAction("reason", () => {
    if (!reasonRef.current || busy || manager) return false;
    reasonRef.current.focus();
    return true;
  });
  const currentIndex = data?.rows.findIndex((row) => row.id === current?.id) ?? -1;
  function update(key: keyof Filter, input: string) {
    setFilter((f) => ({ ...f, [key]: input || null }));
    setCursor(null);
    setHistory([]);
    setSelected(null);
  }
  return (
    <div className="flex flex-col gap-5">
      <Panel
        title="Verification queue"
        description="Search and page across every transaction in your assigned offices. Keyboard shortcuts are listed below and can be changed in My account."
      >
        <FieldGroup className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
          <Field>
            <FieldLabel htmlFor="account-search">Account or transaction</FieldLabel>
            <Input
              ref={searchRef}
              aria-keyshortcuts={searchShortcut}
              id="account-search"
              placeholder="Search all transactions"
              value={filter.search || ""}
              onChange={(e) => update("search", e.target.value)}
            />
          </Field>
          <Field>
            <FieldLabel htmlFor="office-filter">Office</FieldLabel>
            <select
              id="office-filter"
              className="control"
              value={filter.office || ""}
              onChange={(e) => update("office", e.target.value)}
            >
              <option value="">All assigned offices</option>
              {asOptions(offices).map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))}
            </select>
          </Field>
          <Field>
            <FieldLabel htmlFor="status-filter">Primary status</FieldLabel>
            <select
              id="status-filter"
              className="control"
              value={filter.status || ""}
              onChange={(e) => update("status", e.target.value)}
            >
              <option value="">All statuses</option>
              {["Pending", "Matched", "Mismatch"].map((s) => (
                <option key={s}>{s}</option>
              ))}
            </select>
          </Field>
          <Field>
            <FieldLabel htmlFor="date-filter">From report date</FieldLabel>
            <Input
              id="date-filter"
              type="date"
              value={filter.from_date || ""}
              onChange={(e) => update("from_date", e.target.value)}
            />
          </Field>
        </FieldGroup>
        <div className="mt-5">
          {!data ? (
            <Loading error={loadError} />
          ) : (
            <Grid
              rows={data.rows}
              columns={[
                ["account_number", "Account"],
                ["office_name", "Office"],
                ["report_date", "Report date"],
                ["credit", "Credit"],
                ["debit", "Debit"],
                ["primary_status", "PA result"],
                ["final_status", "Final result"],
              ]}
              action={(row) => (
                <Button
                  variant={current?.id === row.id ? "default" : "outline"}
                  size="sm"
                  onClick={() => setSelected(row)}
                >
                  Review
                </Button>
              )}
            />
          )}
        </div>
        <div className="mt-4 flex items-center justify-between">
          <span className="text-sm text-muted-foreground">
            Page {history.length + 1} · {data?.rows.length || 0} transactions
          </span>
          <div className="flex gap-2">
            <Button
              variant="outline"
              disabled={!history.length}
              onClick={() => {
                setCursor(history.at(-1) ?? null);
                setHistory((h) => h.slice(0, -1));
                setSelected(null);
              }}
            >
              Previous
            </Button>
            <Button
              variant="outline"
              disabled={!data?.next_cursor}
              onClick={() => {
                setHistory((h) => [...h, cursor]);
                setCursor(data?.next_cursor || null);
                setSelected(null);
              }}
            >
              Next
            </Button>
          </div>
        </div>
      </Panel>
      {current && (
        <Panel
          title={`Account ${value(current, "account_number")}`}
          description={`${value(current, "transaction_id")} · ${value(current, "source_sheet")} · source row ${value(current, "source_row")}`}
        >
          <p className="mb-4 text-sm text-muted-foreground">
            {value(current, "description") || "No transaction remarks"}
          </p>
          <div className="mb-4 flex flex-wrap gap-2">
            <Button
              variant="outline"
              disabled={busy || currentIndex <= 0}
              aria-keyshortcuts={previousShortcut}
              onClick={() => move(-1)}
            >
              Previous voucher
            </Button>
            <Button
              variant="outline"
              disabled={busy || currentIndex < 0 || currentIndex >= (data?.rows.length ?? 0) - 1}
              aria-keyshortcuts={nextShortcut}
              onClick={() => move(1)}
            >
              Next voucher
            </Button>
          </div>
          {value(current, "primary_status") === "Pending" ? (
            manager ? (
              <p>Initial verification must be completed by the allotted PA.</p>
            ) : (
              <div className="flex flex-wrap items-end gap-3">
                <Field className="max-w-sm">
                  <FieldLabel htmlFor="mismatch-reason">Mismatch reason</FieldLabel>
                  <select
                    ref={reasonRef}
                    aria-keyshortcuts={reasonShortcut}
                    id="mismatch-reason"
                    className="control"
                    value={reason}
                    onChange={(e) => setReason(e.target.value)}
                  >
                    <option value="">Choose a reason</option>
                    {settings?.reasons.map((r) => (
                      <option key={r}>{r}</option>
                    ))}
                  </select>
                </Field>
                <Button
                  disabled={busy}
                  aria-keyshortcuts={matchShortcut}
                  onClick={() => void verify("Matched")}
                >
                  Mark matched
                </Button>
                <Button
                  variant="outline"
                  disabled={busy || !reason}
                  onClick={() => void verify("Mismatch")}
                >
                  Record mismatch
                </Button>
                <Button variant="ghost" onClick={() => move(1)}>
                  Skip
                </Button>
              </div>
            )
          ) : (
            <Form
              key={value(current, "id")}
              label="Request correction"
              fields={[
                {
                  name: "status",
                  label: "Proposed status",
                  options: ["Pending", "Matched", "Mismatch"].map((s) => ({ value: s, label: s })),
                },
                {
                  name: "reason",
                  label: "Mismatch reason",
                  options: [
                    { value: "", label: "Not applicable" },
                    ...(settings?.reasons || []).map((r) => ({ value: r, label: r })),
                  ],
                },
                { name: "notes", label: "Verification notes" },
                { name: "explanation", label: "Reason for correction", required: true },
              ]}
              submit={async (d) => {
                await client.command({
                  kind: "request_correction",
                  id: value(current, "id"),
                  revision: Number(current.revision),
                  status: text(d, "status"),
                  reason: text(d, "reason"),
                  notes: text(d, "notes"),
                  request_reason: text(d, "explanation"),
                });
                setRefresh((r) => r + 1);
              }}
            />
          )}
          {error && (
            <p role="alert" className="mt-3 text-destructive">
              {error}
            </p>
          )}
        </Panel>
      )}
    </div>
  );
}
export function Reviews({ corrections = false }: { corrections?: boolean }) {
  const [refresh, setRefresh] = useState(0);
  const [selected, setSelected] = useState<Row | null>(null);
  const { data, error } = useData<Row[]>(
    { kind: corrections ? "corrections" : "reviews" },
    refresh,
  );
  const { data: settings } = useData<{ reasons: string[] }>({ kind: "settings" });
  return (
    <div className="flex flex-col gap-5">
      <Panel
        title={corrections ? "Correction approvals" : "Supervisor re-verification"}
        description="Your decision is recorded with the transaction revision and user identity."
      >
        {!data ? (
          <Loading error={error} />
        ) : (
          <Grid
            rows={data.filter((r) => !corrections || r.status === "Pending Approval")}
            columns={
              corrections
                ? [
                    ["account_number", "Account"],
                    ["proposed_status", "Proposed result"],
                    ["request_reason", "Explanation"],
                  ]
                : [
                    ["account_number", "Account"],
                    ["office_id", "Office"],
                    ["basis", "Selection"],
                    ["pa_status", "PA result"],
                  ]
            }
            action={(r) => (
              <Button size="sm" onClick={() => setSelected(r)}>
                Review decision
              </Button>
            )}
          />
        )}
      </Panel>
      {selected && (
        <Panel title={`Review ${value(selected, "account_number")}`}>
          <Form
            key={value(selected, "id")}
            label="Record decision"
            fields={
              corrections
                ? [
                    {
                      name: "approve",
                      label: "Decision",
                      options: [
                        { value: "yes", label: "Approve" },
                        { value: "no", label: "Reject" },
                      ],
                    },
                    { name: "notes", label: "Review notes", required: true },
                  ]
                : [
                    {
                      name: "status",
                      label: "Supervisor result",
                      options: ["Matched", "Mismatch"].map((s) => ({ value: s, label: s })),
                    },
                    {
                      name: "reason",
                      label: "Mismatch reason",
                      options: [
                        { value: "", label: "Not applicable" },
                        ...(settings?.reasons || []).map((r) => ({ value: r, label: r })),
                      ],
                    },
                    { name: "notes", label: "Supervisor notes", required: true },
                  ]
            }
            submit={async (d) => {
              await client.command(
                corrections
                  ? {
                      kind: "review_correction",
                      id: value(selected, "id"),
                      approve: text(d, "approve") === "yes",
                      notes: text(d, "notes"),
                    }
                  : {
                      kind: "reverify",
                      id: value(selected, "id"),
                      revision: Number(selected.revision),
                      status: text(d, "status"),
                      reason: text(d, "reason"),
                      notes: text(d, "notes"),
                    },
              );
              setSelected(null);
              setRefresh((r) => r + 1);
            }}
          />
        </Panel>
      )}
    </div>
  );
}
