import type { FlakyResult } from "../schema.ts";
import { upsertCheckRun, type GhContext } from "../github.ts";
import {
  checkRunName,
  encodeProtocolMarker,
  externalIdForProtocolResult,
  type FlakyCIAnalysisResultV2,
} from "../protocol-v2.ts";
import { renderSummary } from "./job-summary.ts";

const BADGE: Record<FlakyResult["classification"], string> = {
  likely_flaky: "Likely flaky",
  likely_blocker: "Likely blocker",
  investigate: "Needs investigation",
};

export async function writeCheckRun(
  gh: GhContext,
  headSha: string,
  result: FlakyResult,
  protocolResult?: FlakyCIAnalysisResultV2,
  prNumber?: number,
  requestId?: string,
): Promise<void> {
  const name = checkRunName(result.run_id);
  const conclusion = result.classification === "likely_blocker" ? "failure" : "neutral";
  const summary = `${BADGE[result.classification]} · verdict=${result.verdict} · relatedness=${result.relatedness_score.toFixed(2)} · confidence=${result.confidence}`;
  const marker = protocolResult ? `${encodeProtocolMarker(protocolResult)}\n\n` : "";
  const text = `${marker}${renderSummary(result)}`;
  const externalId =
    prNumber !== undefined && requestId
      ? externalIdForProtocolResult(gh.owner, gh.repo, prNumber, headSha, result.run_id, requestId)
      : undefined;
  await upsertCheckRun(gh, headSha, name, conclusion, summary, text, externalId);
}
