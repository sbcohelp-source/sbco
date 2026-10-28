"use client";

import Link from "next/link";
import { useId, useState } from "react";
import type { Actor } from "@sbco/client";
import { Button } from "@sbco/ui/button";
import { Field, FieldLabel } from "@sbco/ui/field";
import { Input } from "@sbco/ui/input";
import { Panel } from "./shared";

type HelpLink = { label: string; href: string; roles?: Actor["role"][] };
type Topic = {
  title: string;
  description: string;
  steps: string[];
  keywords: string;
  links: HelpLink[];
};
const administrators: Actor["role"][] = ["Administrator"];
const managers: Actor["role"][] = ["Administrator", "Supervisor"];
const topics: Topic[] = [
  {
    title: "About SBCO and support",
    description: "Author: S K Singh",
    steps: [
      "For help with SBCO, contact sbcohelp@gmail.com. Include the screen name, steps and error message. Do not include passwords or private customer records.",
    ],
    keywords: "author contact support email S K Singh sbcohelp@gmail.com",
    links: [{ label: "Email sbcohelp@gmail.com", href: "mailto:sbcohelp@gmail.com" }],
  },
  {
    title: "Set up your workspace",
    description: "Start with the guide for your role.",
    steps: [
      "On a new standalone offline installation, choose Set up this computer, create the administrator and sign in. Keep the account details safe.",
      "In the installed shared-server client, enter the HTTPS server address supplied by your administrator, choose Connect to server, then sign in with your assigned account. This client needs a network connection to that server and does not create a local database or administrator.",
      "Use Change server to connect the installed client to a different server. This signs you out first; review the displayed server address before entering your credentials.",
      "Get started guides administrators through offices, staff, preferences and the first import. Postal Assistants and Supervisors receive a shorter guide to their daily work.",
      "Save each form before continuing. Continue saves your place; it does not submit unfinished fields. You can leave the guide and resume later.",
    ],
    keywords:
      "first run onboarding installation introduction welcome begin connected client HTTPS server address connection",
    links: [{ label: "Open Get started", href: "/onboarding" }],
  },
  {
    title: "Offices and pool assignments",
    description: "Use the correct office IDs and allocate work to a Postal Assistant.",
    steps: [
      "An administrator creates sub offices (SO) and branch offices (BO), with each BO linked to its parent SO.",
      "Create a pool, select its offices and assign a Postal Assistant. A PA sees work only for allocated offices.",
      "If a PA cannot find an office or voucher, check the pool allocation before importing the same workbook again.",
    ],
    keywords: "SO BO parent allocation assignment staff no records",
    links: [{ label: "Open Offices & pools", href: "/offices", roles: managers }],
  },
  {
    title: "Users, roles and passwords",
    description: "Give each colleague an individual account.",
    steps: [
      "Administrators manage accounts and access. Postal Assistants verify their allocated vouchers. Supervisors handle review work.",
      "After importing users through the setup workbook, set each new user’s password in Users. Share initial passwords privately.",
      "Change your own password in My account. For a forgotten password, ask your administrator to reset it; there is no email recovery link.",
      "Disabling an account or changing its role ends its existing sessions. Keep at least one active administrator.",
    ],
    keywords: "team login sign in forgotten forgot reset disable active account password access",
    links: [
      { label: "Open Users", href: "/users", roles: administrators },
      { label: "Open My account", href: "/account" },
    ],
  },
  {
    title: "Import setup and transaction workbooks",
    description: "Use the supplied Excel templates and check the import result.",
    steps: [
      "Download the Setup, SO transactions or BO transactions template from Excel imports. Follow its instructions and keep the expected sheet names and columns.",
      "Enter account and office IDs as text to preserve leading zeros. Keep credit and debit amounts in their separate columns.",
      "For a setup workbook, preview first, correct every error and then import. The setup workbook is saved together or not at all.",
      "For transactions, wait for Completed and review the inserted and duplicate counts. Failed imports show a reason; correct the source or follow the available retry action.",
    ],
    keywords: "xlsx excel upload template duplicates preview long book longbook leading zeros",
    links: [{ label: "Open Excel imports", href: "/imports", roles: managers }],
  },
  {
    title: "Verify vouchers",
    description: "Work from the voucher and record the result for the selected account.",
    steps: [
      "Open the correct queue: Verification, BO verification, Agent entries or RD default entries. Use office, status and account search to find the voucher.",
      "Check the displayed account, transaction, amounts and source details before selecting a result.",
      "Mark matched when the details agree. For a mismatch or missing voucher, select the required reason and add useful notes.",
      "A high-value voucher or random sample may still need supervisor review before its result is final.",
    ],
    keywords: "matched mismatch voucher missing account search primary BO agent RD default",
    links: [
      { label: "Open Verification", href: "/verify" },
      { label: "Open BO verification", href: "/bo-verification" },
      { label: "Open Agent entries", href: "/agent-verification" },
      { label: "Open RD default entries", href: "/rd-default" },
    ],
  },
  {
    title: "Supervisor review",
    description: "Complete the second check for records that require it.",
    steps: [
      "Open Supervisor review to see vouchers selected by the high-value or random-sampling rules.",
      "Check the PA result, voucher and notes, then record the review outcome with any required reason.",
      "Do not assume the PA result is final when the voucher is waiting for supervisor review.",
    ],
    keywords: "reverify second check high value random sampling final result",
    links: [{ label: "Open Supervisor review", href: "/reverify", roles: managers }],
  },
  {
    title: "Correct an earlier result",
    description: "Use the correction workflow so the history remains available.",
    steps: [
      "Find the completed voucher and choose Request correction where that action is available. Explain why the recorded result needs to change.",
      "An authorized reviewer handles the request under Corrections. Earlier and later values remain in the history.",
      "If the record changed while you were working, reload it and review the current details before trying again.",
    ],
    keywords: "revision stale edit undo mistake change history correction",
    links: [
      { label: "Find a voucher", href: "/verify" },
      { label: "Open Corrections", href: "/corrections", roles: managers },
    ],
  },
  {
    title: "Incidents and compliance",
    description: "Track objections through their resolution.",
    steps: [
      "Open Incidents to review voucher follow-up and mistake-advice objections for offices you can access.",
      "Record the appropriate compliance or status update when a reply or supporting voucher arrives.",
      "Reopening an objection affects progress-report balances. Use the history to understand the changes.",
    ],
    keywords: "objection MAP mistake advice voucher follow up comply reopen settle close",
    links: [{ label: "Open Incidents", href: "/incidents" }],
  },
  {
    title: "Letters and reminders",
    description: "Review correspondence before issuing it.",
    steps: [
      "Choose the relevant incidents in Correspondence. Check the addressee, transaction details, wording and reply due date in the draft.",
      "Issue the letter only after review. An issued PDF keeps its original contents even when settings or incident status later change.",
      "Use the reminder action for follow-up. Downloading a PDF does not send an email or post a letter automatically.",
    ],
    keywords: "PDF print download draft issued reminder due date address signatory correspondence",
    links: [{ label: "Open Correspondence", href: "/letters" }],
  },
  {
    title: "Reports and totals",
    description: "Choose the report, office and period before comparing figures.",
    steps: [
      "DPR shows a calendar register of finalized work. MPR includes return dates, objection balances, age bands and staff work.",
      "Progress reports use final verification dates in India time. Transaction reports use the original report date. A correction can move finalized work into a later period.",
      "The on-screen transaction preview is limited to 100 rows. Complete totals are calculated separately; detailed PDF exports allow up to 20,000 transactions.",
      "Read any history warning before reconciling balances. Use a narrower period if an export is too large.",
      "Training reports show only your practice records. Switch back to live mode before producing official office reports.",
    ],
    keywords: "DPR MPR daily monthly progress totals balance ageing date period 100 20000",
    links: [{ label: "Open Reports", href: "/reports" }],
  },
  {
    title: "Keyboard shortcuts",
    description: "Keep the combinations that work with your keyboard.",
    steps: [
      "Open My account to enable, disable, change or restore keyboard shortcuts. Preferences are saved for your user on this device.",
      "Open Keyboard shortcuts in the workspace to see your current combinations. Defaults use Alt+Shift and a letter; changed combinations take precedence.",
      "Save focused form applies only to supported data-entry forms containing keyboard focus. It still checks required fields and does not bypass access rules.",
      "Voucher navigation and matching shortcuts are suppressed while typing in a field. Unmodified letters are never used to record a result.",
    ],
    keywords: "hotkey keys keyboard preferences Alt Shift save focused form next previous search",
    links: [{ label: "Change keyboard preferences", href: "/account" }],
  },
  {
    title: "Backups and recovery",
    description: "Keep a separate copy and use the correct recovery procedure.",
    steps: [
      "The standalone offline desktop app creates a daily backup while it is open and keeps the latest 14 daily backups on that computer. Administrators can check the latest result in Settings.",
      "Use Back up to save an additional copy to the office’s backup drive. A copy on the same computer is not protection against losing that computer.",
      "Restore is an administrator operation. Follow the recovery instructions and verify the recovered records before returning to daily work.",
      "Shared installations and connected desktop clients use their server’s backup arrangements. The connected client has no local backup or restore controls. Training mode disables backup and restore controls because a database backup includes live and practice workspaces.",
      "Deleting training data does not erase existing backup files or downloaded PDFs and workbooks.",
    ],
    keywords:
      "backup restore recovery lost computer database server daily automatic folder checksum",
    links: [{ label: "Open Settings", href: "/settings", roles: managers }],
  },
  {
    title: "Practice in training mode",
    description: "Use your own isolated practice workspace while remaining signed in.",
    steps: [
      "Open Training mode and enable it. The first enable creates sample offices, accounts and 24 transactions in your own training workspace.",
      "The TRAINING MODE banner stays visible. Choose a practice role to try Administrator, Supervisor or Postal Assistant work without changing your real permissions.",
      "Records and settings created during training stay separate from live office work and other users’ practice. Password changes are unavailable while training.",
      "Disable training to return to live mode. Your practice remains available to resume later; the mode selection applies only to this browser tab or desktop session.",
      "To start over, review the training counts and type DELETE TRAINING. This removes all sample and newly created records in your training workspace, then returns to live mode. Existing backups and downloaded files remain.",
    ],
    keywords:
      "training demo sample sandbox practice role isolated enable disable delete reset live",
    links: [{ label: "Open Training mode", href: "/training" }],
  },
  {
    title: "Troubleshoot common problems",
    description: "Check the message and your current workspace before retrying.",
    steps: [
      "If sign-in fails, check the email, password and whether you are using the intended installation. Ask your administrator about disabled accounts or password recovery.",
      "If the installed client cannot connect, check the server address with your administrator. An unavailable or incompatible server needs a reachable service, a trusted HTTPS certificate and a compatible SBCO version. Ask your administrator to correct the cause, then retry.",
      "If records are missing, check live versus training mode, office allocation, queue, status, search and date filters.",
      "If an import fails, read the reported problem and compare the workbook with its template. Do not repeatedly upload the same file without checking its import status.",
      "If a save reports that the record changed, refresh and review the latest version. If the server is unavailable, confirm the local server or desktop app is running.",
      "For an unresolved problem, give your administrator the screen name, steps and exact error text. Do not send passwords or private customer records in a support message.",
    ],
    keywords:
      "error failed missing unavailable cannot connection help support contact forgot blank",
    links: [
      { label: "Check verification filters", href: "/verify" },
      { label: "Check your account", href: "/account" },
    ],
  },
];

