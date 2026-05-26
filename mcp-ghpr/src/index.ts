#!/usr/bin/env node
import { createConnection, type Socket } from "node:net";
import { userInfo } from "node:os";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const SCHEMA_VERSION = 1;
const MAX_RESPONSE_BYTES = 4 * 1024 * 1024;
const REQUEST_TIMEOUT_MS = 5_000;

type Command = "ping" | "snapshot" | "pr";
type Section = "authored" | "review" | "mentioned" | "merged" | "all";

interface SocketRequest {
  command: Command;
  repository?: string;
  number?: number;
}

interface ErrorPayload {
  code: string;
  message: string;
}

interface SocketResponse {
  schemaVersion: number;
  ok: boolean;
  snapshot?: Snapshot;
  pullRequest?: PRSnapshot;
  error?: ErrorPayload;
}

interface PRSnapshot {
  id: number;
  section: Exclude<Section, "all">;
  repository: string;
  number: number;
  title: string;
  author: string;
  url: string;
  state: string;
  isDraft: boolean;
  isPinned: boolean;
  hasBaseConflicts: boolean;
  unresolvedCount: number;
  ciStatus: string | null;
  checkSuccessCount: number;
  checkFailureCount: number;
  checkPendingCount: number;
  ciIsRunning: boolean;
  approvalCount: number;
  changesRequestedCount: number | null;
  myReviewStatus: string | null;
  jiraTicket: string | null;
  updatedAt: string;
  mergedAt: string | null;
}

interface Snapshot {
  schemaVersion: number;
  generatedAt: string;
  app: { version: string; build: string; bundleIdentifier: string };
  auth: { isAuthenticated: boolean; username: string | null; method: string | null };
  refresh: { status: string; isLoading: boolean; lastUpdated: string; error: string | null };
  rateLimit: { limit: number; remaining: number; resetAt: string; isLow: boolean };
  summary: {
    authored: number;
    reviewRequests: number;
    mentioned: number;
    mergedLast24h: number;
    totalUnresolved: number;
    authoredUnresolved: number;
    readyToMerge: number;
    changesRequested: number;
    ciFailing: number;
    ciRunning: number;
    waitingForMyReview: number;
  };
  pullRequests: {
    authored: PRSnapshot[];
    reviewRequests: PRSnapshot[];
    mentioned: PRSnapshot[];
    mergedLast24h: PRSnapshot[];
  };
}

class GhprSocketError extends Error {
  constructor(message: string, readonly code: string = "internal_error") {
    super(message);
  }
}

function resolveSocketPath(): string {
  const override = process.env.GHPR_SOCKET_PATH?.trim();
  if (override) return override;
  return `/tmp/com.xiaocang.PRDashboard.${userInfo().uid}.sock`;
}

function sendRequest(request: SocketRequest): Promise<SocketResponse> {
  return new Promise<SocketResponse>((resolve, reject) => {
    const socketPath = resolveSocketPath();
    const chunks: Buffer[] = [];
    let totalBytes = 0;
    let settled = false;

    const socket: Socket = createConnection({ path: socketPath });

    const finish = (cb: () => void) => {
      if (settled) return;
      settled = true;
      socket.removeAllListeners();
      socket.destroy();
      cb();
    };

    const timer = setTimeout(() => {
      finish(() =>
        reject(
          new GhprSocketError(
            `Timed out after ${REQUEST_TIMEOUT_MS}ms waiting for PRDashboard at ${socketPath}.`,
            "timeout",
          ),
        ),
      );
    }, REQUEST_TIMEOUT_MS);
    timer.unref?.();

    socket.once("connect", () => {
      const payload = Buffer.from(JSON.stringify(request) + "\n", "utf8");
      socket.write(payload, (err) => {
        if (err) {
          clearTimeout(timer);
          finish(() => reject(new GhprSocketError(`Write failed: ${err.message}`, "write_failed")));
          return;
        }
        socket.end();
      });
    });

    socket.on("data", (chunk) => {
      totalBytes += chunk.length;
      if (totalBytes > MAX_RESPONSE_BYTES) {
        clearTimeout(timer);
        finish(() =>
          reject(new GhprSocketError("Local API response is too large.", "read_failed")),
        );
        return;
      }
      chunks.push(chunk);
    });

    socket.once("end", () => {
      clearTimeout(timer);
      if (settled) return;
      const buffer = Buffer.concat(chunks, totalBytes);
      if (buffer.length === 0) {
        finish(() =>
          reject(
            new GhprSocketError(
              "PRDashboard closed the socket without sending a response.",
              "empty_response",
            ),
          ),
        );
        return;
      }
      try {
        const parsed = JSON.parse(buffer.toString("utf8")) as SocketResponse;
        if (parsed.schemaVersion !== SCHEMA_VERSION) {
          finish(() =>
            reject(
              new GhprSocketError(
                `Unsupported local API schema version: ${parsed.schemaVersion}`,
                "schema_mismatch",
              ),
            ),
          );
          return;
        }
        finish(() => resolve(parsed));
      } catch (err) {
        finish(() =>
          reject(
            new GhprSocketError(
              `Failed to parse response: ${(err as Error).message}`,
              "invalid_response",
            ),
          ),
        );
      }
    });

    socket.on("error", (err) => {
      clearTimeout(timer);
      const nodeErr = err as NodeJS.ErrnoException;
      const message =
        nodeErr.code === "ENOENT" || nodeErr.code === "ECONNREFUSED"
          ? `PRDashboard is not accepting local connections at ${socketPath}. Is the app running?`
          : `Socket error (${nodeErr.code ?? "unknown"}): ${err.message}`;
      finish(() => reject(new GhprSocketError(message, "unavailable")));
    });
  });
}

