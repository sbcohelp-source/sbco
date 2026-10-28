"use client";

import Link from "next/link";
import { useEffect, useId, useRef, useState } from "react";
import {
  client,
  getTrainingContext,
  setTrainingContext,
  type TrainingContext,
  type TrainingStatus,
} from "@sbco/client";
import { Badge } from "@sbco/ui/badge";
import { Button } from "@sbco/ui/button";
import { Field, FieldLabel } from "@sbco/ui/field";
import { Input } from "@sbco/ui/input";
import { Panel } from "./shared";

type PracticeRole = TrainingContext["role"];
type Selection = TrainingContext;
const roleNames: Record<PracticeRole, string> = {
  Administrator: "Administrator",
  Supervisor: "Supervisor",
  Pa: "Postal Assistant",
};
const countLabels: [keyof TrainingStatus["counts"], string][] = [
  ["offices", "Offices"],
  ["users", "Users"],
  ["pools", "Pools"],
  ["imports", "Imports"],
  ["transactions", "Transactions"],
  ["incidents", "Incidents"],
  ["letters", "Letters"],
];
function selection(): { context: Selection | null; error: string } {
  try {
    return { context: getTrainingContext(), error: "" };
  } catch (cause) {
    return {
      context: null,
      error: cause instanceof Error ? cause.message : "Training selection could not be read.",
    };
  }
}
function message(cause: unknown): string {
  return cause instanceof Error
    ? cause.message
    : "Unable to update training mode. Please try again.";
}
function changeWorkspace(context: Selection | null) {
  // The client freezes the current page's selection. A reload starts a new page
  // only after the next selection is saved, so old forms cannot switch databases.
  setTrainingContext(context);
  window.location.reload();
}

export function TrainingBanner() {
  const [current] = useState(selection);
  const [error, setError] = useState("");
  function leave() {
    try {
      changeWorkspace(null);
    } catch (cause) {
      setError(message(cause));
    }
  }
  if (current.error)
    return (
      <section
        aria-label="Workspace mode"
        className="flex flex-col gap-2 border-b bg-secondary px-5 py-3"
      >
        <p role="alert">
          Training selection needs attention: {current.error} Return to live mode explicitly before
          continuing.
        </p>
        <Button type="button" variant="outline" size="sm" onClick={leave} className="self-start">
          Return to live mode
        </Button>
        {error && (
          <p role="alert" className="text-destructive">
            {error}
          </p>
        )}
      </section>
    );
  if (!current.context)
    return (
      <section
        aria-label="Workspace mode"
        className="flex flex-wrap items-center gap-3 border-b px-5 py-2 text-sm"
      >
        <span>Live workspace</span>
        <Link href="/training" className="underline underline-offset-4">
          Enable training
        </Link>
      </section>
    );
  return (
    <section
      aria-label="Workspace mode"
      className="flex flex-wrap items-center gap-3 border-b bg-secondary px-5 py-3 text-secondary-foreground"
    >
      <strong>TRAINING MODE — practice data only</strong>
      <span className="text-sm">Practice role: {roleNames[current.context.role]}</span>
      <Link href="/training" className="text-sm underline underline-offset-4">
        Training controls
      </Link>
      <Button type="button" variant="outline" size="sm" onClick={leave}>
        Disable training
      </Button>
      {error && (
        <p role="alert" className="w-full text-destructive">
          {error}
        </p>
      )}
    </section>
  );
}

