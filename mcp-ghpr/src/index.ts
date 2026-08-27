#!/usr/bin/env node
import { execFile } from "node:child_process";
import { createConnection, type Socket } from "node:net";
import { userInfo } from "node:os";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const SCHEMA_VERSION = 1;
const MAX_RESPONSE_BYTES = 4 * 1024 * 1024;
const REQUEST_TIMEOUT_MS = 5_000;
const GH_COMMAND_TIMEOUT_MS = 15_000;
const GH_PR_VIEW_FIELDS = [
  "author",
  "fullDatabaseId",
  "isDraft",
  "latestReviews",
  "mergeStateStatus",
  "mergeable",
  "mergedAt",
  "number",
  "state",
  "statusCheckRollup",
  "title",
  "updatedAt",
  "url",
];

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
  source?: "gh";
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

class GhCommandError extends Error {
  constructor(message: string, readonly code: string = "gh_failed") {
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

async function fetchPrWithFallback(repository: string, number: number): Promise<PRSnapshot> {
  try {
    return await fetchPr(repository, number);
  } catch (err) {
    if (!shouldFallbackToGh(err)) throw err;
    try {
      return await fetchPrFromGh(repository, number);
    } catch (fallbackErr) {
      throw new GhprSocketError(
        `Local API did not return ${repository}#${number} (${errorMessage(err)}); gh fallback failed: ${errorMessage(fallbackErr)}`,
        fallbackErr instanceof GhCommandError ? fallbackErr.code : "gh_failed",
      );
    }
  }
}

function shouldFallbackToGh(err: unknown): boolean {
  return err instanceof GhprSocketError && err.code !== "invalid_request";
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

async function fetchPrFromGh(repository: string, number: number): Promise<PRSnapshot> {
  const stdout = await runGh([
    "pr",
    "view",
    String(number),
    "--repo",
    repository,
    "--json",
    GH_PR_VIEW_FIELDS.join(","),
  ]);

  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout);
  } catch (err) {
    throw new GhCommandError(`Failed to parse gh JSON: ${errorMessage(err)}`, "gh_invalid_response");
  }

  if (!isRecord(parsed)) {
    throw new GhCommandError("gh returned a non-object PR response.", "gh_invalid_response");
  }

  return ghPullRequestToSnapshot(parsed, repository, number);
}

function runGh(args: string[]): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    execFile(
      "gh",
      args,
      { encoding: "utf8", maxBuffer: MAX_RESPONSE_BYTES, timeout: GH_COMMAND_TIMEOUT_MS },
      (err, stdout, stderr) => {
        if (err) {
          const nodeErr = err as NodeJS.ErrnoException & { killed?: boolean };
          const stderrText = stderr.trim();
          const details = stderrText || nodeErr.message;
          const code =
            nodeErr.code === "ENOENT" ? "gh_not_found" : nodeErr.killed ? "gh_timeout" : "gh_failed";
          reject(new GhCommandError(details, code));
          return;
        }
        resolve(stdout);
      },
    );
  });
}

function ghPullRequestToSnapshot(
  raw: Record<string, unknown>,
  repository: string,
  requestedNumber: number,
): PRSnapshot {
  const number = numberField(raw, "number") ?? requestedNumber;
  const mergedAt = optionalStringField(raw, "mergedAt");
  const updatedAt = optionalStringField(raw, "updatedAt") ?? new Date(0).toISOString();
  const title = optionalStringField(raw, "title") ?? "(untitled)";
  const url = optionalStringField(raw, "url") ?? `https://github.com/${repository}/pull/${number}`;
  const reviewCounts = aggregateGhReviews(raw.latestReviews);
  const ci = deriveGhCI(raw.statusCheckRollup);

  return {
    id: numberField(raw, "fullDatabaseId") ?? stablePrId(repository, number),
    source: "gh",
    section: "mentioned",
    repository,
    number,
    title,
    author: ghAuthorLogin(raw.author),
    url,
    state: normalizeGhPRState(optionalStringField(raw, "state"), mergedAt),
    isDraft: booleanField(raw, "isDraft") ?? false,
    isPinned: false,
    hasBaseConflicts: hasGhBaseConflicts(raw),
    unresolvedCount: 0,
    ciStatus: ci.ciStatus,
    checkSuccessCount: ci.checkSuccessCount,
    checkFailureCount: ci.checkFailureCount,
    checkPendingCount: ci.checkPendingCount,
    ciIsRunning: ci.ciIsRunning,
    approvalCount: reviewCounts.approvalCount,
    changesRequestedCount: reviewCounts.changesRequestedCount,
    myReviewStatus: null,
    jiraTicket: null,
    updatedAt,
    mergedAt,
  };
}

function stablePrId(repository: string, number: number): number {
  let hash = number;
  for (const char of repository.toLowerCase()) {
    hash = (hash * 31 + char.charCodeAt(0)) | 0;
  }
  return Math.abs(hash || number);
}

function normalizeGhPRState(state: string | null, mergedAt: string | null): string {
  if (mergedAt) return "MERGED";
  const normalized = state?.trim().toUpperCase();
  if (normalized === "OPEN" || normalized === "CLOSED" || normalized === "MERGED") {
    return normalized;
  }
  return "OPEN";
}