export function Help({ actor }: { actor: Actor }) {
  const [search, setSearch] = useState("");
  const id = useId();
  const terms = search.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const filtered = topics.filter((topic) => {
    const text = [topic.title, topic.description, topic.keywords, ...topic.steps]
      .join(" ")
      .toLowerCase();
    return terms.every((term) => text.includes(term));
  });
  return (
    <div className="flex flex-col gap-5">
      <Panel
        title="How can we help?"
        description="This guide is included with SBCO and remains available offline. Links open screens in this workspace."
      >
        <Field>
          <FieldLabel htmlFor={id}>Search help</FieldLabel>
          <Input
            id={id}
            type="search"
            value={search}
            onChange={(event) => setSearch(event.target.value)}
            placeholder="Try imports, passwords or training"
            aria-describedby={`${id}-results`}
          />
        </Field>
        <div className="mt-3 flex flex-wrap items-center gap-3">
          <p id={`${id}-results`} role="status" className="text-sm text-muted-foreground">
            {filtered.length} help {filtered.length === 1 ? "topic" : "topics"}
          </p>
          {search && (
            <Button type="button" variant="ghost" size="sm" onClick={() => setSearch("")}>
              Clear help search
            </Button>
          )}
        </div>
      </Panel>
      {filtered.length ? (
        filtered.map((topic) => (
          <Panel key={topic.title} title={topic.title} description={topic.description}>
            <ol className="flex list-decimal flex-col gap-3 pl-5 text-sm leading-6">
              {topic.steps.map((step) => (
                <li key={step}>{step}</li>
              ))}
            </ol>
            <div className="mt-5 flex flex-wrap gap-3">
              {topic.links
                .filter((link) => !link.roles || link.roles.includes(actor.role))
                .map((link) => (
                  <Button key={link.href} asChild variant="outline" size="sm">
                    <Link href={link.href}>{link.label}</Link>
                  </Button>
                ))}
            </div>
          </Panel>
        ))
      ) : (
        <Panel
          title="No matching help topics"
          description="Try a shorter word, such as import, password, report or training."
        >
          <Button type="button" variant="outline" onClick={() => setSearch("")}>
            Show all help topics
          </Button>
        </Panel>
      )}
    </div>
  );
}