export function TrainingControls() {
  const [current] = useState(selection);
  const [status, setStatus] = useState<TrainingStatus | null>(null);
  const [review, setReview] = useState<TrainingStatus | null>(null);
  const [confirmation, setConfirmation] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [retry, setRetry] = useState(0);
  const working = useRef(false);
  const confirmInput = useRef<HTMLInputElement>(null);
  const reviewButton = useRef<HTMLButtonElement>(null);
  const id = useId();
  const active = current.context;
  const valid = !!active && status?.available === true && active.generation === status.generation;

  useEffect(() => {
    if (current.error) return;
    let mounted = true;
    client
      .trainingStatus()
      .then((result) => {
        if (mounted) {
          setStatus(result);
          setError("");
        }
      })
      .catch((cause: unknown) => {
        if (mounted) setError(message(cause));
      });
    return () => {
      mounted = false;
    };
  }, [current.error, retry]);
  useEffect(() => {
    if (review) confirmInput.current?.focus();
  }, [review]);

  function leave() {
    if (working.current) return;
    try {
      changeWorkspace(null);
    } catch (cause) {
      setError(message(cause));
    }
  }
  function chooseRole(role: PracticeRole) {
    if (!active || !valid || working.current) return;
    try {
      changeWorkspace({ generation: active.generation, role });
    } catch (cause) {
      setError(message(cause));
    }
  }
  async function act(action: "enable" | "review" | "reset") {
    if (working.current || current.error) return;
    if (action !== "enable" && (!active || !valid)) return;
    if (action === "reset" && (!review?.generation || confirmation !== "DELETE TRAINING")) return;
    working.current = true;
    setBusy(true);
    setError("");
    setNotice("");
    try {
      if (action === "enable") {
        const result = await client.enableTraining();
        if (!result.available || !result.generation)
          throw new Error("Training workspace is not ready. Please try again.");
        changeWorkspace({ generation: result.generation, role: "Administrator" });
        return;
      }
      const latest = await client.trainingStatus();
      setStatus(latest);
      if (!latest.available || !latest.generation || latest.generation !== active?.generation) {
        setReview(null);
        setConfirmation("");
        setNotice(
          "Your training workspace changed. Disable training to return to live mode, then enable it again.",
        );
        return;
      }
      if (action === "review") {
        setReview(latest);
        setConfirmation("");
        return;
      }
      if (!review) return;
      if (
        latest.generation !== review?.generation ||
        countLabels.some(([key]) => latest.counts[key] !== review.counts[key])
      ) {
        setReview(latest);
        setConfirmation("");
        setNotice("Training records changed. Review the updated counts and confirm again.");
        return;
      }
      await client.resetTraining({
        generation: latest.generation,
        confirmation: "DELETE TRAINING",
      });
      changeWorkspace(null);
    } catch (cause) {
      setError(message(cause));
      if (action === "reset") {
        setReview(null);
        setConfirmation("");
      }
    } finally {
      working.current = false;
      setBusy(false);
    }
  }

  return (
    <div className="flex flex-col gap-5">
      <Panel
        title="Your training workspace"
        description="Practice safely while signed in to your own account."
      >
        <div className="flex flex-col gap-4" aria-busy={busy}>
          <p className="text-sm leading-6">
            The first enable creates sample offices, accounts and 24 transactions in an isolated
            practice workspace. Records and settings you create there stay separate from live office
            work and other users’ training.
          </p>
          <p className="text-sm leading-6">
            Training mode applies to this browser tab or desktop session. You can practise any role
            without changing your real permissions. Password changes and backup/restore controls are
            unavailable while training.
          </p>
          {current.error ? (
            <>
              <p role="alert" className="text-destructive">
                {current.error} No workspace switch was made.
              </p>
              <Button type="button" variant="outline" onClick={leave} className="self-start">
                Return to live mode
              </Button>
            </>
          ) : !status ? (
            error ? (
              <Button
                type="button"
                variant="outline"
                className="self-start"
                onClick={() => setRetry((value) => value + 1)}
              >
                Retry training status
              </Button>
            ) : (
              <p role="status">Loading training status…</p>
            )
          ) : (
            <>
              <Badge variant={active ? "secondary" : "outline"}>
                {active ? "TRAINING selection active" : "LIVE workspace active"}
              </Badge>
              {active ? (
                <>
                  {valid ? (
                    <Field data-disabled={busy}>
                      <FieldLabel htmlFor={`${id}-role`}>Practice role</FieldLabel>
                      <select
                        id={`${id}-role`}
                        className="control"
                        value={active.role}
                        disabled={busy}
                        onChange={(event) => chooseRole(event.target.value as PracticeRole)}
                      >
                        {Object.entries(roleNames).map(([role, name]) => (
                          <option key={role} value={role}>
                            {name}
                          </option>
                        ))}
                      </select>
                    </Field>
                  ) : (
                    <p role="alert" className="text-destructive">
                      This training selection no longer matches your saved workspace. Return to live
                      mode before enabling training again.
                    </p>
                  )}
                  <p className="text-sm text-muted-foreground">
                    Disable training to return to live work. Your practice records are kept for the
                    next time you enable training.
                  </p>
                  <Button
                    type="button"
                    variant="outline"
                    disabled={busy}
                    onClick={leave}
                    className="self-start"
                  >
                    Disable training and return to live
                  </Button>
                </>
              ) : (
                <>
                  {status.available && (
                    <p className="text-sm">
                      Your saved practice workspace is ready to resume. It will not be replaced.
                    </p>
                  )}
                  <Button
                    type="button"
                    disabled={busy}
                    onClick={() => void act("enable")}
                    className="self-start"
                  >
                    {busy
                      ? "Opening training…"
                      : status.available
                        ? "Resume training"
                        : "Enable training"}
                  </Button>
                </>
              )}
              {status.available && (
                <dl
                  aria-label="Training record counts"
                  className="grid grid-cols-2 gap-3 sm:grid-cols-4"
                >
                  {countLabels.map(([key, label]) => (
                    <div key={key}>
                      <dt className="text-sm text-muted-foreground">{label}</dt>
                      <dd className="font-semibold">
                        {(review || status).counts[key].toLocaleString("en-IN")}
                      </dd>
                    </div>
                  ))}
                </dl>
              )}
            </>
          )}
          {notice && <p role="status">{notice}</p>}
          {error && (
            <p role="alert" className="text-destructive">
              {error}
            </p>
          )}
        </div>
      </Panel>
      {valid && (
        <Panel
          title="Delete your training data"
          description="Start over by removing this entire practice workspace."
        >
          <div className="flex flex-col gap-4">
            <p className="text-sm leading-6">
              This deletes all sample records and all records you created while training, including
              practice users, offices, transactions, incidents and letters. Your live office data
              and other users’ practice are kept. Backup files and downloaded files are not deleted.
            </p>
            {!review ? (
              <Button
                ref={reviewButton}
                type="button"
                variant="destructive-outline"
                disabled={busy}
                onClick={() => void act("review")}
                className="self-start"
              >
                {busy ? "Checking training records…" : "Review training deletion"}
              </Button>
            ) : (
              <section aria-label="Confirm training deletion" className="flex flex-col gap-4">
                <p>
                  Review the training counts above. Deletion returns this tab or desktop session to
                  live mode.
                </p>
                <Field data-disabled={busy}>
                  <FieldLabel htmlFor={`${id}-confirmation`}>
                    Type DELETE TRAINING to confirm
                  </FieldLabel>
                  <Input
                    ref={confirmInput}
                    id={`${id}-confirmation`}
                    value={confirmation}
                    onChange={(event) => setConfirmation(event.target.value)}
                    disabled={busy}
                    autoComplete="off"
                    spellCheck={false}
                  />
                </Field>
                <div className="flex flex-wrap gap-3">
                  <Button
                    type="button"
                    variant="destructive"
                    disabled={busy || confirmation !== "DELETE TRAINING"}
                    onClick={() => void act("reset")}
                  >
                    {busy ? "Deleting training data…" : "Delete all my training data"}
                  </Button>
                  <Button
                    type="button"
                    variant="outline"
                    disabled={busy}
                    onClick={() => {
                      setReview(null);
                      setConfirmation("");
                      requestAnimationFrame(() => reviewButton.current?.focus());
                    }}
                  >
                    Cancel
                  </Button>
                </div>
              </section>
            )}
          </div>
        </Panel>
      )}
    </div>
  );
}
