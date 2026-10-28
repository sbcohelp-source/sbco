"use client";

import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import {
  ArrowLeft,
  ArrowRight,
  CheckCircle2,
  ClipboardCheck,
  Building2,
  UsersRound,
  ShieldCheck,
} from "lucide-react";
import { client, type Actor, type Row } from "@sbco/client";
import { Button } from "@sbco/ui/button";
import { Badge } from "@sbco/ui/badge";
import {
  Card,
  CardHeader,
  CardTitle,
  CardDescription,
  CardContent,
  CardFooter,
} from "@sbco/ui/card";
import { Form, Loading, Panel, asOptions, text, useData } from "./shared";
import { Dashboard, Imports, Settings, SetupImport } from "./operations";
import { ShortcutSettings } from "./shortcuts";

export type OnboardingStatus = {
  step: string;
  completed: boolean;
  office_count: number;
  assigned_office_count: number;
  user_count: number | null;
  import_count: number | null;
  transaction_count: number;
};
const adminSteps = [
  ["welcome", "Welcome"],
  ["offices", "Offices"],
  ["team", "Your team"],
  ["preferences", "Preferences"],
  ["import", "First import"],
  ["ready", "Ready"],
];
const staffSteps = [
  ["welcome", "Welcome"],
  ["work", "Your work"],
  ["review", "Daily routine"],
  ["ready", "Ready"],
];

