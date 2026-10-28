import type { Command, CommandRequest, ExportRequest, Login, Query } from "./generated";
export type { Command, Query, Filter, ExportRequest } from "./generated";
export type Actor = { id: string; name: string; role: "Pa" | "Supervisor" | "Administrator" };
export type Row = Record<string, unknown>;
export type ConnectionStatus = {
  mode: "offline" | "connected";
  server_url: string | null;
  configured: boolean;
};
let connectedClient = false;
export type BackupStatus = {
  enabled: boolean;
  directory: string | null;
  retention_days: number;
  last_attempt: string | null;
  last_success: string | null;
  last_backup: string | null;
  last_error: string | null;
};
export type Queue = { rows: Row[]; next_cursor: string | null };
export const emptyFilter = {
  office: null,
  status: null,
  search: null,
  from_date: null,
  to_date: null,
  queue: null,
};
export class ApiError extends Error {
  constructor(
    message: string,
    public status: number,
  ) {
    super(message);
  }
}
export type TrainingContext = { generation: string; role: Actor["role"] };
export type TrainingStatus = {
  available: boolean;
  generation: string | null;
  counts: {
    offices: number;
    users: number;
    pools: number;
    imports: number;
    transactions: number;
    incidents: number;
    letters: number;
  };
};
const trainingKey = "sbco.training.v1";
let workspaceRead = false;
let workspaceContext: TrainingContext | null = null;
let workspaceError: ApiError | null = null;
// Freeze workspace selection for this page's lifetime. A mode switch always reloads;
// already mounted forms can therefore never be redirected into the live workspace.
export function getTrainingContext(): TrainingContext | null {
  if (typeof window === "undefined") return null;
  if (!workspaceRead) {
    workspaceRead = true;
    try {
      const raw = window.sessionStorage.getItem(trainingKey);
      if (raw) {
        const candidate = JSON.parse(raw);
        if (
          !candidate ||
          typeof candidate.generation !== "string" ||
          !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
            candidate.generation,
          ) ||
          !["Administrator", "Supervisor", "Pa"].includes(candidate.role)
        )
          throw new Error("Invalid workspace");
        workspaceContext = { generation: candidate.generation, role: candidate.role };
      }
    } catch {
      workspaceError = new ApiError(
        "The training selection cannot be read. Exit training explicitly before continuing.",
        409,
      );
    }
  }
  if (workspaceError) throw workspaceError;
  return workspaceContext;
}
export function hasTrainingContext(): boolean {
  try {
    return getTrainingContext() !== null;
  } catch {
    return true;
  }
}
export function setTrainingContext(context: TrainingContext | null): void {
  if (typeof window === "undefined") return;
  if (context) window.sessionStorage.setItem(trainingKey, JSON.stringify(context));
  else window.sessionStorage.removeItem(trainingKey);
}
function workspaceHeaders(workspace: boolean): Record<string, string> {
  const context = workspace ? getTrainingContext() : null;
  return {
    "Content-Type": "application/json",
    "X-SBCO-Request": "1",
    ...(context ? { "X-SBCO-Training": JSON.stringify(context) } : {}),
  };
}
function workspaceArgs() {
  return { training: getTrainingContext() };
}
const desktop = () => typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
async function ipc<T>(name: string, args?: Record<string, unknown>): Promise<T> {
  const { invoke } = await import("@tauri-apps/api/core");
  try {
    return await invoke<T>(name, args);
  } catch (error) {
    throw new Error(typeof error === "string" ? error : "Desktop operation failed");
  }
}
async function http<T>(path: string, body?: unknown, workspace = true): Promise<T> {
  const response = await fetch(`/api/v1/${path}`, {
    method: body === undefined ? "GET" : "POST",
    credentials: "same-origin",
    headers: workspaceHeaders(workspace),
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const result = await response.json();
  if (!response.ok)
    throw new ApiError(result.error || `Request failed (${response.status})`, response.status);
  return result as T;
}
export const client = {
  isDesktop: desktop,
  isConnected: () => connectedClient,
  connectionStatus: async (): Promise<ConnectionStatus> => {
    const status = desktop()
      ? await ipc<ConnectionStatus>("connection_status")
      : { mode: "offline" as const, server_url: null, configured: true };
    connectedClient = status.mode === "connected";
    return status;
  },
  configureConnection: (serverUrl: string): Promise<ConnectionStatus> =>
    ipc("configure_connection", { serverUrl }),
  setupNeeded: (): Promise<boolean> => (desktop() ? ipc("setup_needed") : Promise.resolve(false)),
  setup: (name: string, credentials: Login): Promise<void> => ipc("setup", { name, credentials }),
  backup: (): Promise<void> => ipc("backup", workspaceArgs()),
  backupStatus: (): Promise<BackupStatus> => ipc("backup_status", workspaceArgs()),
  saveTemplate: (name: string): Promise<void> => ipc("save_template", { name, ...workspaceArgs() }),
  restore: (): Promise<void> => ipc("restore", workspaceArgs()),
  me: (): Promise<Actor> => (desktop() ? ipc("me", workspaceArgs()) : http("me")),
  login: async (credentials: Login): Promise<Actor> => {
    const actor = await (desktop()
      ? ipc<Actor>("login", { credentials })
      : http<Actor>("login", credentials, false));
    // Explicit sign-in starts in live mode. Reload is required if this page had a training selection.
    setTrainingContext(null);
    if (hasTrainingContext()) window.location.reload();
    return actor;
  },
  disconnectForServerChange: async (): Promise<void> => {
    try {
      await ipc("logout");
    } finally {
      setTrainingContext(null);
    }
  },
  logout: async (): Promise<unknown> => {
    const result = await (desktop() ? ipc("logout") : http("logout", {}, false));
    setTrainingContext(null);
    if (hasTrainingContext()) window.location.reload();
    return result;
  },
  trainingStatus: (): Promise<TrainingStatus> =>
    desktop() ? ipc("training_status") : http("training", undefined, false),
  enableTraining: (): Promise<TrainingStatus> =>
    desktop() ? ipc("enable_training") : http("training/enable", {}, false),
  resetTraining: (input: { generation: string; confirmation: string }): Promise<TrainingStatus> =>
    desktop() ? ipc("reset_training", input) : http("training/reset", input, false),
  query: <T>(query: Query): Promise<T> =>
    desktop() ? ipc("query", { query, ...workspaceArgs() }) : http("query", query),
  command: (command: Command, requestId = crypto.randomUUID()): Promise<Row> => {
    const request: CommandRequest = { request_id: requestId, command };
    return desktop() ? ipc("command", { request, ...workspaceArgs() }) : http("command", request);
  },
  export: async (request: ExportRequest) => {
    if (desktop()) {
      await ipc("save_pdf", { request, ...workspaceArgs() });
      return;
    }
    const response = await fetch("/api/v1/export", {
      method: "POST",
      credentials: "same-origin",
      headers: workspaceHeaders(true),
      body: JSON.stringify(request),
    });
    if (!response.ok) {
      const error = await response.json();
      throw new Error(error.error || "PDF export failed");
    }
    const url = URL.createObjectURL(await response.blob());
    const link = document.createElement("a");
    link.href = url;
    link.download = `${getTrainingContext() ? "TRAINING-" : ""}${request.letter_id ? "sbco-letter.pdf" : `sbco-${request.report}.pdf`}`;
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  },
};
export async function fileBase64(file: File): Promise<string> {
  if (file.size > 20_000_000) throw new Error("Each workbook must be smaller than 20 MB");
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(new Error("Unable to read file"));
    reader.onload = () => resolve(String(reader.result).split(",")[1]);
    reader.readAsDataURL(file);
  });
}
