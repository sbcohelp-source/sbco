"use client";
import Link from "next/link";
import { useEffect, useState } from "react";
import {
  client,
  hasTrainingContext,
  emptyFilter,
  fileBase64,
  type Actor,
  type BackupStatus,
  type Filter,
  type Row,
} from "@sbco/client";
import { Button } from "@sbco/ui/button";
import { Input } from "@sbco/ui/input";
import { Field, FieldLabel } from "@sbco/ui/field";
import { Panel, Grid, Form, Loading, useData, value, text, asOptions } from "./shared";

export function Dashboard() {
  const { data, error } = useData<Row>({ kind: "dashboard", filter: emptyFilter });
  return (
    <div className="flex flex-col gap-5">
      <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        {[
          ["total", "Transactions"],
          ["matched", "Matched"],
          ["mismatch", "Mismatched"],
          ["pending", "Pending final result"],
        ].map(([key, title]) => (
          <Panel key={key} title={title}>
            <p className="text-4xl font-semibold tracking-tight">
              {data ? Number(data[key]).toLocaleString("en-IN") : "—"}
            </p>
          </Panel>
        ))}
      </div>
      {error && <Loading error={error} />}
      <Panel
        title="Two-stage verification"
        description="The allotted PA verifies each voucher first. High-value vouchers and random samples then go to the supervisor."
      >
        <div className="flex flex-wrap gap-3">
          <Button asChild>
            <Link href="/verify">Continue verification</Link>
          </Button>
          <Button asChild variant="outline">
            <Link href="/reports">View reports</Link>
          </Button>
        </div>
        <p className="mt-5 text-sm text-muted-foreground">
          Agent and RD default entries are kept in separate queues. Dashboard totals cover all
          transactions in your authorized offices.
        </p>
      </Panel>
      <Panel title="Amounts in scope">
        <div className="flex flex-wrap gap-12">
          <div>
            <p className="text-sm text-muted-foreground">Total credit</p>
            <p className="text-2xl font-semibold">INR {data ? value(data, "credit") : "—"}</p>
          </div>
          <div>
            <p className="text-sm text-muted-foreground">Total debit</p>
            <p className="text-2xl font-semibold">INR {data ? value(data, "debit") : "—"}</p>
          </div>
        </div>
      </Panel>
    </div>
  );
}
export function SetupImport({ onSaved }: { onSaved?: () => Promise<unknown> } = {}) {
  const [file, setFile] = useState<File | null>(null);
  const [validated, setValidated] = useState(false);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  async function submit(preview: boolean) {
    if (!file) return;
    setBusy(true);
    setError("");
    setMessage("");
    try {
      if (file.size > 5_000_000) throw new Error("Choose a setup workbook up to 5 MB.");
      const result = await client.command({
        kind: "import_setup",
        filename: file.name,
        content_base64: await fileBase64(file),
        preview,
      });
      const counts = result.created as Record<string, number>;
      const existing = result.existing as Record<string, number>;
      setMessage(
        `${preview ? "Ready to import" : "Imported"}: ${counts.users} users, ${counts.offices} offices, ${counts.pools} pools. ${existing.users + existing.offices + existing.pools} identical records skipped.${preview ? " No setup records have been saved." : " Set passwords for new users in Users."}`,
      );
      setValidated(preview);
      if (!preview) await onSaved?.();
    } catch (e) {
      setValidated(false);
      setError(e instanceof Error ? e.message : "Setup import failed");
    } finally {
      setBusy(false);
    }
  }
  return (
    <Panel
      title="Setup workbook"
      description="Import users, offices and pool assignments together. Preview checks every record. Any error cancels the complete import."
    >
      <Field>
        <FieldLabel htmlFor="setup-workbook">
          Choose a completed setup template (XLSX, up to 5 MB)
        </FieldLabel>
        <Input
          id="setup-workbook"
          type="file"
          accept=".xlsx"
          disabled={busy}
          onChange={(event) => {
            setFile(event.target.files?.[0] ?? null);
            setValidated(false);
            setMessage("");
            setError("");
          }}
        />
      </Field>
      <div className="mt-4 flex flex-wrap gap-3">
        <Button variant="outline" disabled={!file || busy} onClick={() => void submit(true)}>
          Preview setup
        </Button>
        <Button disabled={!validated || busy} onClick={() => void submit(false)}>
          Import setup
        </Button>
      </div>
      <p className="mt-3 text-sm text-muted-foreground">
        Existing records must match exactly. Set new user passwords separately in Users after
        import.
      </p>
      {busy && (
        <p role="status" className="mt-3">
          Checking workbook…
        </p>
      )}
      {message && (
        <p role="status" className="mt-3 text-primary">
          {message}
        </p>
      )}
      {error && (
        <p role="alert" className="mt-3 text-destructive">
          {error}
        </p>
      )}
    </Panel>
  );
}

