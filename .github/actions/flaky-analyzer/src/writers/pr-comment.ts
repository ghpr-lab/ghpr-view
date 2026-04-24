import type { FlakyResult } from "../schema.ts";
import { upsertPrComment, type GhContext } from "../github.ts";
import { renderSummary } from "./job-summary.ts";

export async function writePrComment(
  gh: GhContext,
  prNumber: number,
  result: FlakyResult,
): Promise<void> {
  const marker = `<!-- flaky-ci-review:pr=${prNumber};run=${result.run_id} -->`;
  const body = renderSummary(result);
  await upsertPrComment(gh, prNumber, marker, body);
}
