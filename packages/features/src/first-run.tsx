"use client";
import { useEffect, useRef, useState, type FormEvent } from "react";
import { client } from "@sbco/client";
import { Button } from "@sbco/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from "@sbco/ui/card";
import { Field, FieldGroup, FieldLabel } from "@sbco/ui/field";
import { Input } from "@sbco/ui/input";

type Problem = { message: string; field?: "name" | "password" | "confirm_password" };

export function OfflineSetupWizard({ onCreated }: { onCreated: () => void }) {
  const [step, setStep] = useState<"welcome" | "administrator">("welcome");
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<Problem | null>(null);
  const submitting = useRef(false);
  const heading = useRef<HTMLHeadingElement>(null);
  const form = useRef<HTMLFormElement>(null);
  const error = useRef<HTMLParagraphElement>(null);

  useEffect(() => {
    heading.current?.focus();
  }, [step]);
  useEffect(() => {
    if (!problem) return;
    const field = problem.field && form.current?.elements.namedItem(problem.field);
    if (field instanceof HTMLInputElement) field.focus();
    else error.current?.focus();
  }, [problem]);

  async function createAdministrator(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (submitting.current) return;
    const currentForm = event.currentTarget;
    if (!currentForm.reportValidity()) return;
    const data = new FormData(currentForm);
    const password = String(data.get("password") || "");
    const confirmation = String(data.get("confirm_password") || "");
    if (!name.trim()) {
      setProblem({ field: "name", message: "Enter the administrator's full name." });
      return;
    }
    if (Array.from(password).length < 12) {
      setProblem({ field: "password", message: "Use a password with at least 12 characters." });
      return;
    }
    if (password !== confirmation) {
      setProblem({
        field: "confirm_password",
        message: "The passwords do not match. Enter the same password again.",
      });
      return;
    }
    if (!client.isDesktop()) {
      setProblem({ message: "Open the installed SBCO application to set up this computer." });
      return;
    }
    submitting.current = true;
    setBusy(true);
    setProblem(null);
    try {
      await client.setup(name.trim(), { email: email.trim(), password });
      currentForm.reset();
      onCreated();
    } catch (cause) {
      setProblem({
        message:
          cause instanceof Error
            ? cause.message
            : "Unable to create the administrator. Please try again.",
      });
    } finally {
      submitting.current = false;
      setBusy(false);
    }
  }

  return (
    <main className="mx-auto flex min-h-screen max-w-xl items-center p-5">
      <Card className="w-full">
        <CardHeader>
          <p role="status" className="text-sm text-muted-foreground">
            Step {step === "welcome" ? "1" : "2"} of 2
          </p>
          <CardTitle>
            <h1 ref={heading} tabIndex={-1}>
              Set up this offline workspace
            </h1>
          </CardTitle>
          <CardDescription>
            {step === "welcome"
              ? "Welcome to SBCO on this computer."
              : "Create the administrator who will manage users and office setup."}
          </CardDescription>
        </CardHeader>
        {step === "welcome" ? (
          <>
            <CardContent>
              <ul className="flex list-disc flex-col gap-3 pl-5">
                <li>
                  Your office records stay on this computer and can be used without an internet
                  connection.
                </li>
                <li>
                  A daily backup is created while the app is open. The latest 14 daily backups are
                  kept on this computer.
                </li>
                <li>
                  After signing in, save an additional backup to your office’s backup drive and
                  import your setup and transactions.
                </li>
              </ul>
            </CardContent>
            <CardFooter>
              <Button type="button" data-setup-start onClick={() => setStep("administrator")}>
                Set up this computer
              </Button>
            </CardFooter>
          </>
        ) : (
          <form
            ref={form}
            onSubmit={createAdministrator}
            aria-busy={busy}
            className="flex flex-col gap-5"
          >
            <CardContent>
              <FieldGroup>
                <Field data-disabled={busy} data-invalid={problem?.field === "name"}>
                  <FieldLabel htmlFor="setup-name">Full name</FieldLabel>
                  <Input
                    id="setup-name"
                    name="name"
                    autoComplete="name"
                    required
                    disabled={busy}
                    value={name}
                    onChange={(event) => setName(event.target.value)}
                    aria-invalid={problem?.field === "name"}
                    aria-describedby={problem?.field === "name" ? "setup-error" : undefined}
                  />
                </Field>
                <Field data-disabled={busy}>
                  <FieldLabel htmlFor="setup-email">Email</FieldLabel>
                  <Input
                    id="setup-email"
                    name="email"
                    type="email"
                    autoComplete="username"
                    required
                    disabled={busy}
                    value={email}
                    onChange={(event) => setEmail(event.target.value)}
                  />
                </Field>
                <Field data-disabled={busy} data-invalid={problem?.field === "password"}>
                  <FieldLabel htmlFor="setup-password">Password (12+ characters)</FieldLabel>
                  <Input
                    id="setup-password"
                    name="password"
                    type="password"
                    autoComplete="new-password"
                    minLength={12}
                    required
                    disabled={busy}
                    aria-invalid={problem?.field === "password"}
                    aria-describedby={problem?.field === "password" ? "setup-error" : undefined}
                  />
                </Field>
                <Field data-disabled={busy} data-invalid={problem?.field === "confirm_password"}>
                  <FieldLabel htmlFor="setup-confirm-password">Confirm password</FieldLabel>
                  <Input
                    id="setup-confirm-password"
                    name="confirm_password"
                    type="password"
                    autoComplete="new-password"
                    minLength={12}
                    required
                    disabled={busy}
                    aria-invalid={problem?.field === "confirm_password"}
                    aria-describedby={
                      problem?.field === "confirm_password" ? "setup-error" : undefined
                    }
                  />
                </Field>
                {problem && (
                  <p
                    ref={error}
                    id="setup-error"
                    role="alert"
                    tabIndex={-1}
                    className="text-destructive"
                  >
                    {problem.message}
                  </p>
                )}
                <p className="text-sm text-muted-foreground">
                  Keep these details safe. You will use this account to sign in after setup.
                </p>
              </FieldGroup>
            </CardContent>
            <CardFooter className="flex-wrap gap-3">
              <Button
                type="button"
                variant="outline"
                disabled={busy}
                onClick={() => {
                  setProblem(null);
                  setStep("welcome");
                }}
              >
                Back
              </Button>
              <Button type="submit" disabled={busy}>
                {busy ? "Creating administrator…" : "Create administrator"}
              </Button>
            </CardFooter>
          </form>
        )}
      </Card>
    </main>
  );
}

