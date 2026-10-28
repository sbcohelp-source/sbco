"use client";
import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import { ClipboardCheck, CircleHelp, LogOut, Menu, ShieldCheck, X } from "lucide-react";
import {
  client,
  hasTrainingContext,
  setTrainingContext,
  type Actor,
  type ConnectionStatus,
} from "@sbco/client";
import { Button } from "@sbco/ui/button";
import { Form, Loading, Panel, text } from "./shared";
import { Verification, Reviews } from "./verification";
import { Imports, Offices, Users, Reports, Settings, Audit } from "./operations";
import { Correspondence } from "./correspondence";
import { Help } from "./help";
import { TrainingControls, TrainingBanner } from "./training";
import { GettingStarted } from "./onboarding";
import { OfflineSetupWizard, ServerConnectionWizard } from "./first-run";
import { ShortcutProvider, ShortcutReference, ShortcutSettings } from "./shortcuts";
const sections = [
  ["dashboard", "Overview"],
  ["onboarding", "Get started"],
  ["training", "Training"],
  ["help", "Help"],
  ["imports", "Excel imports"],
  ["verify", "Verification"],
  ["bo-verification", "BO verification"],
  ["agent-verification", "Agent entries"],
  ["rd-default", "RD default entries"],
  ["reverify", "Supervisor review"],
  ["corrections", "Corrections"],
  ["incidents", "Incidents"],
  ["letters", "Correspondence"],
  ["reports", "Reports"],
  ["offices", "Offices & pools"],
  ["users", "Users"],
  ["settings", "Settings"],
  ["audit", "Audit history"],
  ["account", "My account"],
];
const managerSections = new Set([
  "imports",
  "reverify",
  "corrections",
  "offices",
  "users",
  "settings",
  "audit",
]);
export function App({ section = "dashboard" }: { section?: string }) {
  const [connection, setConnection] = useState<ConnectionStatus | null>(null);
  const [connectNeeded, setConnectNeeded] = useState(false);
  const [setupNeeded, setSetupNeeded] = useState(false);
  const [actor, setActor] = useState<Actor | null>(null);
  const [ready, setReady] = useState(false);
  const [menu, setMenu] = useState(false);
  const [sessionError, setSessionError] = useState("");
  const navigationRef = useRef<HTMLElement>(null);
  useEffect(() => {
    if (!menu) return;
    const navigation = navigationRef.current;
    if (!navigation) return;
    const previousFocus = document.activeElement as HTMLElement | null;
    const overflow = document.body.style.overflow;
    const controls = () =>
      Array.from(navigation.querySelectorAll<HTMLElement>("a[href], button:not([disabled])"));
    controls()[0]?.focus();
    document.body.style.overflow = "hidden";
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        setMenu(false);
      }
      if (event.key !== "Tab") return;
      const items = controls();
      const first = items[0];
      const last = items.at(-1);
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last?.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first?.focus();
      }
    };
    const desktop = window.matchMedia("(min-width: 1024px)");
    const onResize = () => {
      if (desktop.matches) setMenu(false);
    };
    document.addEventListener("keydown", onKeyDown);
    desktop.addEventListener("change", onResize);
    return () => {
      document.body.style.overflow = overflow;
      document.removeEventListener("keydown", onKeyDown);
      desktop.removeEventListener("change", onResize);
      previousFocus?.focus();
    };
  }, [menu]);
  useEffect(() => {
    let active = true;
    client
      .connectionStatus()
      .then(async (status) => {
        if (active) setConnection(status);
        if (status.mode === "connected" && !status.configured) {
          if (active) setConnectNeeded(true);
          return;
        }
        const needed = status.mode === "connected" ? false : await client.setupNeeded();
        if (active) setSetupNeeded(needed);
        if (!needed) {
          const a = await client.me();
          if (active) setActor(a);
        }
      })
      .catch((e) => {
        if (active && e.status !== 401 && e.message !== "Sign in to continue")
          setSessionError(e.message);
      })
      .finally(() => {
        if (active) setReady(true);
      });
    return () => {
      active = false;
    };
  }, []);
  async function changeServer() {
    try {
      await client.disconnectForServerChange();
    } catch {
      /* Native transport always forgets its local session. */
    }
    setTrainingContext(null);
    setActor(null);
    setSessionError("");
    setConnectNeeded(true);
  }
  if (!ready)
    return (
      <main className="mx-auto max-w-lg p-10">
        <Loading />
      </main>
    );
  if (connectNeeded)
    return (
      <ServerConnectionWizard
        serverUrl={connection?.server_url || ""}
        onConnected={() => {
          setTrainingContext(null);
          window.location.reload();
        }}
      />
    );
  if (setupNeeded) return <OfflineSetupWizard onCreated={() => setSetupNeeded(false)} />;
  if (!actor)
    return (
      <main className="flex min-h-screen items-center justify-center p-5">
        <div className="w-full max-w-md">
          <TrainingBanner />
          <div className="mb-7 flex items-center gap-3">
            <span className="rounded-xl bg-primary p-3 text-primary-foreground">
              <ClipboardCheck className="size-7" />
            </span>
            <div>
              <h1 className="text-2xl font-semibold tracking-tight">SBCO</h1>
              <p className="text-sm text-muted-foreground">Voucher verification workspace</p>
            </div>
          </div>
          <Panel title="Welcome back" description="Sign in with your assigned account.">
            {connection?.mode === "connected" && (
              <div className="mb-4 flex flex-col gap-2">
                <p className="text-sm break-all text-muted-foreground">
                  Server: {connection.server_url}
                </p>
                <Button variant="outline" onClick={() => void changeServer()}>
                  Change server
                </Button>
              </div>
            )}
            <Form
              shortcut={false}
              label="Sign in"
              fields={[
                { name: "email", label: "Email address", type: "email", required: true },
                { name: "password", label: "Password", type: "password", required: true },
              ]}
              submit={async (d) => {
                const a = await client.login({
                  email: text(d, "email"),
                  password: String(d.get("password") || ""),
                });
                setSessionError("");
                setActor(a);
              }}
            />
            {sessionError && (
              <p role="alert" className="mt-4 text-destructive">
                {sessionError}
              </p>
            )}
            <p className="mt-5 text-xs leading-5 text-muted-foreground">
              Signing in opens your live workspace. Contact your administrator for access or
              password recovery. Offline installations use their local accounts.
            </p>
          </Panel>
        </div>
      </main>
    );
  const manager = actor.role !== "Pa";
  const allowed = manager || !managerSections.has(section);
  let content;
  if (!allowed)
    content = (
      <Panel title="Access restricted">
        This workspace is available to supervisors and administrators.
      </Panel>
    );
  else
    switch (section) {
      case "training":
        content = <TrainingControls />;
        break;
      case "help":
        content = <Help actor={actor} />;
        break;
      case "onboarding":
        content = <GettingStarted key={actor.id} actor={actor} />;
        break;
      case "imports":
        content = <Imports actor={actor} />;
        break;
      case "verify":
      case "bo-verification":
      case "agent-verification":
      case "rd-default":
        content = (
          <Verification
            key={section}
            manager={manager}
            queue={
              section === "bo-verification"
                ? "bo"
                : section === "agent-verification"
                  ? "agent"
                  : section === "rd-default"
                    ? "rd_default"
                    : "standard"
            }
          />
        );
        break;
      case "reverify":
        content = <Reviews />;
        break;
      case "corrections":
        content = <Reviews corrections />;
        break;
      case "incidents":
        content = <Correspondence />;
        break;
      case "letters":
        content = <Correspondence letters />;
        break;
      case "reports":
        content = <Reports />;
        break;
      case "offices":
        content = <Offices />;
        break;
      case "users":
        content = <Users actor={actor} />;
        break;
      case "settings":
        content = <Settings actor={actor} />;
        break;
      case "audit":
        content = <Audit />;
        break;
      case "account":
        content = (
          <div className="flex flex-col gap-5">
            <Panel title={actor.name} description={actor.role}>
              <Form
                shortcut={false}
                label="Change password"
                fields={[
                  { name: "current", label: "Current password", type: "password", required: true },
                  {
                    name: "new",
                    label: "New password (12+ characters)",
                    type: "password",
                    required: true,
                  },
                ]}
                submit={async (d) => {
                  await client.command({
                    kind: "change_password",
                    current_password: String(d.get("current") || ""),
                    new_password: String(d.get("new") || ""),
                  });
                  setActor(null);
                }}
              />
            </Panel>
            <ShortcutSettings />
          </div>
        );
        break;
      default:
        content = <GettingStarted key={actor.id} actor={actor} automatic />;
    }
  return (
    <ShortcutProvider key={actor.id} userId={actor.id}>
      <div className="min-h-screen">
        <a
          href="#main-content"
          className="sr-only focus:not-sr-only focus:fixed focus:top-2 focus:left-2 focus:z-50 focus:rounded focus:bg-card focus:p-3"
        >
          Skip to main content
        </a>
        <aside
          ref={navigationRef}
          id="main-navigation"
          role={menu ? "dialog" : undefined}
          aria-modal={menu || undefined}
          aria-label={menu ? "Main navigation" : undefined}
          className={`${menu ? "flex" : "hidden"} sidebar fixed inset-y-0 left-0 z-30 w-60 flex-col border-r border-sidebar-border bg-sidebar p-4 text-sidebar-foreground lg:flex`}
        >
          <Button
            variant="ghost"
            size="icon"
            className="absolute top-3 right-3 lg:hidden"
            aria-label="Close navigation"
            onClick={() => setMenu(false)}
          >
            <X />
          </Button>
          <Link href="/" className="mb-8 flex items-center gap-3 px-3 py-2">
            <ClipboardCheck className="size-8" />
            <div>
              <b className="text-xl tracking-tight">SBCO</b>
              <p className="text-xs opacity-75">Voucher verification</p>
            </div>
          </Link>
          <nav className="flex flex-1 flex-col gap-1 overflow-y-auto" aria-label="Main navigation">
            {sections
              .filter(([key]) => manager || !managerSections.has(key))
              .map(([key, label]) => (
                <Link
                  key={key}
                  onClick={() => setMenu(false)}
                  href={key === "dashboard" ? "/" : `/${key}`}
                  aria-current={section === key ? "page" : undefined}
                  className={`rounded-lg px-3 py-2 text-sm font-medium ${section === key ? "bg-sidebar-accent text-sidebar-accent-foreground" : "hover:bg-sidebar-accent/60"}`}
                >
                  {label}
                </Link>
              ))}
          </nav>
          <div className="mt-4 border-t border-sidebar-border px-3 pt-4">
            <p className="text-sm font-medium">{actor.name}</p>
            <p className="text-xs opacity-70">
              {actor.role === "Pa" ? "Postal Assistant" : actor.role}
            </p>
          </div>
        </aside>
        {menu && (
          <button
            aria-label="Dismiss navigation backdrop"
            className="fixed inset-0 z-20 bg-foreground/20 lg:hidden"
            onClick={() => setMenu(false)}
          />
        )}
        <div className="lg:pl-60" inert={menu}>
          <header className="sticky top-0 z-10 flex h-18 items-center justify-between border-b bg-background/95 px-5 backdrop-blur lg:px-8">
            <div className="flex items-center gap-3">
              <Button
                variant="ghost"
                size="icon"
                className="lg:hidden"
                aria-label="Open navigation"
                aria-controls="main-navigation"
                aria-expanded={menu}
                onClick={() => setMenu(true)}
              >
                <Menu />
              </Button>
              <span className="text-sm text-muted-foreground">
                <span className="hidden sm:inline">
                  SBCO workspace <span className="mx-2">/</span>
                </span>
                <span className="text-foreground">
                  {sections.find(([s]) => s === section)?.[1] || "Overview"}
                </span>
              </span>
            </div>
            <div className="flex items-center gap-3">
              {client.isConnected() && (
                <Button variant="outline" size="sm" onClick={() => void changeServer()}>
                  Change server
                </Button>
              )}
              {client.isDesktop() &&
                !client.isConnected() &&
                actor.role === "Administrator" &&
                !hasTrainingContext() && (
                  <div className="flex gap-2">
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => void client.backup().catch((e) => setSessionError(e.message))}
                    >
                      Back up
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => void client.restore().catch((e) => setSessionError(e.message))}
                    >
                      Restore
                    </Button>
                  </div>
                )}
              <Button variant="ghost" size="icon-sm" asChild>
                <Link href="/help" aria-label="Open help">
                  <CircleHelp />
                </Link>
              </Button>
              <ShieldCheck className="hidden size-4 text-primary sm:block" />
              <Button
                variant="ghost"
                size="sm"
                onClick={() =>
                  void client
                    .logout()
                    .then(() => setActor(null))
                    .catch((e) => setSessionError(e.message))
                }
              >
                <LogOut data-icon="inline-start" />
                Sign out
              </Button>
            </div>
          </header>
          <main id="main-content" tabIndex={-1} className="mx-auto max-w-[1600px] p-5 lg:p-8">
            <TrainingBanner />
            <div className="mb-7">
              <p className="mb-2 text-xs font-semibold tracking-[0.18em] text-muted-foreground uppercase">
                Savings Bank Control Organisation
              </p>
              <h1 className="text-3xl font-semibold tracking-tight">
                {sections.find(([s]) => s === section)?.[1] || "Overview"}
              </h1>
            </div>
            {sessionError && (
              <p role="alert" className="mb-4 text-destructive">
                {sessionError}
              </p>
            )}
            {content}
            <div className="mt-5">
              <ShortcutReference />
            </div>
          </main>
        </div>
      </div>
    </ShortcutProvider>
  );
}
