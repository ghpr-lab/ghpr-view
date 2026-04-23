import type {
  AgentOutput,
  Classification,
  ClassifyMeta,
  Confidence,
  FlakyResult,
} from "./schema.ts";

const SUGGESTED_ACTIONS: Record<Classification, string[]> = {
  likely_flaky: ["Rerun failed jobs", "Consider quarantine if it re-occurs"],
  likely_blocker: ["Review the related changed files", "Reproduce locally"],
  investigate: [
    "Verdict and correlation disagree — open the full logs",
    "Ask the CI owner",
  ],
};

export function classify(agent: AgentOutput, meta: ClassifyMeta): FlakyResult {
  const historyInfluenced = meta.history.main_matches >= 2;
  let classification: Classification;
  if (historyInfluenced) {
    classification = "likely_flaky";
  } else if (agent.verdict === "blocker" && agent.relatedness_score >= 0.5) {
    classification = "likely_blocker";
  } else if (agent.verdict === "flaky" && agent.relatedness_score < 0.5) {
    classification = "likely_flaky";
  } else {
    classification = "investigate";
  }

  const agrees =
    (agent.verdict === "flaky" && agent.relatedness_score < 0.5) ||
    (agent.verdict === "blocker" && agent.relatedness_score >= 0.5);
  const confidence: Confidence = historyInfluenced
    ? "high"
    : agrees
      ? agent.confidence
      : "low";

  const evidence: string[] = [
    `root cause: ${agent.root_cause || "(none)"}`,
    `verdict: ${agent.verdict} — ${agent.rationale || "(no rationale)"}`,
    `relatedness: ${agent.relatedness_score.toFixed(2)}`,
    `failure signature: ${meta.failure_signature || "(none)"}`,
    `history: signature matched in ${meta.history.main_matches}/${meta.history.main_sampled} main failures, ${meta.history.pr_matches}/${meta.history.pr_sampled} recent PR failures`,
  ];
  if (meta.history.sample_run_urls.length > 0) {
    evidence.push(`history matched runs: ${meta.history.sample_run_urls.join(", ")}`);
  }
  if (agent.related_files.length > 0) {
    evidence.push(`related files: ${agent.related_files.join(", ")}`);
  }
  if (agent.tools_used.length > 0) {
    evidence.push(`tools used: ${agent.tools_used.join(", ")}`);
  }
  if (!agrees && !historyInfluenced) {
    evidence.push(
      `disagreement: verdict=${agent.verdict} vs relatedness=${agent.relatedness_score.toFixed(2)} — classified as investigate`,
    );
  }
  if (historyInfluenced) {
    evidence.push("history override: this signature is active on main");
  }

  const explanation = agent.error_summary || agent.rationale || "";

  const result: FlakyResult = {
    schema_version: 1,
    classification,
    verdict: agent.verdict,
    relatedness_score: agent.relatedness_score,
    confidence,
    failure_signature: meta.failure_signature,
    history: meta.history,
    history_influenced: historyInfluenced,
    root_cause: agent.root_cause,
    error_summary: agent.error_summary,
    related_files: agent.related_files,
    evidence,
    suggested_actions: SUGGESTED_ACTIONS[classification],
    explanation,
    tools_used: agent.tools_used,
    agent_model: meta.agent_model,
    ci_provider: "github_actions",
    backend: "workflow",
    run_id: meta.run_id,
    failed_jobs: meta.failed_jobs,
  };
  if (meta.correlation_id) result.correlation_id = meta.correlation_id;
  return result;
}
