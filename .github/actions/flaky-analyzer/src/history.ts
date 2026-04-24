import * as core from "@actions/core";
import { fetchJobLog, listFailedJobs, listRecentFailedRuns, type GhContext, type GhWorkflowRun } from "./github.ts";
import { stripLogNoise } from "./preprocess.ts";
import { redactSecrets } from "./redact.ts";
import { extractSignature } from "./signature.ts";
import type { HistorySummary } from "./schema.ts";

const RUN_LIST_LIMIT = 20;
const RUN_SAMPLE_CAP = 3;
const JOBS_PER_RUN_CAP = 10;

export interface HistoryBucket {
  sampled: number;
  matches: number;
  sample_urls: string[];
}

export interface HistoryJson {
  failure_signature: string;
  job_name: string;
  main: HistoryBucket;
  recent_prs: HistoryBucket;
  error?: string;
}

export interface FetchHistoryOpts {
  workflowId: number;
  currentFailedJobName: string;
  currentSignature: string;
  prNumber: number;
}

function emptyBucket(): HistoryBucket {
  return { sampled: 0, matches: 0, sample_urls: [] };
}

export function emptyHistory(
  failureSignature: string,
  jobName: string,
  error?: string,
): HistoryJson {
  return {
    failure_signature: failureSignature,
    job_name: jobName,
    main: emptyBucket(),
    recent_prs: emptyBucket(),
    ...(error ? { error } : {}),
  };
}

export function historyToSummary(history: HistoryJson): HistorySummary {
  return {
    main_matches: history.main.matches,
    main_sampled: history.main.sampled,
    pr_matches: history.recent_prs.matches,
    pr_sampled: history.recent_prs.sampled,
    sample_run_urls: [...history.main.sample_urls, ...history.recent_prs.sample_urls],
  };
}

async function sampleBucket(
  gh: GhContext,
  label: string,
  runs: GhWorkflowRun[],
  signature: string,
): Promise<HistoryBucket> {
  const started = Date.now();
  const bucket = emptyBucket();

  for (const run of runs) {
    if (bucket.sampled >= RUN_SAMPLE_CAP) break;

    let failedJobs;
    try {
      failedJobs = await listFailedJobs(gh, run.id);
    } catch (err: unknown) {
      core.warning(`History ${label}: failed to list jobs for run ${run.id}: ${(err as Error).message}`);
      continue;
    }
    if (failedJobs.length === 0) continue;

    bucket.sampled += 1;
    let matched = false;
    const toInspect = failedJobs.slice(0, JOBS_PER_RUN_CAP);
    for (const job of toInspect) {
      let log = "";
      try {
        log = await fetchJobLog(gh, job.id);
      } catch (err: unknown) {
        core.warning(`History ${label}: failed to fetch log for job ${job.id}: ${(err as Error).message}`);
        continue;
      }
      const candidateSignature = extractSignature(redactSecrets(stripLogNoise(log)));
      if (candidateSignature === signature) {
        matched = true;
        break;
      }
    }
    if (matched) {
      bucket.matches += 1;
      bucket.sample_urls.push(run.html_url);
    }
  }

  core.info(
    `History ${label}: sampled=${bucket.sampled} matches=${bucket.matches} elapsed_ms=${Date.now() - started}`,
  );
  return bucket;
}

export async function fetchFailureHistory(
  gh: GhContext,
  opts: FetchHistoryOpts,
): Promise<HistoryJson> {
  if (!opts.currentSignature) {
    return emptyHistory(opts.currentSignature, opts.currentFailedJobName);
  }

  const base = emptyHistory(opts.currentSignature, opts.currentFailedJobName);
  try {
    const mainRuns = await listRecentFailedRuns(gh, opts.workflowId, {
      branch: "main",
      limit: RUN_LIST_LIMIT,
    });
    const prRuns = await listRecentFailedRuns(gh, opts.workflowId, {
      event: "pull_request",
      excludePrNumber: opts.prNumber,
      limit: RUN_LIST_LIMIT,
    });

    return {
      ...base,
      main: await sampleBucket(gh, "main", mainRuns, opts.currentSignature),
      recent_prs: await sampleBucket(gh, "recent_prs", prRuns, opts.currentSignature),
    };
  } catch (err: unknown) {
    const message = (err as Error).message || String(err);
    core.warning(`History lookup failed: ${message}`);
    return emptyHistory(opts.currentSignature, opts.currentFailedJobName, message);
  }
}
