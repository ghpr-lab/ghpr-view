import * as core from "@actions/core";

export interface AnalyzerInputs {
  schemaVersion: number;
  requestId: string;
  prNumber: number;
  headSha: string;
  runId: number;
  jobIds: number[];
  trigger: string;
  prCodeDir: string;
  correlationId: string;
  writePrComment: boolean;
  dryRun: boolean;
  githubToken: string;
  copilotToken: string;
  actionPath: string;
  model: string;
}

function required(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing required env: ${name}`);
  return v;
}

function parseBool(v: string | undefined, fallback = false): boolean {
  if (v === undefined || v === "") return fallback;
  return /^(1|true|yes)$/i.test(v);
}

function parsePositiveInt(name: string, raw: string): number {
  const n = Number(raw);
  if (!Number.isInteger(n) || n <= 0) {
    throw new Error(`Invalid ${name}: expected positive integer, got ${JSON.stringify(raw)}`);
  }
  return n;
}

function parseOptionalPositiveInt(name: string, raw: string | undefined, fallback: number): number {
  if (raw === undefined || raw.trim() === "") return fallback;
  return parsePositiveInt(name, raw);
}

function parseJobIds(raw: string | undefined): number[] {
  if (raw === undefined || raw.trim() === "") return [];
  return raw
    .split(",")
    .map((part) => part.trim())
    .filter(Boolean)
    .map((part) => parsePositiveInt("job_ids", part));
}

export function parseInputs(): AnalyzerInputs {
  const schemaVersion = parseOptionalPositiveInt("schema_version", process.env.INPUT_SCHEMA_VERSION, 2);
  const prNumber = parsePositiveInt("pr_number", required("INPUT_PR_NUMBER"));
  const runId = parsePositiveInt("run_id", required("INPUT_RUN_ID"));
  const headSha = required("INPUT_HEAD_SHA").trim();
  if (!/^[0-9a-f]{7,40}$/i.test(headSha)) {
    throw new Error(`Invalid head_sha: ${JSON.stringify(headSha)}`);
  }

  const correlationId = process.env.INPUT_CORRELATION_ID ?? "";
  const requestId = process.env.INPUT_REQUEST_ID?.trim() || correlationId || `run-${runId}`;

  return {
    schemaVersion,
    requestId,
    prNumber,
    headSha,
    runId,
    jobIds: parseJobIds(process.env.INPUT_JOB_IDS),
    trigger: process.env.INPUT_TRIGGER?.trim() || "manual",
    prCodeDir: required("INPUT_PR_CODE_DIR"),
    correlationId,
    writePrComment: parseBool(process.env.INPUT_WRITE_PR_COMMENT, false),
    dryRun: parseBool(process.env.INPUT_DRY_RUN, false),
    githubToken: required("GITHUB_TOKEN"),
    copilotToken: required("COPILOT_GITHUB_TOKEN"),
    actionPath: required("ACTION_PATH"),
    model: process.env.FLAKY_MODEL?.trim() || "claude-sonnet-4.6",
  };
}

export async function validateHeadSha(
  inputs: AnalyzerInputs,
  fetchPrHead: (prNumber: number) => Promise<string>,
): Promise<void> {
  const realHead = await fetchPrHead(inputs.prNumber);
  if (realHead.toLowerCase() !== inputs.headSha.toLowerCase()) {
    throw new Error(
      `head_sha mismatch: input=${inputs.headSha} but PR #${inputs.prNumber} head=${realHead}. ` +
        `Refusing to run — dispatcher may be stale or forged.`,
    );
  }
  core.info(`head_sha validated: ${realHead}`);
}
