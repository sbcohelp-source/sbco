"use client";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { Button } from "@sbco/ui/button";
import { Input } from "@sbco/ui/input";
import { Field, FieldGroup, FieldLabel } from "@sbco/ui/field";
import { Card, CardHeader, CardTitle, CardDescription, CardContent } from "@sbco/ui/card";

const actions = {
  save: {
    label: "Save focused form",
    key: "S",
    description: "Submit the data-entry form containing keyboard focus.",
  },
  search: {
    label: "Focus account search",
    key: "F",
    description: "Open the account or transaction search in Verification.",
  },
  next: {
    label: "Next voucher",
    key: "N",
    description: "Select the next voucher on the current page.",
  },
  previous: {
    label: "Previous voucher",
    key: "P",
    description: "Select the previous voucher on the current page.",
  },
  match: {
    label: "Mark matched",
    key: "M",
    description: "Record the current pending voucher as matched (allotted PA only).",
  },
  reason: {
    label: "Focus mismatch reason",
    key: "R",
    description: "Focus the reason selector without recording a mismatch.",
  },
  help: {
    label: "Show shortcut reference",
    key: "K",
    description: "Open or close this reference.",
  },
} as const;
type Action = keyof typeof actions;
type Bindings = Record<Action, string>;
type Preferences = { version: 1; enabled: boolean; bindings: Bindings };
const entries = Object.entries(actions) as [Action, (typeof actions)[Action]][];
const defaults: Preferences = {
  version: 1,
  enabled: true,
  bindings: Object.fromEntries(
    entries.map(([id, action]) => [id, `Alt+Shift+${action.key}`]),
  ) as Bindings,
};

function validateBindings(bindings: Bindings): Bindings {
  const normalized = {} as Bindings;
  const used = new Set<string>();
  for (const [id, action] of entries) {
    const input = bindings[id];
    if (typeof input !== "string" || !/^Alt\+Shift\+[A-Z]$/i.test(input.trim())) {
      throw new Error(
        `${action.label}: use Alt+Shift and one letter, for example Alt+Shift+S. Browser Ctrl/Cmd shortcuts and unmodified keys are not allowed.`,
      );
    }
    const binding = `Alt+Shift+${input.trim().slice(-1).toUpperCase()}`;
    if (used.has(binding))
      throw new Error(
        `${binding} is assigned more than once. Choose a different letter for each action.`,
      );
    used.add(binding);
    normalized[id] = binding;
  }
  return normalized;
}

function loadPreferences(key: string): Preferences {
  try {
    const stored = JSON.parse(localStorage.getItem(key) || "null");
    if (stored?.version === 1 && typeof stored.enabled === "boolean") {
      return { version: 1, enabled: stored.enabled, bindings: validateBindings(stored.bindings) };
    }
  } catch {
    // Invalid or unavailable local storage must never enable an unsafe binding.
  }
  return defaults;
}

type ShortcutContextValue = {
  preferences: Preferences;
  save: (preferences: Preferences) => void;
  reset: () => void;
  register: (action: Action, handler: () => boolean) => () => void;
  referenceOpen: boolean;
  setReferenceOpen: (open: boolean) => void;
  storageError: string;
};
const ShortcutContext = createContext<ShortcutContextValue | null>(null);

export function ShortcutProvider({ userId, children }: { userId: string; children: ReactNode }) {
  const storageKey = `sbco.shortcuts.v1.${userId}`;
  const [preferences, setPreferences] = useState(() => loadPreferences(storageKey));
  const [storageError, setStorageError] = useState("");
  const [referenceOpen, setReferenceOpen] = useState(false);
  const handlers = useRef(new Map<Action, () => boolean>());
  const register = useCallback((action: Action, handler: () => boolean) => {
    handlers.current.set(action, handler);
    return () => {
      if (handlers.current.get(action) === handler) handlers.current.delete(action);
    };
  }, []);
  const save = useCallback(
    (input: Preferences) => {
      const next: Preferences = {
        version: 1,
        enabled: input.enabled,
        bindings: validateBindings(input.bindings),
      };
      setPreferences(next);
      try {
        localStorage.setItem(storageKey, JSON.stringify(next));
        setStorageError("");
      } catch {
        setStorageError(
          "Preferences work for this session, but this browser could not save them on this device.",
        );
      }
    },
    [storageKey],
  );
  useEffect(() => {
    function keydown(event: KeyboardEvent) {
      if (
        !preferences.enabled ||
        event.defaultPrevented ||
        event.repeat ||
        event.isComposing ||
        event.keyCode === 229 ||
        event.getModifierState("AltGraph")
      )
        return;
      if (
        !event.altKey ||
        !event.shiftKey ||
        event.ctrlKey ||
        event.metaKey ||
        !/^[a-z]$/i.test(event.key)
      )
        return;
      if (document.querySelector('[aria-modal="true"]')) return;
      const binding = `Alt+Shift+${event.key.toUpperCase()}`;
      const action = entries.find(([id]) => preferences.bindings[id] === binding)?.[0];
      if (!action) return;
      const target = event.target instanceof HTMLElement ? event.target : null;
      if (target?.closest("[inert]")) return;
      if (action === "save") {
        const form = target?.closest<HTMLFormElement>('form[data-shortcut-form="true"]');
        if (!form || !form.contains(document.activeElement)) return;
        const submit = form.querySelector<HTMLButtonElement>(
          'button[type="submit"]:not(:disabled)',
        );
        if (!submit) return;
        event.preventDefault();
        form.requestSubmit(submit);
        return;
      }
      if (action === "help") {
        event.preventDefault();
        setReferenceOpen((open) => !open);
        return;
      }
      if (
        target?.closest(
          'input,textarea,select,[contenteditable]:not([contenteditable="false"]),[role="textbox"]',
        )
      )
        return;
      if (handlers.current.get(action)?.()) event.preventDefault();
    }
    window.addEventListener("keydown", keydown);
    return () => window.removeEventListener("keydown", keydown);
  }, [preferences]);
  return (
    <ShortcutContext.Provider
      value={{
        preferences,
        save,
        reset: () => save(defaults),
        register,
        referenceOpen,
        setReferenceOpen,
        storageError,
      }}
    >
      {children}
    </ShortcutContext.Provider>
  );
}

