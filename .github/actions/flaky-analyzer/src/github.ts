import * as core from "@actions/core";
import { getOctokit, context } from "@actions/github";

export interface GhJob {
  id: number;
  name: string;
  conclusion: string | null;
}

export interface GhWorkflowRun {
  id: number;
  workflow_id: number;
  name: string | null;
  event: string;
  conclusion: string | null;
  head_branch: string | null;
  html_url: string;
  pull_requests: { number: number }[] | null;
}

export interface GhContext {
  octokit: ReturnType<typeof getOctokit>;
  owner: string;
  repo: string;
}

export function makeGh(githubToken: string): GhContext {
  const octokit = getOctokit(githubToken);
  const { owner, repo } = context.repo;
  return { octokit, owner, repo };
}

export async function fetchPrHeadSha(gh: GhContext, prNumber: number): Promise<string> {
  const { data } = await gh.octokit.rest.pulls.get({
    owner: gh.owner,
    repo: gh.repo,
    pull_number: prNumber,
  });
  return data.head.sha;
}

function isFailedConclusion(conclusion: string | null): boolean {
  return conclusion === "failure" || conclusion === "cancelled" || conclusion === "timed_out";
}

export async function listFailedJobs(gh: GhContext, runId: number): Promise<GhJob[]> {
  const jobs: GhJob[] = [];
  const iter = gh.octokit.paginate.iterator(gh.octokit.rest.actions.listJobsForWorkflowRun, {
    owner: gh.owner,
    repo: gh.repo,
    run_id: runId,
    per_page: 100,
  });
  for await (const { data } of iter) {
    for (const j of data) {
      if (isFailedConclusion(j.conclusion)) {
        jobs.push({ id: j.id, name: j.name, conclusion: j.conclusion });
      }
    }
  }
  return jobs;
}

export async function findFailedJobByName(
  gh: GhContext,
  runId: number,
  jobName: string,
): Promise<GhJob | null> {
  const iter = gh.octokit.paginate.iterator(gh.octokit.rest.actions.listJobsForWorkflowRun, {
    owner: gh.owner,
    repo: gh.repo,
    run_id: runId,
    per_page: 100,
  });
  for await (const { data } of iter) {
    for (const j of data) {
      if (j.name === jobName && isFailedConclusion(j.conclusion)) {
        return { id: j.id, name: j.name, conclusion: j.conclusion };
      }
    }
  }
  return null;
}

function mapWorkflowRun(run: {
  id: number;
  workflow_id: number;
  name?: string | null;
  event: string;
  conclusion: string | null;
  head_branch: string | null;
  html_url: string;
  pull_requests: { number: number }[] | null;
}): GhWorkflowRun {
  return {
    id: run.id,
    workflow_id: run.workflow_id,
    name: run.name ?? null,
    event: run.event,
    conclusion: run.conclusion,
    head_branch: run.head_branch,
    html_url: run.html_url,
    pull_requests: run.pull_requests?.map((pr) => ({ number: pr.number })) ?? null,
  };
}

export async function getWorkflowRun(gh: GhContext, runId: number): Promise<GhWorkflowRun> {
  const { data } = await gh.octokit.rest.actions.getWorkflowRun({
    owner: gh.owner,
    repo: gh.repo,
    run_id: runId,
  });
  return mapWorkflowRun(data);
}

export async function listRecentFailedRuns(
  gh: GhContext,
  workflowId: number,
  opts: {
    branch?: string;
    event?: string;
    excludePrNumber?: number;
    limit: number;
  },
): Promise<GhWorkflowRun[]> {
  const runs: GhWorkflowRun[] = [];
  const iter = gh.octokit.paginate.iterator(gh.octokit.rest.actions.listWorkflowRuns, {
    owner: gh.owner,
    repo: gh.repo,
    workflow_id: workflowId,
    status: "failure",
    ...(opts.branch ? { branch: opts.branch } : {}),
    ...(opts.event ? { event: opts.event } : {}),
    per_page: 100,
  });

  outer:
  for await (const { data } of iter) {
    for (const rawRun of data) {
      const run = mapWorkflowRun(rawRun);
      if (opts.excludePrNumber !== undefined) {
        if (!run.pull_requests || run.pull_requests.length === 0) continue;
        if (run.pull_requests.some((pr) => pr.number === opts.excludePrNumber)) continue;
      }
      runs.push(run);
      if (runs.length >= opts.limit) break outer;
    }
  }

  return runs;
}

