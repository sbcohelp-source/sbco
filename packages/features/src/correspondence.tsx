"use client";
import { useState } from "react";
import { client, emptyFilter, type Row } from "@sbco/client";
import { Button } from "@sbco/ui/button";
import { Panel, Grid, Form, Loading, useData, value, text } from "./shared";
const dueDate = () => new Date(Date.now() + 7 * 86400000).toISOString().slice(0, 10);
export function Correspondence({ letters = false }: { letters?: boolean }) {
  const [refresh, setRefresh] = useState(0);
  const [selected, setSelected] = useState<string[]>([]);
  const [editing, setEditing] = useState<Row | null>(null);
  const [error, setError] = useState("");
  const { data, error: loadError } = useData<Row[]>(
    { kind: letters ? "letters" : "incidents" },
    refresh,
  );
  async function issue(row: Row) {
    setError("");
    try {
      await client.command({ kind: "issue_letter", id: value(row, "id") });
      setRefresh((r) => r + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Issue failed");
    }
  }
  async function download(row: Row) {
    setError("");
    try {
      await client.export({
        report: "Transactions",
        filter: emptyFilter,
        letter_id: value(row, "id"),
      });
    } catch (e) {
      setError(e instanceof Error ? e.message : "Export failed");
    }
  }
  return (
    <div className="flex flex-col gap-5">
      <Panel
        title={letters ? "Correspondence register" : "Incidents and objections"}
        description={
          letters
            ? "Issued PDFs are retained as immutable snapshots."
            : "Select open incidents for one destination SO to draft a letter."
        }
      >
        {error && (
          <p role="alert" className="mb-4 text-destructive">
            {error}
          </p>
        )}
        {!data ? (
          <Loading error={loadError} />
        ) : (
          <Grid
            rows={data}
            columns={
              letters
                ? [
                    ["number", "Number"],
                    ["office_id", "Destination"],
                    ["kind", "Kind"],
                    ["round", "Reminder"],
                    ["due_date", "Due date"],
                    ["status", "Status"],
                  ]
                : [
                    ["account_number", "Account"],
                    ["office_id", "Office"],
                    ["incident_type", "Type"],
                    ["issue", "Issue"],
                    ["status", "Status"],
                  ]
            }
            action={(row) =>
              letters ? (
                <div className="flex flex-wrap gap-2">
                  <Button variant="outline" size="sm" onClick={() => void download(row)}>
                    PDF
                  </Button>
                  {row.status === "Draft" ? (
                    <Button size="sm" onClick={() => void issue(row)}>
                      Issue
                    </Button>
                  ) : row.status !== "Complied" ? (
                    <Button variant="outline" size="sm" onClick={() => setEditing(row)}>
                      Remind
                    </Button>
                  ) : null}
                </div>
              ) : (
                <div className="flex flex-wrap gap-2">
                  {row.status === "Open" && (
                    <Button
                      variant={selected.includes(value(row, "id")) ? "default" : "outline"}
                      size="sm"
                      aria-pressed={selected.includes(value(row, "id"))}
                      onClick={() =>
                        setSelected((ids) =>
                          ids.includes(value(row, "id"))
                            ? ids.filter((id) => id !== row.id)
                            : [...ids, value(row, "id")],
                        )
                      }
                    >
                      {selected.includes(value(row, "id")) ? "Selected" : "Select"}
                    </Button>
                  )}
                  {!["Complied", "Closed"].includes(value(row, "status")) && (
                    <Button variant="outline" size="sm" onClick={() => setEditing(row)}>
                      Record compliance
                    </Button>
                  )}
                </div>
              )
            }
          />
        )}
      </Panel>
      {!letters && selected.length > 0 && (
        <Panel title={`Draft letter for ${selected.length} incident(s)`}>
          <Form
            fields={[
              {
                name: "due",
                label: "Reply due date",
                type: "date",
                defaultValue: dueDate(),
                required: true,
              },
            ]}
            label="Create draft"
            submit={async (d) => {
              await client.command({
                kind: "create_letter",
                incident_ids: selected,
                due_date: text(d, "due"),
              });
              setSelected([]);
              setRefresh((r) => r + 1);
            }}
          />
        </Panel>
      )}
      {editing && (
        <Panel title={letters ? "Prepare reminder" : "Record compliance"}>
          <Form
            key={value(editing, "id")}
            fields={
              letters
                ? [
                    {
                      name: "due",
                      label: "New reply due date",
                      type: "date",
                      defaultValue: dueDate(),
                      required: true,
                    },
                  ]
                : [
                    { name: "reference", label: "Reply or voucher reference", required: true },
                    { name: "notes", label: "Compliance notes", required: true },
                  ]
            }
            submit={async (d) => {
              await client.command(
                letters
                  ? {
                      kind: "create_reminder",
                      letter_id: value(editing, "id"),
                      due_date: text(d, "due"),
                    }
                  : {
                      kind: "comply",
                      id: value(editing, "id"),
                      reference: text(d, "reference"),
                      notes: text(d, "notes"),
                    },
              );
              setEditing(null);
              setRefresh((r) => r + 1);
            }}
          />
        </Panel>
      )}
    </div>
  );
}
