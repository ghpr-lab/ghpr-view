import type { Classification, Confidence, FailedJob, FlakyResult, HistorySummary } from "./schema.ts";

export const FLAKY_CI_PROTOCOL = "ghpr_flaky_ci_analysis";
export const FLAKY_CI_SCHEMA_VERSION = 2;
export const FLAKY_CI_CHECK_NAME_PREFIX = "Flaky CI Analysis";
export const FLAKY_CI_MARKER_PREFIX = "<!-- ghpr-flaky-ci-result:v2:";
export const FLAKY_CI_EXTERNAL_ID_PREFIX = "ghpr-flaky-ci:v2:";
export const MAX_MARKER_BYTES = 60_000;

export type FlakyCIBackendKind = "workflow_dispatch" | "github_app";
export type FlakyCIStatus = "queued" | "in_progress" | "completed" | "stale" | "error";

export interface FlakyCIProtocolBackend {
  kind: FlakyCIBackendKind;
  version: string;
}

export interface FlakyCIProtocolTarget {
  ci_provider: "github_actions";
  run_id: number;
  workflow_name?: string;
  head_sha: string;
}

export interface FlakyCIJobResult {
  job_id: number;
  job_name: string;
  conclusion?: string | null;
  failure_signature: string;
  history: HistorySummary;
}

export interface FlakyCISummary {
  title: string;
  evidence_line: string;
  detail: string;
}

export interface FlakyCIEvidence {
  kind: "root_cause" | "verdict" | "relatedness" | "history" | "related_files" | "tools" | "other";
  message: string;
  url?: string;
}

export interface FlakyCIAction {
  id:
    | "rerun_failed_jobs"
    | "open_failed_run"
    | "open_check_run"
    | "open_artifact"
    | "open_pr_comment"
    | "analyze_again"
    | "investigate_manually";
  label: string;
  enabled: boolean;
  url?: string;
}

export interface FlakyCILinks {
  check_run_url?: string;
  workflow_run_url?: string;
  artifact_url?: string;
}

export interface FlakyCITimestamps {
  created_at: string;
  completed_at?: string;
}

export interface FlakyCIAnalysisResultV2 {
  schema_version: 2;
  protocol: typeof FLAKY_CI_PROTOCOL;
  analysis_id: string;
  request_id: string;
  backend: FlakyCIProtocolBackend;
  status: FlakyCIStatus;
  classification: Classification;
  flaky_score: number;
  relatedness_score: number;
  confidence: Confidence;
  history_influenced: boolean;
  target: FlakyCIProtocolTarget;
  failed_jobs: FlakyCIJobResult[];
  summary: FlakyCISummary;
  evidence: FlakyCIEvidence[];
  suggested_actions: FlakyCIAction[];
  links: FlakyCILinks;
  timestamps: FlakyCITimestamps;
}

export interface BuildProtocolResultOpts {
  owner: string;
  repo: string;
  prNumber: number;
  requestId: string;
  headSha: string;
  workflowName?: string;
  workflowRunUrl?: string;
  failedJobs: FailedJob[];
  jobSignatures: Map<number, string>;
  jobConclusions: Map<number, string | null>;
  primaryHistory: HistorySummary;
  createdAt?: Date;
  completedAt?: Date;
  backendVersion?: string;
}

export const CLASSIFICATION_LABEL: Record<Classification, { plain: string; emoji: string }> = {
  likely_flaky: { plain: "Likely flaky", emoji: "🟡 Likely flaky" },
  likely_blocker: { plain: "Likely blocker", emoji: "🔴 Likely blocker" },
  investigate: { plain: "Needs investigation", emoji: "🔍 Needs investigation" },
};

function flakyScore(classification: Classification, confidence: Confidence): number {
  const confidenceBoost: Record<Confidence, number> = { low: 8, medium: 16, high: 24 };
  if (classification === "likely_flaky") return Math.min(100, 68 + confidenceBoost[confidence]);
  if (classification === "likely_blocker") return Math.max(0, 32 - confidenceBoost[confidence]);
  return 50;
}

function evidenceKind(message: string): FlakyCIEvidence["kind"] {
  if (message.startsWith("root cause:")) return "root_cause";
  if (message.startsWith("verdict:")) return "verdict";
  if (message.startsWith("relatedness:")) return "relatedness";
  if (message.startsWith("history:") || message.startsWith("history override:")) return "history";
  if (message.startsWith("related files:")) return "related_files";
  if (message.startsWith("tools used:")) return "tools";
  return "other";
}

function emptyHistory(): HistorySummary {
  return {
    main_matches: 0,
    main_sampled: 0,
    pr_matches: 0,
    pr_sampled: 0,
    sample_run_urls: [],
  };
}