export function Imports({ actor, includeSetup = true }: { actor: Actor; includeSetup?: boolean }) {
  const [refresh, setRefresh] = useState(0);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const { data, error: loadError } = useData<Row[]>({ kind: "imports" }, refresh);
  useEffect(() => {
    const timer = setInterval(() => setRefresh((r) => r + 1), 5000);
    return () => clearInterval(timer);
  }, []);
  async function upload(files: FileList | null) {
    if (!files?.length) return;
    setBusy(true);
    setError("");
    setMessage("");
    try {
      for (const file of Array.from(files)) {
        await client.command({
          kind: "import",
          filename: file.name,
          content_base64: await fileBase64(file),
        });
      }
      setMessage(`${files.length} workbook(s) submitted. Import progress is saved automatically.`);
      setRefresh((r) => r + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Upload failed");
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className="flex flex-col gap-5">
      <Panel
        title="Import templates"
        description="Download a blank Excel template. Instructions and examples are included in each workbook."
      >
        <div className="flex flex-wrap gap-3">
          {[
            ...(actor.role === "Administrator" ? [["SBCO_Setup_Template", "Setup template"]] : []),
            ["SBCO_SO_Transactions_Template", "SO transactions"],
            ["SBCO_BO_Transactions_Template", "BO transactions"],
          ].map(([file, label]) => (
            <Button key={file} asChild variant="outline">
              <a
                href={`/templates/${file}.xlsx`}
                download
                onClick={(event) => {
                  if (client.isDesktop()) {
                    event.preventDefault();
                    void client.saveTemplate(file).catch((e) => setError(e.message));
                  }
                }}
              >
                {label}
              </a>
            </Button>
          ))}
        </div>
      </Panel>
      {includeSetup && actor.role === "Administrator" && <SetupImport />}
      <Panel
        title="Import transaction workbooks"
        description="BO/AO and SO Long Book reports · XLS, XLSX or XLSM · up to 20 MB per file"
      >
        <Field>
          <FieldLabel htmlFor="workbooks">Choose one or more workbooks</FieldLabel>
          <Input
            id="workbooks"
            type="file"
            multiple
            accept=".xls,.xlsx,.xlsm"
            disabled={busy}
            onChange={(e) => void upload(e.target.files)}
          />
        </Field>
        {busy && (
          <p role="status" className="mt-3">
            Uploading…
          </p>
        )}
        {message && (
          <p role="status" className="mt-3 text-primary">
            {message}
          </p>
        )}
        {error && (
          <p role="alert" className="mt-3 text-destructive">
            {error}
          </p>
        )}
      </Panel>
      <Panel
        title="Import history"
        description="Exact duplicate files are reused. Semantic duplicates are retained in the duplicate register."
      >
        {!data ? (
          <Loading error={loadError} />
        ) : (
          <Grid
            rows={data}
            columns={[
              ["filename", "File"],
              ["status", "Status"],
              ["total", "Read"],
              ["inserted", "Inserted"],
              ["duplicates", "Duplicates"],
              ["error", "Details"],
            ]}
            action={(row) =>
              row.status === "Failed" ? (
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() =>
                    void client
                      .command({ kind: "retry_import", id: value(row, "id") })
                      .then(() => setRefresh((r) => r + 1))
                      .catch((e) => setError(e.message))
                  }
                >
                  Retry
                </Button>
              ) : null
            }
          />
        )}
      </Panel>
    </div>
  );
}
export function Offices() {
  const [refresh, setRefresh] = useState(0);
  const { data, error } = useData<Row[]>({ kind: "offices" }, refresh);
  const { data: pools } = useData<Row[]>({ kind: "pools" }, refresh);
  const { data: users } = useData<Row[]>({ kind: "users" }, refresh);
  return (
    <div className="flex flex-col gap-5">
      <Panel title="Offices">
        <Grid
          rows={data || []}
          columns={[
            ["id", "Office ID"],
            ["name", "Office"],
            ["office_type", "Type"],
            ["parent_id", "Parent SO"],
          ]}
        />
        {error && <Loading error={error} />}
      </Panel>
      <Panel title="Create or update an office">
        <Form
          fields={[
            { name: "id", label: "Office ID", required: true },
            { name: "name", label: "Office name", required: true },
            {
              name: "type",
              label: "Office type",
              options: ["SO", "BO"].map((s) => ({ value: s, label: s })),
            },
            {
              name: "parent",
              label: "Parent SO",
              options: [
                { value: "", label: "No parent" },
                ...asOptions(data?.filter((r) => r.office_type === "SO")),
              ],
            },
          ]}
          submit={async (d) => {
            await client.command({
              kind: "save_office",
              id: text(d, "id"),
              name: text(d, "name"),
              office_type: text(d, "type"),
              parent_id: text(d, "parent") || null,
            });
            setRefresh((r) => r + 1);
          }}
        />
      </Panel>
      <Panel
        title="Office pools"
        description="Each office belongs to one pool. A PA sees only the offices allocated through their pools."
      >
        <Grid
          rows={pools || []}
          columns={[
            ["name", "Pool"],
            ["offices", "Offices"],
            ["pa_user", "Assigned PA"],
            ["random_percent", "Sampling %"],
          ]}
        />
      </Panel>
      <Panel title="Create an office pool">
        <Form
          fields={[
            { name: "name", label: "Pool name", required: true },
            { name: "offices", label: "Office IDs, separated by commas", required: true },
            {
              name: "pa",
              label: "Assigned PA",
              options: [
                { value: "", label: "Unassigned" },
                ...asOptions(users?.filter((r) => r.role === "Pa")),
              ],
            },
            {
              name: "percentage",
              label: "Random sample percentage",
              type: "number",
              defaultValue: "10",
              required: true,
            },
          ]}
          submit={async (d) => {
            await client.command({
              kind: "save_pool",
              id: null,
              name: text(d, "name"),
              offices: text(d, "offices")
                .split(",")
                .map((s) => s.trim())
                .filter(Boolean),
              pa_user: text(d, "pa") || null,
              random_percent: Number(text(d, "percentage")),
            });
            setRefresh((r) => r + 1);
          }}
        />
      </Panel>
    </div>
  );
}
export function Users({ actor }: { actor: Actor }) {
  const [refresh, setRefresh] = useState(0);
  const { data, error } = useData<Row[]>({ kind: "users" }, refresh);
  return (
    <div className="flex flex-col gap-5">
      <Panel title="Users and roles">
        {!data ? (
          <Loading error={error} />
        ) : (
          <Grid
            rows={data}
            columns={[
              ["name", "Name"],
              ["email", "Email"],
              ["role", "Role"],
              ["active", "Active"],
            ]}
          />
        )}
      </Panel>
      {actor.role === "Administrator" && (
        <>
          <Panel title="Create a user">
            <Form
              fields={[
                { name: "name", label: "Full name", required: true },
                { name: "email", label: "Email", type: "email", required: true },
                {
                  name: "password",
                  label: "Initial password (at least 12 characters)",
                  type: "password",
                  required: true,
                },
                {
                  name: "role",
                  label: "Role",
                  options: ["Pa", "Supervisor", "Administrator"].map((s) => ({
                    value: s,
                    label: s,
                  })),
                },
              ]}
              submit={async (d) => {
                await client.command({
                  kind: "create_user",
                  name: text(d, "name"),
                  email: text(d, "email"),
                  password: String(d.get("password") || ""),
                  role: text(d, "role"),
                });
                setRefresh((r) => r + 1);
              }}
            />
          </Panel>
          <Panel
            title="Update user access"
            description="Saving revokes existing sessions. Disabling a PA or changing their role also clears their pool assignment. At least one active administrator is required."
          >
            <Form
              fields={[
                { name: "user", label: "User to update", options: asOptions(data) },
                { name: "name", label: "Full name", required: true },
                {
                  name: "role",
                  label: "New role",
                  options: ["Pa", "Supervisor", "Administrator"].map((s) => ({
                    value: s,
                    label: s,
                  })),
                },
                {
                  name: "active",
                  label: "Account access",
                  options: [
                    { value: "true", label: "Enabled" },
                    { value: "false", label: "Disabled" },
                  ],
                },
              ]}
              submit={async (d) => {
                await client.command({
                  kind: "update_user",
                  user_id: text(d, "user"),
                  name: text(d, "name"),
                  role: text(d, "role"),
                  active: text(d, "active") === "true",
                });
                setRefresh((r) => r + 1);
              }}
            />
          </Panel>
          <Panel
            title="Administrator password recovery"
            description="Resetting a password revokes all of that user's active sessions."
          >
            <Form
              fields={[
                { name: "user", label: "User", options: asOptions(data) },
                { name: "password", label: "New password", type: "password", required: true },
              ]}
              submit={async (d) => {
                await client.command({
                  kind: "reset_password",
                  user_id: text(d, "user"),
                  password: String(d.get("password") || ""),
                });
              }}
            />
          </Panel>
        </>
      )}
    </div>
  );
}
export function Reports() {
  const [report, setReport] = useState("DPR");
  const [filter, setFilter] = useState<Filter>({ ...emptyFilter, queue: "all" });
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const { data, error: loadError } = useData<{
    totals: Row;
    rows: Row[];
    effective_filter: Filter;
    document: {
      title: string;
      subtitle: string;
      sections: { title: string; columns: string[]; rows: string[][] }[];
      notes: string[];
    };
  }>({
    kind: "report",
    report,
    filter,
  });
  const { data: offices } = useData<Row[]>({ kind: "offices" });
  async function download() {
    setBusy(true);
    setError("");
    try {
      await client.export({ report, filter, letter_id: null });
    } catch (e) {
      setError(e instanceof Error ? e.message : "Export failed");
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className="flex flex-col gap-5">
      <Panel
        title="Operational reports"
        description="Totals and progress summaries cover the full result. Transaction details preview 100 rows; detailed PDF exports allow up to 20,000 rows."
      >
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <Field>
            <FieldLabel htmlFor="report-kind">Report</FieldLabel>
            <select
              id="report-kind"
              className="control"
              value={report}
              onChange={(e) => setReport(e.target.value)}
            >
              {[
                "DPR",
                "Daily Detail",
                "MPR",
                "Mismatch",
                "Pending Voucher",
                "MAP",
                "Transactions",
              ].map((r) => (
                <option key={r}>{r}</option>
              ))}
            </select>
          </Field>
          <Field>
            <FieldLabel htmlFor="report-office">Office</FieldLabel>
            <select
              id="report-office"
              className="control"
              value={filter.office || ""}
              onChange={(e) => setFilter((f) => ({ ...f, office: e.target.value || null }))}
            >
              <option value="">All assigned offices</option>
              {asOptions(offices).map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))}
            </select>
          </Field>
          {["from_date", "to_date"].map((key) => (
            <Field key={key}>
              <FieldLabel htmlFor={key}>{key === "from_date" ? "From date" : "To date"}</FieldLabel>
              <Input
                id={key}
                type="date"
                onChange={(e) => setFilter((f) => ({ ...f, [key]: e.target.value || null }))}
              />
            </Field>
          ))}
        </div>
        <p className="my-4 text-sm text-muted-foreground">
          DPR, daily detail and MPR use the final verification date in India time. Other reports use
          the original report date. Progress reports default to the last 31 days and allow up to 366
          days.
        </p>
        <Button onClick={() => void download()} disabled={busy}>
          {busy ? "Generating…" : "Download PDF"}
        </Button>
        {error && (
          <p role="alert" className="mt-3 text-destructive">
            {error}
          </p>
        )}
      </Panel>
      <Panel title="Complete totals">
        {!data ? (
          <Loading error={loadError} />
        ) : (
          <>
            <div className="mb-5 flex flex-wrap gap-8">
              <span>
                <b>{value(data.totals, "total")}</b> transactions
              </span>
              <span>
                Credit: INR <b>{value(data.totals, "credit")}</b>
              </span>
              <span>
                Debit: INR <b>{value(data.totals, "debit")}</b>
              </span>
            </div>
            <p className="mb-4 text-sm text-muted-foreground">{data.document.subtitle}</p>
            {data.document.sections.map((section, index) => (
              <section key={index} className="mb-6">
                {section.title && <h3 className="mb-3 font-semibold">{section.title}</h3>}
                <div
                  className="overflow-x-auto rounded-md border"
                  tabIndex={0}
                  role="region"
                  aria-label={section.title || data.document.title}
                >
                  <table className="w-full text-left text-sm">
                    <caption className="sr-only">{section.title || data.document.title}</caption>
                    <thead className="bg-muted">
                      <tr>
                        {section.columns.map((column) => (
                          <th key={column} scope="col" className="p-3">
                            {column}
                          </th>
                        ))}
                      </tr>
                    </thead>
                    <tbody>
                      {section.rows.map((row, rowIndex) => (
                        <tr key={rowIndex} className="border-t">
                          {row.map((cell, cellIndex) => (
                            <td key={cellIndex} className="p-3 align-top whitespace-pre-line">
                              {cell}
                            </td>
                          ))}
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </section>
            ))}
            {data.document.notes.map((note, index) => (
              <p key={index} className="mt-3 text-sm text-muted-foreground">
                {note}
              </p>
            ))}
          </>
        )}
      </Panel>
    </div>
  );
}
function DesktopBackups() {
  const [status, setStatus] = useState<BackupStatus | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    if (client.isConnected()) return;
    let active = true;
    const load = () =>
      client
        .backupStatus()
        .then((result) => {
          if (active) {
            setStatus(result);
            setError("");
          }
        })
        .catch((e: Error) => {
          if (active) setError(e.message);
        });
    void load();
    const timer = setInterval(() => void load(), 60_000);
    return () => {
      active = false;
      clearInterval(timer);
    };
  }, []);
  return (
    <Panel
      title="Automatic backups"
      description="While this app is open, a daily backup is checked at startup and every hour. The latest 14 daily backups are kept on this computer."
    >
      {error ? (
        <Loading error={error} />
      ) : !status ? (
        <Loading />
      ) : !status.enabled ? (
        <p>This workspace uses a connected database. Manage backups on its server.</p>
      ) : (
        <dl className="grid gap-3 text-sm">
          <div>
            <dt className="font-medium">Last successful backup</dt>
            <dd>
              {status.last_success
                ? new Date(status.last_success).toLocaleString("en-IN", {
                    timeZone: "Asia/Kolkata",
                  }) + " (India time)"
                : "Waiting for the first backup"}
            </dd>
          </div>
          <div>
            <dt className="font-medium">Backup folder</dt>
            <dd className="break-all">{status.directory}</dd>
          </div>
          {status.last_error && (
            <div role="alert" className="text-destructive">
              <dt className="font-medium">Latest backup problem</dt>
              <dd>{status.last_error}</dd>
            </div>
          )}
        </dl>
      )}
      <p className="mt-4 text-sm text-muted-foreground">
        Use Back up in the navigation menu to save an additional copy to your office’s backup drive.
        Automatic backups resume when the app is reopened.
      </p>
    </Panel>
  );
}

export function Settings({ actor }: { actor: Actor }) {
  const [refresh, setRefresh] = useState(0);
  const { data, error } = useData<Row>({ kind: "settings" }, refresh);
  return (
    <div className="flex flex-col gap-5">
      <Panel title="Verification and correspondence settings">
        {!data ? (
          <Loading error={error} />
        ) : (
          <Form
            key={refresh}
            fields={[
              {
                name: "percent",
                label: "Default random sample %",
                type: "number",
                defaultValue: value(data, "random_percent"),
                required: true,
              },
              {
                name: "days",
                label: "Reminder interval in days",
                type: "number",
                defaultValue: value(data, "reminder_days"),
                required: true,
              },
              { name: "signatory", label: "Signatory", defaultValue: value(data, "signatory") },
              {
                name: "designation",
                label: "Designation",
                defaultValue: value(data, "designation"),
              },
              {
                name: "reasons",
                label: "Mismatch reasons, separated by semicolons",
                defaultValue: (data.reasons as string[]).join("; "),
                required: true,
              },
            ]}
            submit={async (d) => {
              await client.command({
                kind: "save_settings",
                random_percent: Number(text(d, "percent")),
                reminder_days: Number(text(d, "days")),
                signatory: text(d, "signatory"),
                designation: text(d, "designation"),
                reasons: text(d, "reasons")
                  .split(";")
                  .map((s) => s.trim())
                  .filter(Boolean),
              });
              setRefresh((r) => r + 1);
            }}
          />
        )}
      </Panel>
      {client.isDesktop() &&
        !client.isConnected() &&
        actor.role === "Administrator" &&
        !hasTrainingContext() && <DesktopBackups />}
    </div>
  );
}
export function Audit() {
  const { data, error } = useData<Row[]>({ kind: "audit" });
  return (
    <Panel
      title="Audit history"
      description="The latest 500 recorded actions. Passwords and raw uploaded data are excluded."
    >
      {!data ? (
        <Loading error={error} />
      ) : (
        <Grid
          rows={data}
          columns={[
            ["created_at", "Time"],
            ["actor_id", "User"],
            ["action", "Action"],
            ["entity_id", "Record"],
            ["detail", "Details"],
          ]}
        />
      )}
    </Panel>
  );
}