async function call(request: SocketRequest): Promise<SocketResponse> {
  const response = await sendRequest(request);
  if (!response.ok) {
    const err = response.error;
    throw new GhprSocketError(err?.message ?? "Local API request failed.", err?.code ?? "unknown");
  }
  return response;
}

async function fetchSnapshot(): Promise<Snapshot> {
  const response = await call({ command: "snapshot" });
  if (!response.snapshot) {
    throw new GhprSocketError("Response did not include a snapshot.", "invalid_response");
  }
  return response.snapshot;
}

async function fetchPr(repository: string, number: number): Promise<PRSnapshot> {
  const response = await call({ command: "pr", repository, number });
  if (!response.pullRequest) {
    throw new GhprSocketError("Response did not include a pull request.", "invalid_response");
  }
  return response.pullRequest;
}

function flattenPrs(snapshot: Snapshot, section: Section): PRSnapshot[] {
  const { authored, reviewRequests, mentioned, mergedLast24h } = snapshot.pullRequests;
  switch (section) {
    case "authored":
      return authored;
    case "review":
      return reviewRequests;
    case "mentioned":
      return mentioned;
    case "merged":
      return mergedLast24h;
    case "all":
    default:
      return [...authored, ...reviewRequests, ...mentioned, ...mergedLast24h];
  }
}

function matchesRepository(pr: PRSnapshot, query: string): boolean {
  const needle = query.trim().toLowerCase();
  if (!needle) return true;
  return pr.repository.toLowerCase().includes(needle);
}

function compactPr(pr: PRSnapshot) {
  return {
    section: pr.section,
    repository: pr.repository,
    number: pr.number,
    title: pr.title,
    author: pr.author,
    state: pr.state,
    isDraft: pr.isDraft,
    url: pr.url,
    unresolvedCount: pr.unresolvedCount,
    ci: pr.ciIsRunning ? `${pr.ciStatus ?? "RUNNING"} (running)` : pr.ciStatus,
    checks: {
      success: pr.checkSuccessCount,
      failure: pr.checkFailureCount,
      pending: pr.checkPendingCount,
    },
    approvals: pr.approvalCount,
    changesRequested: pr.changesRequestedCount,
    myReview: pr.myReviewStatus,
    jira: pr.jiraTicket,
    hasBaseConflicts: pr.hasBaseConflicts,
    updatedAt: pr.updatedAt,
    mergedAt: pr.mergedAt,
  };
}

function asTextResult(payload: unknown) {
  return {
    content: [
      {
        type: "text" as const,
        text: typeof payload === "string" ? payload : JSON.stringify(payload, null, 2),
      },
    ],
  };
}

function asErrorResult(err: unknown) {
  const message =
    err instanceof GhprSocketError
      ? err.message
      : err instanceof Error
        ? err.message
        : String(err);
  return {
    isError: true,
    content: [{ type: "text" as const, text: message }],
  };
}

const server = new McpServer({
  name: "ghpr-mcp",
  version: "0.1.0",
});

server.tool(
  "ping",
  "Check whether the PRDashboard app is currently running and reachable over the local socket.",
  {},
  async () => {
    try {
      await call({ command: "ping" });
      return asTextResult({ ok: true, message: "PRDashboard is running." });
    } catch (err) {
      return asErrorResult(err);
    }
  },
);

