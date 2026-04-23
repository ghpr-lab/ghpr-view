import * as core from "@actions/core";
import * as fs from "node:fs";
import * as path from "node:path";
import { parseInputs, validateHeadSha } from "./inputs.ts";
import {
  fetchJobLog,
  fetchPrDiffFilenames,
  fetchPrDiffPatch,
  fetchPrHeadSha,
  getWorkflowRun,
  listFailedJobs,
  makeGh,
} from "./github.ts";
import { filterNoisyFilenames, stripLogNoise } from "./preprocess.ts";
import { sliceAroundFailure } from "./logs.ts";
import { redactSecrets } from "./redact.ts";
import { extractSignature } from "./signature.ts";
import { emptyHistory, fetchFailureHistory, historyToSummary } from "./history.ts";
import { runCopilotAgent } from "./agent.ts";
import { classify } from "./classify.ts";
import { writeFinalResult } from "./final-result.ts";
import { buildProtocolResultV2 } from "./protocol-v2.ts";
import { writeJobSummary } from "./writers/job-summary.ts";
import { writeCheckRun } from "./writers/check-run.ts";
import { writePrComment } from "./writers/pr-comment.ts";

const LOG_TAIL_BYTES = 40_000;

async function main(): Promise<void> {
  const inputs = parseInputs();
  const gh = makeGh(inputs.githubToken);

  await validateHeadSha(inputs, (n) => fetchPrHeadSha(gh, n));

  const allJobs = await listFailedJobs(gh, inputs.runId);
  const requestedJobIds = new Set(inputs.jobIds);
  const jobs = requestedJobIds.size > 0
    ? allJobs.filter((job) => requestedJobIds.has(job.id))
    : allJobs;
  core.info(`Found ${jobs.length} failed job(s) in run ${inputs.runId}`);

  const primaryJob = jobs[0];
  let primaryFilteredLog = "";
  const jobSignatures = new Map<number, string>();
  const jobConclusions = new Map<number, string | null>();
  const rawLogs: string[] = [];
  const filteredLogs: string[] = [];
  for (const j of jobs) {
    core.info(`Fetching log for job ${j.id} (${j.name})…`);
    let log = "";
    try {
      log = await fetchJobLog(gh, j.id);
    } catch (err: unknown) {
      core.warning(`Failed to fetch log for job ${j.id}: ${(err as Error).message}`);
      log = `(failed to fetch log for job ${j.id}: ${(err as Error).message})\n`;
    }
    const redactedRawLog = redactSecrets(log);
    const filteredLog = redactSecrets(stripLogNoise(log));
    const jobSignature = extractSignature(filteredLog);
    jobSignatures.set(j.id, jobSignature);
    jobConclusions.set(j.id, j.conclusion);
    rawLogs.push(`\n===== JOB ${j.id} ${j.name} =====\n${redactedRawLog}`);
    filteredLogs.push(`\n===== JOB ${j.id} ${j.name} =====\n${filteredLog}`);
    if (primaryJob?.id === j.id) {
      primaryFilteredLog = filteredLog;
    }
  }

  const rawLogsBlob = rawLogs.join("");
  const filteredLogsBlob = sliceAroundFailure(filteredLogs.join(""), LOG_TAIL_BYTES);
  const failureSignature = primaryJob ? jobSignatures.get(primaryJob.id) ?? extractSignature(primaryFilteredLog) : "";

  core.info(`Fetching PR diff filenames…`);
  const rawDiffFiles = await fetchPrDiffFilenames(gh, inputs.prNumber);
  const filteredDiffFiles = filterNoisyFilenames(rawDiffFiles);

  core.info(`Fetching PR unified diff patch…`);
  let diffPatch = "";
  try {
    diffPatch = await fetchPrDiffPatch(gh, inputs.prNumber);
  } catch (err: unknown) {
    core.warning(`Failed to fetch PR diff patch: ${(err as Error).message}`);
  }

  const ioDir = path.join(inputs.prCodeDir, ".tmp", "flaky");
  fs.mkdirSync(ioDir, { recursive: true });

  let history = emptyHistory(failureSignature, primaryJob?.name ?? "");
  let currentRun: Awaited<ReturnType<typeof getWorkflowRun>> | null = null;
  if (primaryJob && failureSignature) {
    try {
      core.info(`Fetching recent workflow-level failure history (primary job: "${primaryJob.name}")…`);
      currentRun = await getWorkflowRun(gh, inputs.runId);
      history = await fetchFailureHistory(gh, {
        workflowId: currentRun.workflow_id,
        currentFailedJobName: primaryJob.name,
        currentSignature: failureSignature,
        prNumber: inputs.prNumber,
      });
    } catch (err: unknown) {
      const message = (err as Error).message || String(err);
      core.warning(`History lookup failed: ${message}`);
      history = emptyHistory(failureSignature, primaryJob.name, message);
    }
  } else {
    core.info("Skipping history lookup because no primary failed job signature was available.");
  }

  fs.writeFileSync(path.join(ioDir, "logs.raw.txt"), rawLogsBlob);
  fs.writeFileSync(path.join(ioDir, "logs.txt"), filteredLogsBlob);
  fs.writeFileSync(path.join(ioDir, "diff-files.raw.txt"), rawDiffFiles.join("\n"));
  fs.writeFileSync(
    path.join(ioDir, "diff-files.txt"),
    filteredDiffFiles.length > 0
      ? filteredDiffFiles.join("\n")
      : "(all changed files were auto-generated / lockfiles)",
  );
  fs.writeFileSync(path.join(ioDir, "diff.patch"), diffPatch);
  fs.writeFileSync(
    path.join(ioDir, "context.json"),
    JSON.stringify(
      {
        pr_number: inputs.prNumber,
        schema_version: inputs.schemaVersion,
        request_id: inputs.requestId,
        trigger: inputs.trigger,
        run_id: inputs.runId,
        head_sha: inputs.headSha,
        failed_jobs: jobs.map((j) => ({ job_id: j.id, job_name: j.name })),
        primary_failed_job: primaryJob
          ? { job_id: primaryJob.id, job_name: primaryJob.name }
          : null,
        failure_signature: failureSignature,
      },
      null,
      2,
    ),
  );
  fs.writeFileSync(path.join(ioDir, "history.json"), JSON.stringify(history, null, 2));

  const agentOut = await runCopilotAgent({
    actionPath: inputs.actionPath,
    prCodeDir: inputs.prCodeDir,
    ioDir,
    model: inputs.model,
  });

  const result = classify(agentOut, {
    run_id: inputs.runId,
    failed_jobs: jobs.map((j) => ({ job_id: j.id, job_name: j.name })),
    agent_model: inputs.model,
    failure_signature: failureSignature,
    history: historyToSummary(history),
    correlation_id: inputs.correlationId || undefined,
  });
  const protocolResult = buildProtocolResultV2(result, {
    owner: gh.owner,
    repo: gh.repo,
    prNumber: inputs.prNumber,
    requestId: inputs.requestId,
    headSha: inputs.headSha,
    workflowName: currentRun?.name ?? undefined,
    workflowRunUrl: currentRun?.html_url,
    failedJobs: jobs.map((j) => ({ job_id: j.id, job_name: j.name })),
    jobSignatures,
    jobConclusions,
    primaryHistory: historyToSummary(history),
  });
  writeFinalResult(ioDir, protocolResult);

  await writeJobSummary(result);

  if (!inputs.dryRun) {
    try {
      await writeCheckRun(gh, inputs.headSha, result, protocolResult, inputs.prNumber, inputs.requestId);
    } catch (err: unknown) {
      core.warning(`Check Run write failed: ${(err as Error).message}`);
    }
    if (inputs.writePrComment) {
      try {
        await writePrComment(gh, inputs.prNumber, result);
      } catch (err: unknown) {
        core.warning(`PR comment write failed: ${(err as Error).message}`);
      }
    }
  } else {
    core.info("dry_run=true — skipping Check Run and PR comment writes.");
  }

  core.setOutput("classification", result.classification);
  core.setOutput("verdict", result.verdict);
  core.setOutput("result_json", JSON.stringify(result));
  core.info(
    `Done — classification=${result.classification} verdict=${result.verdict} relatedness=${result.relatedness_score.toFixed(2)}`,
  );
}

main().catch((err: unknown) => {
  const e = err as Error;
  core.setFailed(e.message ?? String(err));
  if (e.stack) core.debug(e.stack);
});