export async function fetchJobLog(gh: GhContext, jobId: number): Promise<string> {
  // REST returns a text/plain body (or a redirect to it).
  const res = await gh.octokit.request("GET /repos/{owner}/{repo}/actions/jobs/{job_id}/logs", {
    owner: gh.owner,
    repo: gh.repo,
    job_id: jobId,
  });
  const body = res.data;
  if (typeof body === "string") return body;
  if (body instanceof ArrayBuffer) return new TextDecoder().decode(body);
  // octokit can hand us a Node Buffer-like object
  if (body && typeof (body as { toString?: unknown }).toString === "function") {
    return String(body);
  }
  return "";
}

export async function fetchPrDiffFilenames(gh: GhContext, prNumber: number): Promise<string[]> {
  const names: string[] = [];
  const iter = gh.octokit.paginate.iterator(gh.octokit.rest.pulls.listFiles, {
    owner: gh.owner,
    repo: gh.repo,
    pull_number: prNumber,
    per_page: 100,
  });
  for await (const { data } of iter) {
    for (const f of data) names.push(f.filename);
  }
  return names;
}

export async function fetchPrDiffPatch(gh: GhContext, prNumber: number): Promise<string> {
  const res = await gh.octokit.rest.pulls.get({
    owner: gh.owner,
    repo: gh.repo,
    pull_number: prNumber,
    mediaType: { format: "diff" },
  });
  // With `mediaType.format=diff`, octokit returns the raw patch string as data.
  return typeof res.data === "string" ? res.data : "";
}

export async function upsertCheckRun(
  gh: GhContext,
  headSha: string,
  name: string,
  conclusion: "neutral" | "failure",
  summary: string,
  text: string,
  externalId?: string,
): Promise<number> {
  // Try to find an existing Check Run with this name on this SHA; update if present, else create.
  const existing = await gh.octokit.rest.checks.listForRef({
    owner: gh.owner,
    repo: gh.repo,
    ref: headSha,
    check_name: name,
    per_page: 1,
  });
  if (existing.data.check_runs.length > 0) {
    const existingRun = existing.data.check_runs[0];
    if (existingRun) {
      const id = existingRun.id;
      await gh.octokit.rest.checks.update({
        owner: gh.owner,
        repo: gh.repo,
        check_run_id: id,
        status: "completed",
        conclusion,
        ...(externalId ? { external_id: externalId } : {}),
        output: { title: name, summary, text },
      });
      return id;
    }
  }
  const created = await gh.octokit.rest.checks.create({
    owner: gh.owner,
    repo: gh.repo,
    name,
    head_sha: headSha,
    status: "completed",
    conclusion,
    ...(externalId ? { external_id: externalId } : {}),
    output: { title: name, summary, text },
  });
  return created.data.id;
}

/** Upsert a PR comment identified by an HTML marker. Returns the comment id, or null on 403. */
export async function upsertPrComment(
  gh: GhContext,
  prNumber: number,
  marker: string,
  body: string,
): Promise<number | null> {
  const fullBody = `${marker}\n${body}`;
  try {
    const iter = gh.octokit.paginate.iterator(gh.octokit.rest.issues.listComments, {
      owner: gh.owner,
      repo: gh.repo,
      issue_number: prNumber,
      per_page: 100,
    });
    for await (const { data } of iter) {
      for (const c of data) {
        if (c.body && c.body.includes(marker)) {
          await gh.octokit.rest.issues.updateComment({
            owner: gh.owner,
            repo: gh.repo,
            comment_id: c.id,
            body: fullBody,
          });
          return c.id;
        }
      }
    }
    const created = await gh.octokit.rest.issues.createComment({
      owner: gh.owner,
      repo: gh.repo,
      issue_number: prNumber,
      body: fullBody,
    });
    return created.data.id;
  } catch (err: unknown) {
    const e = err as { status?: number; message?: string };
    if (e.status === 403) {
      core.warning(
        `PR comment upsert denied (403). The workflow likely needs 'pull-requests: write' + 'issues: write'. Skipping.`,
      );
      return null;
    }
    throw err;
  }
}