function hasGhBaseConflicts(raw: Record<string, unknown>): boolean {
  return (
    optionalStringField(raw, "mergeable")?.toUpperCase() === "CONFLICTING" ||
    optionalStringField(raw, "mergeStateStatus")?.toUpperCase() === "DIRTY"
  );
}

function aggregateGhReviews(value: unknown): { approvalCount: number; changesRequestedCount: number } {
  const reviews = Array.isArray(value) ? value.filter(isRecord) : [];
  let approvalCount = 0;
  let changesRequestedCount = 0;
  for (const review of reviews) {
    switch (optionalStringField(review, "state")?.toUpperCase()) {
      case "APPROVED":
        approvalCount += 1;
        break;
      case "CHANGES_REQUESTED":
        changesRequestedCount += 1;
        break;
      default:
        break;
    }
  }
  return { approvalCount, changesRequestedCount };
}

function deriveGhCI(value: unknown): {
  ciStatus: string | null;
  checkSuccessCount: number;
  checkFailureCount: number;
  checkPendingCount: number;
  ciIsRunning: boolean;
} {
  const contexts = collectGhStatusContexts(value);
  let checkSuccessCount = 0;
  let checkFailureCount = 0;
  let checkPendingCount = 0;
  let ciIsRunning = false;
  const seenNames = new Set<string>();

  for (const context of contexts) {
    const key = optionalStringField(context, "name") ?? optionalStringField(context, "context");
    if (key) {
      const normalizedKey = key.toLowerCase();
      if (seenNames.has(normalizedKey)) continue;
      seenNames.add(normalizedKey);
    }

    const conclusion = optionalStringField(context, "conclusion")?.toUpperCase();
    const state = optionalStringField(context, "state")?.toUpperCase();
    const status = optionalStringField(context, "status")?.toUpperCase();

    if (conclusion) {
      switch (conclusion) {
        case "SUCCESS":
          checkSuccessCount += 1;
          break;
        case "FAILURE":
        case "TIMED_OUT":
        case "ACTION_REQUIRED":
        case "STARTUP_FAILURE":
          checkFailureCount += 1;
          break;
        case "CANCELLED":
        case "SKIPPED":
        case "NEUTRAL":
        case "STALE":
          break;
        default:
          checkPendingCount += 1;
          ciIsRunning = true;
          break;
      }
    } else if (state) {
      switch (state) {
        case "SUCCESS":
          checkSuccessCount += 1;
          break;
        case "FAILURE":
        case "ERROR":
          checkFailureCount += 1;
          break;
        case "PENDING":
        case "EXPECTED":
          checkPendingCount += 1;
          if (state === "PENDING") ciIsRunning = true;
          break;
        default:
          break;
      }
    } else if (status && status !== "COMPLETED") {
      checkPendingCount += 1;
      ciIsRunning = true;
    }
  }

  if (contexts.length === 0 && isRecord(value)) {
    const rollupState = optionalStringField(value, "state")?.toUpperCase();
    switch (rollupState) {
      case "SUCCESS":
        checkSuccessCount = 1;
        break;
      case "FAILURE":
      case "ERROR":
        checkFailureCount = 1;
        break;
      case "PENDING":
      case "EXPECTED":
        checkPendingCount = 1;
        if (rollupState === "PENDING") ciIsRunning = true;
        break;
      default:
        break;
    }
  }

  const ciStatus =
    checkFailureCount > 0
      ? "FAILURE"
      : checkPendingCount > 0
        ? "PENDING"
        : checkSuccessCount > 0
          ? "SUCCESS"
          : null;

  return { ciStatus, checkSuccessCount, checkFailureCount, checkPendingCount, ciIsRunning };
}

function collectGhStatusContexts(value: unknown): Record<string, unknown>[] {
  if (Array.isArray(value)) return value.filter(isRecord);
  if (!isRecord(value)) return [];

  const nodes = value.nodes;
  if (Array.isArray(nodes)) return nodes.filter(isRecord);

  const contexts = value.contexts;
  if (isRecord(contexts) && Array.isArray(contexts.nodes)) {
    return contexts.nodes.filter(isRecord);
  }

  return [];
}

function ghAuthorLogin(value: unknown): string {
  if (!isRecord(value)) return "unknown";
  return optionalStringField(value, "login") ?? optionalStringField(value, "name") ?? "unknown";
}

function optionalStringField(record: Record<string, unknown>, key: string): string | null {
  const value = record[key];
  return typeof value === "string" && value.length > 0 ? value : null;
}

function numberField(record: Record<string, unknown>, key: string): number | null {
  const value = record[key];
  return typeof value === "number" ? value : null;
}

function booleanField(record: Record<string, unknown>, key: string): boolean | null {
  const value = record[key];
  return typeof value === "boolean" ? value : null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
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
  const compact = {
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
  return pr.source ? { source: pr.source, ...compact } : compact;
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
      .describe("Case-insensitive substring of OWNER/NAME, e.g. 'example-org/example-repo' or just 'example-org'."),
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
  "Fetch details for a single PR by repository and number. Falls back to `gh pr view` if the PR is not available from PRDashboard's local snapshot.",
  {
    repository: z.string().describe("OWNER/NAME, e.g. 'example-org/example-repo'."),
    number: z.number().int().positive().describe("PR number."),
  },
  async ({ repository, number }) => {
    try {
      const pr = await fetchPrWithFallback(repository, number);
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