export function GettingStarted({
  actor,
  automatic = false,
}: {
  actor: Actor;
  automatic?: boolean;
}) {
  const [state, setState] = useState<OnboardingStatus | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [dismissed, setDismissed] = useState(false);
  const [retry, setRetry] = useState(0);
  const title = useRef<HTMLHeadingElement>(null);
  const saving = useRef(false);
  const admin = actor.role === "Administrator";
  const steps = admin ? adminSteps : staffSteps;
  const index = Math.max(
    0,
    steps.findIndex(([id]) => id === state?.step),
  );
  const step = steps[index][0];
  useEffect(() => {
    let active = true;
    client
      .query<OnboardingStatus>({ kind: "onboarding" })
      .then((result) => {
        if (active) {
          setState(result);
          setError("");
        }
      })
      .catch((e: Error) => {
        if (active) setError(e.message);
      });
    return () => {
      active = false;
    };
  }, [actor.id, retry]);
  const incomplete = state !== null && !state.completed;
  useEffect(() => {
    if (incomplete && !dismissed) title.current?.focus();
  }, [step, incomplete, dismissed]);

  async function refresh() {
    const result = await client.query<OnboardingStatus>({ kind: "onboarding" });
    setState(result);
    return result;
  }
  async function move(next: string, completed = false) {
    if (saving.current) return;
    saving.current = true;
    setBusy(true);
    setError("");
    try {
      await client.command({ kind: "save_onboarding", step: next, completed });
      await refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Unable to save your progress. Please try again.");
    } finally {
      saving.current = false;
      setBusy(false);
    }
  }
  if (dismissed || (automatic && state?.completed))
    return (
      <>
        <div className="mb-5 flex flex-wrap items-center justify-between gap-3">
          <p className="text-sm text-muted-foreground">
            {state?.completed
              ? "Your introduction is complete."
              : "Continue setting up whenever you are ready."}
          </p>
          {state?.completed ? (
            <Button variant="outline" asChild>
              <Link href="/onboarding">Review setup</Link>
            </Button>
          ) : (
            <Button variant="outline" onClick={() => setDismissed(false)}>
              Resume setup
            </Button>
          )}
        </div>
        <Dashboard />
      </>
    );
  if (!state)
    return (
      <Panel title="Getting your workspace ready">
        {error ? (
          <>
            <p role="alert" className="mb-4 text-destructive">
              {error}
            </p>
            <Button
              onClick={() => {
                setError("");
                setRetry((r) => r + 1);
              }}
            >
              Try again
            </Button>
            {automatic && (
              <Button variant="ghost" onClick={() => setDismissed(true)}>
                Go to overview
              </Button>
            )}
          </>
        ) : (
          <Loading />
        )}
      </Panel>
    );
  if (state.completed)
    return (
      <Panel
        title="Your introduction is complete"
        description="You can revisit these steps without deleting any offices, accounts or transactions."
      >
        <div className="flex flex-wrap gap-3">
          <Button disabled={busy} onClick={() => void move("welcome")}>
            Review setup
          </Button>
          <Button variant="outline" asChild>
            <Link href="/">Go to overview</Link>
          </Button>
        </div>
        {error && (
          <p role="alert" className="mt-4 text-destructive">
            {error}
          </p>
        )}
      </Panel>
    );

  return (
    <section aria-label="Setup wizard" className="flex flex-col gap-5">
      <Card>
        <CardHeader>
          <div className="mb-3 flex flex-wrap items-center justify-between gap-3">
            <Badge variant="secondary">{admin ? "Workspace setup" : "Your introduction"}</Badge>
            <span className="text-sm text-muted-foreground">
              Step {index + 1} of {steps.length}
            </span>
          </div>
          <CardTitle>
            <h2 ref={title} tabIndex={-1} className="outline-none">
              {step === "welcome" ? `Welcome to SBCO, ${actor.name}` : steps[index][1]}
            </h2>
          </CardTitle>
          <CardDescription>
            {admin
              ? "Set up your office at your own pace. Saved records and progress stay in this workspace."
              : "A short guide to your role, your work and the tools you will use each day."}
          </CardDescription>
        </CardHeader>
        <CardContent>
          <ol
            aria-label="Setup progress"
            className="grid grid-cols-2 gap-2 text-sm sm:grid-cols-3 xl:flex xl:flex-wrap xl:gap-5"
          >
            {steps.map(([id, label], i) => (
              <li
                key={id}
                aria-current={step === id ? "step" : undefined}
                className={step === id ? "font-semibold text-foreground" : "text-muted-foreground"}
              >
                {i + 1}. {label}
              </li>
            ))}
          </ol>
        </CardContent>
      </Card>

      <div key={step} className="flex flex-col gap-5">
        {step === "welcome" && (
          <Panel
            title={admin ? "Let’s prepare your workspace" : "Start with the work assigned to you"}
          >
            <p className="mb-5 text-sm leading-6">
              {client.isDesktop()
                ? "You are using the installed application. Your administrator manages where this workspace keeps its records."
                : "You are signed in to the shared workspace. Saved work is available to authorized colleagues on the same server."}{" "}
              No sample offices or transactions will be added automatically.
            </p>
            <div className="grid gap-5 md:grid-cols-3">
              {(admin
                ? [
                    [
                      Building2,
                      "1. Add your offices",
                      "Create the first sub office or import offices and staff from the setup workbook.",
                    ],
                    [
                      UsersRound,
                      "2. Prepare your team",
                      "Add staff, allocate office pools and review verification settings.",
                    ],
                    [
                      ClipboardCheck,
                      "3. Start daily work",
                      "Import a transaction workbook, check readiness and open the workspace.",
                    ],
                  ]
                : [
                    [
                      ShieldCheck,
                      "Your access",
                      actor.role === "Pa"
                        ? "You see only the offices allocated to you."
                        : "Review team work and handle the actions permitted to your role.",
                    ],
                    [
                      ClipboardCheck,
                      "Your daily workflow",
                      "Find work, record results and use reports to check progress.",
                    ],
                    [
                      UsersRound,
                      "Help when needed",
                      "Your administrator manages accounts, office allocation and recovery.",
                    ],
                  ]
              ).map(([Icon, label, description]) => {
                const Symbol = Icon as typeof Building2;
                return (
                  <div key={String(label)} className="flex flex-col gap-2">
                    <Symbol className="size-6 text-primary" aria-hidden="true" />
                    <h3 className="font-medium">{String(label)}</h3>
                    <p className="text-sm leading-6 text-muted-foreground">{String(description)}</p>
                  </div>
                );
              })}
            </div>
          </Panel>
        )}
        {step === "offices" && <OfficeSetup status={state} refresh={refresh} />}
        {step === "team" && <TeamSetup status={state} refresh={refresh} />}
        {step === "preferences" && (
          <>
            <Panel
              title="Review your office rules"
              description="Existing values are already saved. Save only if your office needs a change."
            >
              <p className="text-sm leading-6">
                Check sampling, reminders and the signatory with your supervisor. Keyboard
                preferences below apply to your account on this device.
              </p>
            </Panel>
            <Settings actor={actor} />
            <ShortcutSettings />
          </>
        )}
        {step === "import" && (
          <>
            <Panel
              title="Bring in your first transaction workbook"
              description="This step is optional. You can import from Excel imports later."
            >
              <p className="text-sm leading-6">
                Use the SO or BO template, keep account numbers as text and check office IDs before
                uploading. Wait for the import to complete and review any errors in import history.
                Imported records are real workspace data.
              </p>
            </Panel>
            <Imports actor={actor} includeSetup={false} />
          </>
        )}
        {step === "work" && (
          <Panel
            title={
              actor.role === "Pa" ? "Find and verify your vouchers" : "Review your team’s work"
            }
          >
            <p className="mb-4 text-sm leading-6">
              {actor.role === "Pa"
                ? `You currently have ${state.assigned_office_count} allocated offices and ${state.transaction_count} transactions in scope. Open Verification, search by account or transaction, compare the voucher and record the result. A mismatch needs a reason.`
                : "Use Supervisor review for high-value and sampled checks. Record your findings and notes; use Corrections when an existing decision needs to be changed."}
            </p>
            {actor.role === "Pa" && state.assigned_office_count === 0 && (
              <p role="status" className="mb-4 text-sm">
                No offices are assigned yet. Ask your administrator to allocate an office pool.
                Completing this introduction does not grant access.
              </p>
            )}
            <Button variant="outline" asChild>
              <Link href={actor.role === "Pa" ? "/verify" : "/reverify"}>Open your work queue</Link>
            </Button>
          </Panel>
        )}
        {step === "review" && (
          <>
            <Panel title="A simple daily routine">
              <ol className="ml-5 list-decimal text-sm leading-7">
                <li>Check that you are working in the right office and reporting period.</li>
                <li>
                  Record results with clear reasons and notes. Saved actions retain their history.
                </li>
                <li>
                  Review incidents, correspondence and daily or monthly reports within your
                  permissions.
                </li>
                <li>Sign out when finished. Contact your administrator for access or recovery.</li>
              </ol>
            </Panel>
            <ShortcutSettings />
          </>
        )}
        {step === "ready" && <Readiness actor={actor} status={state} />}
      </div>
      <Card>
        <CardContent className="pt-1">
          <p className="text-sm text-muted-foreground">
            Save each form before continuing. Continue saves your place; it does not submit
            unfinished fields.
          </p>
          {error && (
            <p role="alert" className="mt-3 text-destructive">
              {error}
            </p>
          )}
          {busy && (
            <p role="status" className="mt-3">
              Saving your progress…
            </p>
          )}
        </CardContent>
        <CardFooter className="flex-wrap justify-between gap-3">
          <Button variant="ghost" disabled={busy} onClick={() => setDismissed(true)}>
            Do this later
          </Button>
          <div className="flex flex-wrap gap-3">
            {index > 0 && (
              <Button
                variant="outline"
                disabled={busy}
                onClick={() => void move(steps[index - 1][0])}
              >
                <ArrowLeft data-icon="inline-start" />
                Back
              </Button>
            )}
            {step === "ready" ? (
              <Button
                disabled={busy || (admin && state.office_count === 0)}
                onClick={() => void move("ready", true)}
              >
                <CheckCircle2 data-icon="inline-start" />
                Finish setup
              </Button>
            ) : (
              <Button disabled={busy} onClick={() => void move(steps[index + 1][0])}>
                Continue
                <ArrowRight data-icon="inline-end" />
              </Button>
            )}
          </div>
        </CardFooter>
      </Card>
    </section>
  );
}

