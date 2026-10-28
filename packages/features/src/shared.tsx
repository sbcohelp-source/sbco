"use client";
import { useEffect, useId, useRef, useState, type FormEvent, type ReactNode } from "react";
import { client, type Query, type Row } from "@sbco/client";
import { Button } from "@sbco/ui/button";
import { Input } from "@sbco/ui/input";
import { Field, FieldGroup, FieldLabel } from "@sbco/ui/field";
import { Card, CardHeader, CardTitle, CardDescription, CardContent } from "@sbco/ui/card";
import { Table, TableHeader, TableHead, TableBody, TableRow, TableCell } from "@sbco/ui/table";
import { useShortcutBinding } from "./shortcuts";
export const value = (row: Row, key: string): string =>
  row[key] == null
    ? ""
    : typeof row[key] === "object"
      ? JSON.stringify(row[key])
      : String(row[key]);
export function useData<T>(query: Query, refresh = 0) {
  const key = JSON.stringify(query) + ":" + refresh;
  const [state, setState] = useState<{ key: string; data?: T; error?: string }>({ key: "" });
  const serialized = JSON.stringify(query);
  useEffect(() => {
    let active = true;
    client
      .query<T>(JSON.parse(serialized))
      .then((data) => {
        if (active) setState({ key, data });
      })
      .catch((error) => {
        if (active) setState({ key, error: error.message });
      });
    return () => {
      active = false;
    };
  }, [key, serialized]);
  return {
    data: state.key === key ? state.data : undefined,
    error: state.key === key ? state.error : undefined,
    loading: state.key !== key,
  };
}
export function Panel({
  title,
  description,
  children,
}: {
  title: string;
  description?: string;
  children: ReactNode;
}) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>
          <h2>{title}</h2>
        </CardTitle>
        {description && <CardDescription>{description}</CardDescription>}
      </CardHeader>
      <CardContent>{children}</CardContent>
    </Card>
  );
}
export type FormField = {
  name: string;
  label: string;
  type?: string;
  required?: boolean;
  defaultValue?: string;
  options?: { value: string; label: string }[];
};
export function Form({
  fields,
  submit,
  label = "Save",
  children,
  shortcut = true,
}: {
  fields: FormField[];
  submit: (data: FormData) => Promise<void>;
  label?: string;
  children?: ReactNode;
  shortcut?: boolean;
}) {
  const id = useId();
  const saveShortcut = useShortcutBinding("save");
  const submitting = useRef(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [done, setDone] = useState("");
  async function handle(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    if (submitting.current) return;
    submitting.current = true;
    const form = e.currentTarget;
    setBusy(true);
    setError("");
    setDone("");
    try {
      await submit(new FormData(form));
      setDone("Saved successfully");
    } catch (e) {
      setError(e instanceof Error ? e.message : "Unable to save");
    } finally {
      submitting.current = false;
      setBusy(false);
    }
  }
  return (
    <form
      data-shortcut-form={shortcut ? "true" : undefined}
      onSubmit={handle}
      className="flex flex-col gap-4"
    >
      <FieldGroup className="grid gap-4 sm:grid-cols-2">
        {fields.map((field) => (
          <Field key={field.name}>
            <FieldLabel htmlFor={`${id}-${field.name}`}>{field.label}</FieldLabel>
            {field.options ? (
              <select
                id={`${id}-${field.name}`}
                name={field.name}
                required={field.required}
                defaultValue={field.defaultValue}
                className="control"
              >
                {field.options.map((option) => (
                  <option key={option.value} value={option.value}>
                    {option.label}
                  </option>
                ))}
              </select>
            ) : (
              <Input
                id={`${id}-${field.name}`}
                name={field.name}
                type={field.type || "text"}
                required={field.required}
                defaultValue={field.defaultValue}
                autoComplete={field.type === "password" ? "new-password" : undefined}
              />
            )}
          </Field>
        ))}
      </FieldGroup>
      {children}
      {error && (
        <p role="alert" className="text-destructive">
          {error}
        </p>
      )}
      {done && (
        <p role="status" className="text-primary">
          {done}
        </p>
      )}
      <Button
        type="submit"
        disabled={busy}
        className="self-start"
        aria-keyshortcuts={shortcut ? saveShortcut : undefined}
      >
        {busy ? "Saving…" : label}
      </Button>
    </form>
  );
}
export function Grid({
  rows,
  columns,
  action,
}: {
  rows: Row[];
  columns: [string, string][];
  action?: (row: Row) => ReactNode;
}) {
  return (
    <div className="overflow-x-auto">
      <Table>
        <TableHeader>
          <TableRow>
            {columns.map(([key, name]) => (
              <TableHead key={key}>{name}</TableHead>
            ))}
            {action && <TableHead>Actions</TableHead>}
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.length ? (
            rows.map((row, index) => (
              <TableRow key={value(row, "id") || index}>
                {columns.map(([key]) => (
                  <TableCell key={key} className="max-w-80 break-words whitespace-normal">
                    {value(row, key) || "—"}
                  </TableCell>
                ))}
                {action && <TableCell>{action(row)}</TableCell>}
              </TableRow>
            ))
          ) : (
            <TableRow>
              <TableCell
                colSpan={columns.length + (action ? 1 : 0)}
                className="h-28 text-center text-muted-foreground"
              >
                No records match this view.
              </TableCell>
            </TableRow>
          )}
        </TableBody>
      </Table>
    </div>
  );
}
export function Loading({ error }: { error?: string }) {
  return error ? (
    <p role="alert" className="text-destructive">
      {error}
    </p>
  ) : (
    <p role="status" className="py-8 text-muted-foreground">
      Loading records…
    </p>
  );
}
export const text = (data: FormData, key: string) => String(data.get(key) || "").trim();
export const asOptions = (rows: Row[] = [], name = "name") =>
  rows.map((r) => ({ value: value(r, "id"), label: value(r, name) }));
