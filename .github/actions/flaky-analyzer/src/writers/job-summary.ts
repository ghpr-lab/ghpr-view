import * as core from "@actions/core";
import type { FlakyResult } from "../schema.ts";
import { CLASSIFICATION_LABEL } from "../protocol-v2.ts";

export async function writeJobSummary(result: FlakyResult): Promise<void> {
  const md = renderSummary(result);
  await core.summary.addRaw(md, true).write();
}

export function renderSummary(r: FlakyResult): string {
  const lines: string[] = [];
  lines.push(`## Flaky CI Review — ${CLASSIFICATION_LABEL[r.classification].emoji}`);
  lines.push("");
  lines.push(`**Verdict:** \`${r.verdict}\``);
  lines.push(`**Relatedness:** \`${r.relatedness_score.toFixed(2)}\``);
  lines.push(`**Confidence:** \`${r.confidence}\``);
  lines.push(`**Model:** \`${r.agent_model}\`  ·  **Run:** \`${r.run_id}\``);
  if (r.failure_signature) {
    lines.push(`**Failure signature:** \`${r.failure_signature}\``);
  }
  lines.push(
    `**History:** main \`${r.history.main_matches}/${r.history.main_sampled}\` · recent PRs \`${r.history.pr_matches}/${r.history.pr_sampled}\``,
  );
  if (r.history_influenced) {
    lines.push(`**History override:** active on main`);
  }
  lines.push("");
  lines.push(`**Root cause:** ${r.root_cause || "_n/a_"}`);
  if (r.error_summary) {
    lines.push("");
    lines.push(`> ${r.error_summary.replace(/\n/g, "\n> ")}`);
  }
  if (r.failed_jobs.length > 0) {
    lines.push("");
    lines.push(`**Failed jobs:** ${r.failed_jobs.map((j) => `\`${j.job_name}\``).join(", ")}`);
  }
  if (r.evidence.length > 0) {
    lines.push("");
    lines.push(`**Evidence:**`);
    for (const e of r.evidence) lines.push(`- ${e}`);
  }
  if (r.suggested_actions.length > 0) {
    lines.push("");
    lines.push(`**Suggested actions:**`);
    for (const a of r.suggested_actions) lines.push(`- ${a}`);
  }
  if (r.correlation_id) {
    lines.push("");
    lines.push(`<sub>correlation_id: \`${r.correlation_id}\`</sub>`);
  }
  return lines.join("\n") + "\n";
}