export function checkRunName(runId: number): string {
  return `${FLAKY_CI_CHECK_NAME_PREFIX} (run ${runId})`;
}

export function externalIdForProtocolResult(
  owner: string,
  repo: string,
  prNumber: number,
  headSha: string,
  runId: number,
  requestId: string,
): string {
  return `${FLAKY_CI_EXTERNAL_ID_PREFIX}${owner}/${repo}#${prNumber}:${headSha}:${runId}:${requestId}`;
}

export function buildProtocolResultV2(
  result: FlakyResult,
  opts: BuildProtocolResultOpts,
): FlakyCIAnalysisResultV2 {
  const history = opts.primaryHistory;
  const runUrl = opts.workflowRunUrl ?? `https://github.com/${opts.owner}/${opts.repo}/actions/runs/${result.run_id}`;
  const primaryJobId = result.failed_jobs[0]?.job_id;
  const evidenceLine = result.history_influenced
    ? "Same signature is active on main"
    : result.evidence.find((e) => e.startsWith("history:")) ?? result.explanation;

  return {
    schema_version: FLAKY_CI_SCHEMA_VERSION,
    protocol: FLAKY_CI_PROTOCOL,
    analysis_id: externalIdForProtocolResult(
      opts.owner,
      opts.repo,
      opts.prNumber,
      opts.headSha,
      result.run_id,
      opts.requestId,
    ),
    request_id: opts.requestId,
    backend: {
      kind: "workflow_dispatch",
      version: opts.backendVersion ?? "0.2.0",
    },
    status: "completed",
    classification: result.classification,
    flaky_score: flakyScore(result.classification, result.confidence),
    relatedness_score: result.relatedness_score,
    confidence: result.confidence,
    history_influenced: result.history_influenced,
    target: {
      ci_provider: "github_actions",
      run_id: result.run_id,
      ...(opts.workflowName ? { workflow_name: opts.workflowName } : {}),
      head_sha: opts.headSha,
    },
    failed_jobs: opts.failedJobs.map((job) => ({
      job_id: job.job_id,
      job_name: job.job_name,
      conclusion: opts.jobConclusions.get(job.job_id),
      failure_signature: opts.jobSignatures.get(job.job_id) ?? "",
      history: job.job_id === primaryJobId ? history : emptyHistory(),
    })),
    summary: {
      title: CLASSIFICATION_LABEL[result.classification].plain,
      evidence_line: evidenceLine || result.error_summary || result.root_cause,
      detail: result.explanation || result.error_summary || result.root_cause,
    },
    evidence: [
      ...result.evidence.map((message) => ({ kind: evidenceKind(message), message })),
      ...history.sample_run_urls.map((url) => ({
        kind: "history" as const,
        message: "Historical matching run",
        url,
      })),
    ],
    suggested_actions: [
      { id: "rerun_failed_jobs", label: "Rerun failed jobs", enabled: true },
      { id: "open_failed_run", label: "Open failed workflow run", enabled: true, url: runUrl },
      { id: "investigate_manually", label: "Investigate manually", enabled: true },
    ],
    links: {
      workflow_run_url: runUrl,
    },
    timestamps: {
      created_at: (opts.createdAt ?? new Date()).toISOString(),
      completed_at: (opts.completedAt ?? new Date()).toISOString(),
    },
  };
}

export function encodeProtocolMarker(result: FlakyCIAnalysisResultV2): string {
  const encoded = Buffer.from(JSON.stringify(result), "utf8").toString("base64url");
  const marker = `${FLAKY_CI_MARKER_PREFIX}${encoded} -->`;
  const markerBytes = Buffer.byteLength(marker, "utf8");
  if (markerBytes > MAX_MARKER_BYTES) {
    throw new Error(`Flaky CI protocol marker is too large: ${markerBytes} bytes`);
  }
  return marker;
}

export function decodeProtocolMarker(text: string): FlakyCIAnalysisResultV2 | null {
  const start = text.indexOf(FLAKY_CI_MARKER_PREFIX);
  if (start < 0) return null;
  const encodedStart = start + FLAKY_CI_MARKER_PREFIX.length;
  const end = text.indexOf(" -->", encodedStart);
  if (end < 0) return null;

  const payload = Buffer.from(text.slice(encodedStart, end), "base64url").toString("utf8");
  const decoded = JSON.parse(payload) as FlakyCIAnalysisResultV2;
  if (decoded.schema_version !== FLAKY_CI_SCHEMA_VERSION || decoded.protocol !== FLAKY_CI_PROTOCOL) {
    return null;
  }
  return decoded;
}