export function ServerConnectionWizard({
  serverUrl = "",
  onConnected,
}: {
  serverUrl?: string;
  onConnected: () => void;
}) {
  const [address, setAddress] = useState(serverUrl);
  const [problem, setProblem] = useState("");
  const [busy, setBusy] = useState(false);
  const submitting = useRef(false);
  const input = useRef<HTMLInputElement>(null);
  async function connect(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (submitting.current) return;
    try {
      const url = new URL(address.trim());
      if (
        url.protocol !== "https:" ||
        !url.hostname ||
        url.username ||
        url.password ||
        url.pathname !== "/" ||
        url.search ||
        url.hash
      )
        throw new Error("Invalid server address");
    } catch {
      setProblem(
        "Enter only the HTTPS server address, without a path, account details, query or fragment.",
      );
      input.current?.focus();
      return;
    }
    submitting.current = true;
    setBusy(true);
    setProblem("");
    try {
      await client.configureConnection(address.trim());
      onConnected();
    } catch (cause) {
      setProblem(
        cause instanceof Error
          ? cause.message
          : "Unable to connect. Check the server address and try again.",
      );
    } finally {
      submitting.current = false;
      setBusy(false);
    }
  }
  return (
    <main className="mx-auto flex min-h-screen max-w-xl items-center p-5">
      <Card className="w-full">
        <CardHeader>
          <CardTitle>
            <h1>Connect to your SBCO server</h1>
          </CardTitle>
          <CardDescription>
            Use the secure server address supplied by your administrator. This client needs a
            network connection; office data and accounts stay on the server.
          </CardDescription>
        </CardHeader>
        <form onSubmit={connect} aria-busy={busy}>
          <CardContent className="flex flex-col gap-4">
            <Field>
              <FieldLabel htmlFor="server-url">Server address</FieldLabel>
              <Input
                ref={input}
                id="server-url"
                name="server_url"
                type="url"
                required
                autoComplete="url"
                placeholder="https://sbco.example.org"
                value={address}
                onChange={(event) => setAddress(event.target.value)}
                disabled={busy}
                aria-invalid={!!problem}
                aria-describedby={problem ? "connection-problem" : undefined}
              />
            </Field>
            {problem && (
              <p id="connection-problem" role="alert" className="text-sm text-destructive">
                {problem}
              </p>
            )}
            <p className="text-sm text-muted-foreground">
              The application checks the secure connection and server compatibility before saving
              this address. You will sign in with your assigned account next.
            </p>
          </CardContent>
          <CardFooter>
            <Button type="submit" disabled={busy}>
              {busy ? "Connecting…" : "Connect to server"}
            </Button>
          </CardFooter>
        </form>
      </Card>
    </main>
  );
}