export function useShortcutBinding(action: Action) {
  const context = useContext(ShortcutContext);
  return context?.preferences.enabled ? context.preferences.bindings[action] : undefined;
}

export function useShortcutAction(action: Action, handler: () => boolean) {
  const register = useContext(ShortcutContext)?.register;
  useEffect(() => register?.(action, handler), [register, action, handler]);
}

export function ShortcutReference() {
  const context = useContext(ShortcutContext);
  const summary = useRef<HTMLElement>(null);
  useEffect(() => {
    if (context?.referenceOpen) summary.current?.focus();
  }, [context?.referenceOpen]);
  if (!context) return null;
  return (
    <details
      className="mb-5 rounded-lg border bg-card p-4"
      open={context.referenceOpen}
      onToggle={(event) => context.setReferenceOpen(event.currentTarget.open)}
    >
      <summary
        ref={summary}
        className="cursor-pointer font-medium"
        aria-keyshortcuts={
          context.preferences.enabled ? context.preferences.bindings.help : undefined
        }
      >
        Keyboard shortcuts{context.preferences.enabled ? "" : " (disabled)"}
      </summary>
      <div className="mt-4 flex flex-col gap-3">
        <p className="text-sm text-muted-foreground">
          Change shortcuts in My account. Search, voucher navigation, match and reason shortcuts
          pause while you type. Save checks the focused form before submitting.
        </p>
        <dl className="grid gap-3 sm:grid-cols-2">
          {entries.map(([id, action]) => (
            <div key={id}>
              <dt className="text-sm font-medium">
                {action.label} · <kbd>{context.preferences.bindings[id]}</kbd>
              </dt>
              <dd className="text-sm text-muted-foreground">{action.description}</dd>
            </div>
          ))}
        </dl>
      </div>
    </details>
  );
}

export function ShortcutSettings() {
  const context = useContext(ShortcutContext);
  const [draft, setDraft] = useState(() => context?.preferences ?? defaults);
  const [error, setError] = useState("");
  const [done, setDone] = useState("");
  if (!context) return null;
  return (
    <Card>
      <CardHeader>
        <CardTitle>
          <h2>Keyboard preferences</h2>
        </CardTitle>
        <CardDescription>
          Saved for your account on this browser or desktop device only. These preferences do not
          change other users or devices.
        </CardDescription>
      </CardHeader>
      <CardContent>
        <form
          className="flex flex-col gap-4"
          onSubmit={(event) => {
            event.preventDefault();
            setError("");
            setDone("");
            try {
              context.save(draft);
              setDone("Keyboard preferences saved");
            } catch (error) {
              setError(error instanceof Error ? error.message : "Unable to save preferences");
            }
          }}
        >
          <FieldGroup className="grid gap-4 sm:grid-cols-2">
            <Field className="sm:col-span-2">
              <FieldLabel htmlFor="shortcuts-enabled">Keyboard shortcuts</FieldLabel>
              <select
                id="shortcuts-enabled"
                className="control"
                value={draft.enabled ? "enabled" : "disabled"}
                onChange={(event) =>
                  setDraft((value) => ({ ...value, enabled: event.target.value === "enabled" }))
                }
              >
                <option value="enabled">Enabled</option>
                <option value="disabled">Disabled</option>
              </select>
            </Field>
            <p className="text-sm text-muted-foreground sm:col-span-2">
              Use Alt+Shift and a different letter for each action, such as Alt+Shift+S. On Mac, Alt
              is Option. Ctrl/Cmd combinations, unmodified letters and duplicate shortcuts are not
              accepted. If your operating system uses a combination, choose another letter or
              disable shortcuts.
            </p>
            {entries.map(([id, action]) => (
              <Field key={id}>
                <FieldLabel htmlFor={`shortcut-${id}`}>{action.label} shortcut</FieldLabel>
                <Input
                  id={`shortcut-${id}`}
                  value={draft.bindings[id]}
                  autoComplete="off"
                  spellCheck={false}
                  onChange={(event) =>
                    setDraft((value) => ({
                      ...value,
                      bindings: { ...value.bindings, [id]: event.target.value },
                    }))
                  }
                />
              </Field>
            ))}
          </FieldGroup>
          {error && (
            <p role="alert" className="text-destructive">
              {error}
            </p>
          )}
          {context.storageError && (
            <p role="alert" className="text-destructive">
              {context.storageError}
            </p>
          )}
          {done && <p role="status">{done}</p>}
          <div className="flex flex-wrap gap-3">
            <Button type="submit">Save keyboard preferences</Button>
            <Button
              type="button"
              variant="outline"
              onClick={() => {
                context.reset();
                setDraft(defaults);
                setError("");
                setDone("Default keyboard preferences restored");
              }}
            >
              Restore default shortcuts
            </Button>
          </div>
        </form>
      </CardContent>
    </Card>
  );
}
