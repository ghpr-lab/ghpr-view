import { describe, expect, test } from "bun:test";
import { classify } from "./classify.ts";
import {
  buildProtocolResultV2,
  checkRunName,
  decodeProtocolMarker,
  encodeProtocolMarker,
  externalIdForProtocolResult,
  MAX_MARKER_BYTES,
} from "./protocol-v2.ts";
import type { AgentOutput, HistorySummary } from "./schema.ts";

const agent: AgentOutput = {
  failure_signature: "Error: service timed out",
  root_cause: "service timed out",
  error_summary: "The service timed out during startup.",
  verdict: "flaky",
  relatedness_score: 0.2,
  related_files: [],
  rationale: "The diff does not touch the failing service.",
  confidence: "high",
  tools_used: ["read"],
};

const history: HistorySummary = {
  main_matches: 2,
  main_sampled: 3,
  pr_matches: 1,
  pr_sampled: 3,
  sample_run_urls: ["https://github.com/acme/web/actions/runs/1"],
};

function makeProtocolResult() {
  const result = classify(agent, {
    run_id: 987,
    failed_jobs: [{ job_id: 111, job_name: "macos / test" }],
    agent_model: "test-model",
    failure_signature: "Error: service timed out",
    history,
  });

  return buildProtocolResultV2(result, {
    owner: "acme",
    repo: "web",
    prNumber: 123,
    requestId: "req-1",
    headSha: "abc123",
    workflowName: "CI",
    workflowRunUrl: "https://github.com/acme/web/actions/runs/987",
    failedJobs: [{ job_id: 111, job_name: "macos / test" }],
    jobSignatures: new Map([[111, "Error: service timed out"]]),
    jobConclusions: new Map([[111, "failure"]]),
    primaryHistory: history,
    createdAt: new Date("2026-04-23T10:00:00Z"),
    completedAt: new Date("2026-04-23T10:01:00Z"),
  });
}

describe("protocol v2", () => {
  test("builds a v2 result from the v1 classifier result", () => {
    const result = makeProtocolResult();

    expect(result.schema_version).toBe(2);
    expect(result.protocol).toBe("ghpr_flaky_ci_analysis");
    expect(result.backend.kind).toBe("workflow_dispatch");
    expect(result.status).toBe("completed");
    expect(result.classification).toBe("likely_flaky");
    expect(result.flaky_score).toBeGreaterThan(80);
    expect(result.failed_jobs[0]?.failure_signature).toBe("Error: service timed out");
    expect(result.failed_jobs[0]?.history.main_matches).toBe(2);
    expect(result.suggested_actions[0]?.id).toBe("rerun_failed_jobs");
  });

  test("encodes and decodes the Check Run marker", () => {
    const result = makeProtocolResult();
    const marker = encodeProtocolMarker(result);
    const decoded = decodeProtocolMarker(`${marker}\n\n## Flaky CI Analysis`);

    expect(decoded?.analysis_id).toBe(result.analysis_id);
    expect(decoded?.target.run_id).toBe(987);
  });

  test("returns null for a missing marker", () => {
    expect(decodeProtocolMarker("## Flaky CI Analysis")).toBeNull();
  });

  test("generates standard Check Run name and external id", () => {
    expect(checkRunName(987)).toBe("Flaky CI Analysis (run 987)");
    expect(externalIdForProtocolResult("acme", "web", 123, "abc123", 987, "req-1")).toBe(
      "ghpr-flaky-ci:v2:acme/web#123:abc123:987:req-1",
    );
  });

  test("rejects oversized markers", () => {
    const result = makeProtocolResult();
    result.evidence = [{
      kind: "other",
      message: "x".repeat(MAX_MARKER_BYTES),
    }];

    expect(() => encodeProtocolMarker(result)).toThrow("too large");
  });
});