function OfficeSetup({
  status,
  refresh,
}: {
  status: OnboardingStatus;
  refresh: () => Promise<OnboardingStatus>;
}) {
  return (
    <>
      <Panel
        title="Add your first sub office"
        description={`${status.office_count} offices are already saved. Existing offices are kept; you can continue if they are ready.`}
      >
        <Form
          label="Save office"
          fields={[
            { name: "id", label: "Office ID", required: true },
            { name: "name", label: "Office name", required: true },
          ]}
          submit={async (data) => {
            // The first-office form only creates; updating a known ID belongs in Offices & pools.
            const offices = await client.query<Row[]>({ kind: "offices" });
            if (offices.some((office) => office.id === text(data, "id")))
              throw new Error(
                "This office ID already exists. Use Offices & pools to edit it, or continue with your existing offices.",
              );
            await client.command({
              kind: "save_office",
              id: text(data, "id"),
              name: text(data, "name"),
              office_type: "SO",
              parent_id: null,
            });
            await refresh();
          }}
        />
        <p className="mt-4 text-sm text-muted-foreground">
          Add branch offices and parent SO links later in{" "}
          <Link className="underline underline-offset-4" href="/offices">
            Offices & pools
          </Link>
          .
        </p>
      </Panel>
      <details className="rounded-xl border p-4">
        <summary className="cursor-pointer font-medium">
          Set up several offices and staff from Excel
        </summary>
        <div className="mt-4 flex flex-col gap-4">
          <TemplateLink />
          <SetupImport onSaved={refresh} />
        </div>
      </details>
    </>
  );
}