server.tool(
  "status",
  "Show app version, auth state, refresh state, summary counters, and GitHub rate limit.",
  {},
  async () => {
    try {
      const snapshot = await fetchSnapshot();
      return asTextResult({
        app: snapshot.app,
        auth: snapshot.auth,
        refresh: snapshot.refresh,
        rateLimit: snapshot.rateLimit,
        summary: snapshot.summary,
        generatedAt: snapshot.generatedAt,
      });
    } catch (err) {
      return asErrorResult(err);
    }
  },
);

server.tool(
  "summary",
  "Return only the summary counters (authored, review, unresolved, CI, etc.) from the current snapshot.",
  {},
  async () => {
    try {
      const snapshot = await fetchSnapshot();
      return asTextResult(snapshot.summary);
    } catch (err) {
      return asErrorResult(err);
    }
  },
);

server.tool(
  "list_prs",
  "List PRs from the snapshot. Optional filters: `repository` (case-insensitive substring of OWNER/NAME), `section` (authored|review|mentioned|merged|all), `limit`.",
  {
    repository: z
      .string()
      .optional()
      .describe("Case-insensitive substring of OWNER/NAME, e.g. 'kong/kong' or just 'kong'."),
    section: z
      .enum(["authored", "review", "mentioned", "merged", "all"])
      .optional()
      .describe("Which snapshot section to pull from. Defaults to 'all'."),
    limit: z
      .number()
      .int()
      .positive()
      .max(500)
      .optional()
      .describe("Maximum rows to return after filtering."),
  },
  async ({ repository, section, limit }) => {
    try {
      const snapshot = await fetchSnapshot();
      let prs = flattenPrs(snapshot, section ?? "all");
      if (repository) prs = prs.filter((pr) => matchesRepository(pr, repository));
      if (limit) prs = prs.slice(0, limit);
      return asTextResult({
        section: section ?? "all",
        repositoryFilter: repository ?? null,
        count: prs.length,
        pullRequests: prs.map(compactPr),
      });
    } catch (err) {
      return asErrorResult(err);
    }
  },
);

server.tool(
  "get_pr",
  "Fetch details for a single PR by repository and number.",
  {
    repository: z.string().describe("OWNER/NAME, e.g. 'kong/kong'."),
    number: z.number().int().positive().describe("PR number."),
  },
  async ({ repository, number }) => {
    try {
      const pr = await fetchPr(repository, number);
      return asTextResult(compactPr(pr));
    } catch (err) {
      return asErrorResult(err);
    }
  },
);

server.tool(
  "list_unresolved",
  "List PRs that currently have unresolved review comments. Optional `repository` substring filter.",
  {
    repository: z.string().optional(),
    limit: z.number().int().positive().max(500).optional(),
  },
  async ({ repository, limit }) => {
    try {
      const snapshot = await fetchSnapshot();
      let prs = flattenPrs(snapshot, "all").filter((pr) => pr.unresolvedCount > 0);
      if (repository) prs = prs.filter((pr) => matchesRepository(pr, repository));
      prs.sort((a, b) => b.unresolvedCount - a.unresolvedCount);
      if (limit) prs = prs.slice(0, limit);
      return asTextResult({
        count: prs.length,
        pullRequests: prs.map(compactPr),
      });
    } catch (err) {
      return asErrorResult(err);
    }
  },
);

server.tool(
  "list_ci_failing",
  "List PRs whose CI is currently failing. Optional `repository` substring filter.",
  {
    repository: z.string().optional(),
    limit: z.number().int().positive().max(500).optional(),
  },
  async ({ repository, limit }) => {
    try {
      const snapshot = await fetchSnapshot();
      let prs = flattenPrs(snapshot, "all").filter((pr) => pr.checkFailureCount > 0);
      if (repository) prs = prs.filter((pr) => matchesRepository(pr, repository));
      prs.sort((a, b) => b.checkFailureCount - a.checkFailureCount);
      if (limit) prs = prs.slice(0, limit);
      return asTextResult({
        count: prs.length,
        pullRequests: prs.map(compactPr),
      });
    } catch (err) {
      return asErrorResult(err);
    }
  },
);

server.tool(
  "snapshot",
  "Return the full, raw snapshot JSON from PRDashboard. Use this when finer-grained filtering than the other tools provide is needed.",
  {},
  async () => {
    try {
      const snapshot = await fetchSnapshot();
      return asTextResult(snapshot);
    } catch (err) {
      return asErrorResult(err);
    }
  },
);

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  process.stderr.write(
    `mcp-ghpr fatal: ${err instanceof Error ? err.stack ?? err.message : String(err)}\n`,
  );
  process.exit(1);
});