function TemplateLink() {
  const [error, setError] = useState("");
  return (
    <>
      <Button variant="outline" asChild>
        <a
          href="/templates/SBCO_Setup_Template.xlsx"
          download
          onClick={(event) => {
            if (client.isDesktop()) {
              event.preventDefault();
              void client
                .saveTemplate("SBCO_Setup_Template")
                .catch((e: Error) => setError(e.message));
            }
          }}
        >
          Download setup template
        </a>
      </Button>
      {error && (
        <p role="alert" className="text-destructive">
          {error}
        </p>
      )}
    </>
  );
}

function TeamSetup({
  status,
  refresh,
}: {
  status: OnboardingStatus;
  refresh: () => Promise<OnboardingStatus>;
}) {
  const [version, setVersion] = useState(0);
  const { data: users, error: userError } = useData<Row[]>({ kind: "users" }, version);
  const { data: offices, error: officeError } = useData<Row[]>({ kind: "offices" }, version);
  const { data: pools, error: poolError } = useData<Row[]>({ kind: "pools" }, version);
  const available = offices?.filter(
    (office) => !pools?.some((pool) => (pool.offices as string[])?.includes(String(office.id))),
  );
  async function updated() {
    setVersion((v) => v + 1);
    await refresh();
  }
  return (
    <>
      <Panel
        title="Give each colleague their own account"
        description={`${status.user_count ?? 0} active users · ${status.assigned_office_count} offices allocated to a PA`}
      >
        <p className="mb-4 text-sm leading-6">
          Postal Assistants verify vouchers in allocated office pools. Supervisors review work.
          Administrators manage setup and access. You can continue and prepare your team later; an
          administrator account cannot perform PA verification.
        </p>
        <Form
          label="Add staff member"
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
              options: [
                { value: "Pa", label: "Postal Assistant" },
                { value: "Supervisor", label: "Supervisor" },
              ],
            },
          ]}
          submit={async (data) => {
            await client.command({
              kind: "create_user",
              name: text(data, "name"),
              email: text(data, "email"),
              password: String(data.get("password") || ""),
              role: text(data, "role"),
            });
            await updated();
          }}
        />
        <p className="mt-4 text-sm text-muted-foreground">
          Share initial passwords privately. Staff can change them in My account. For imported
          staff, set a password in{" "}
          <Link href="/users" className="underline underline-offset-4">
            Users
          </Link>{" "}
          before they sign in.
        </p>
      </Panel>
      <Panel
        title="Allocate an office to a Postal Assistant"
        description="An office pool controls which work a PA can see. This starter form creates one pool for one office."
      >
        {userError || officeError || poolError ? (
          <Loading error={userError || officeError || poolError} />
        ) : !users || !offices || !pools ? (
          <Loading />
        ) : !users.some((u) => u.role === "Pa" && u.active) ? (
          <p className="text-sm">
            Add an active Postal Assistant first, then allocate their office here.
          </p>
        ) : !available?.length ? (
          <p className="text-sm">
            No offices are waiting for a pool. Manage existing assignments in{" "}
            <Link href="/offices" className="underline underline-offset-4">
              Offices & pools
            </Link>
            .
          </p>
        ) : (
          <Form
            key={version}
            label="Assign office"
            fields={[
              { name: "name", label: "Pool name", required: true },
              { name: "office", label: "Office", options: asOptions(available), required: true },
              {
                name: "pa",
                label: "Postal Assistant",
                options: asOptions(users.filter((u) => u.role === "Pa" && u.active)),
                required: true,
              },
            ]}
            submit={async (data) => {
              const settings = await client.query<Row>({ kind: "settings" });
              await client.command({
                kind: "save_pool",
                id: null,
                name: text(data, "name"),
                offices: [text(data, "office")],
                pa_user: text(data, "pa"),
                random_percent: Number(settings.random_percent),
              });
              await updated();
            }}
          />
        )}
      </Panel>
    </>
  );
}

function Readiness({ actor, status }: { actor: Actor; status: OnboardingStatus }) {
  const admin = actor.role === "Administrator";
  return (
    <Panel title={admin ? "Check your workspace before you start" : "You’re ready to explore"}>
      <dl className="grid gap-4 sm:grid-cols-2">
        <div>
          <dt className="font-medium">{admin ? "Offices saved" : "Offices in your scope"}</dt>
          <dd>{status.office_count}</dd>
        </div>
        <div>
          <dt className="font-medium">Offices allocated to a PA</dt>
          <dd>{status.assigned_office_count}</dd>
        </div>
        {admin && (
          <div>
            <dt className="font-medium">Active users</dt>
            <dd>{status.user_count}</dd>
          </div>
        )}
        <div>
          <dt className="font-medium">Transactions in your scope</dt>
          <dd>{status.transaction_count}</dd>
        </div>
      </dl>
      {admin && status.office_count === 0 && (
        <p role="alert" className="mt-5 text-destructive">
          Add at least one office before finishing setup. Use Back to return to Offices.
        </p>
      )}
      {admin && status.assigned_office_count < status.office_count && (
        <p className="mt-5 text-sm">
          Some offices are not allocated to a PA. You can finish setup, but allocate their pools
          before starting verification.
        </p>
      )}
      {status.transaction_count === 0 && (
        <p className="mt-4 text-sm">
          No transactions yet.{" "}
          {admin
            ? "Import a workbook from Excel imports when ready."
            : "Your team will import transactions before verification starts."}
        </p>
      )}
      <p className="mt-5 text-sm leading-6 text-muted-foreground">
        {admin
          ? "Keep a recovery copy on separate storage and have the office operator check reports and letters. Finishing this guide records your progress; it does not certify office acceptance."
          : "Your account permissions stay the same. You can reopen this guide from Get started and change keyboard shortcuts in My account."}
      </p>
    </Panel>
  );
}
