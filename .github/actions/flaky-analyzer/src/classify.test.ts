import { describe, expect, test } from "bun:test";
import { classify } from "./classify.ts";
import type { AgentOutput, ClassifyMeta, HistorySummary } from "./schema.ts";

const baseAgent: AgentOutput = {
  root_cause: "unit test failed because assertion mismatched",
  error_summary: "The test assertion failed.",
  verdict: "blocker",
  relatedness_score: 0.8,
  related_files: ["src/app.ts"],
  rationale: "The failing symbol is in the PR diff.",
  confidence: "medium",
  tools_used: ["read", "grep"],
};

const emptyHistory: HistorySummary = {
  main_matches: 0,
  main_sampled: 0,
  pr_matches: 0,
  pr_sampled: 0,
  sample_run_urls: [],
};

function meta(history: HistorySummary = emptyHistory): ClassifyMeta {
  return {
    run_id: 123,
    failed_jobs: [{ job_id: 456, job_name: "test" }],
    agent_model: "test-model",
    failure_signature: "Error: assertion failed",
    history,
  };
}

describe("classify", () => {
  test("uses history override when main has at least two matches", () => {
    const result = classify(baseAgent, meta({
      main_matches: 2,
      main_sampled: 3,
      pr_matches: 1,
      pr_sampled: 3,
      sample_run_urls: ["https://github.com/acme/app/actions/runs/1"],
    }));

    expect(result.classification).toBe("likely_flaky");
    expect(result.confidence).toBe("high");
    expect(result.history_influenced).toBe(true);
    expect(result.evidence).toContain("history override: this signature is active on main");
    expect(result.evidence).toContain(
      "history matched runs: https://github.com/acme/app/actions/runs/1",
    );
  });

  test("preserves v1 likely blocker behavior", () => {
    const result = classify(baseAgent, meta());

    expect(result.classification).toBe("likely_blocker");
    expect(result.confidence).toBe("medium");
    expect(result.history_influenced).toBe(false);
  });

  test("preserves v1 likely flaky behavior", () => {
    const result = classify(
      {
        ...baseAgent,
        verdict: "flaky",
        relatedness_score: 0.2,
      },
      meta(),
    );

    expect(result.classification).toBe("likely_flaky");
    expect(result.confidence).toBe("medium");
  });

  test("preserves v1 disagreement investigate behavior", () => {
    const result = classify(
      {
        ...baseAgent,
        verdict: "flaky",
        relatedness_score: 0.7,
      },
      meta(),
    );

    expect(result.classification).toBe("investigate");
    expect(result.confidence).toBe("low");
    expect(result.evidence.some((e) => e.includes("classified as investigate"))).toBe(true);
  });

  test("always includes history evidence", () => {
    const result = classify(baseAgent, meta({
      main_matches: 1,
      main_sampled: 3,
      pr_matches: 2,
      pr_sampled: 3,
      sample_run_urls: [],
    }));

    expect(result.history).toEqual({
      main_matches: 1,
      main_sampled: 3,
      pr_matches: 2,
      pr_sampled: 3,
      sample_run_urls: [],
    });
    expect(result.evidence).toContain(
      "history: signature matched in 1/3 main failures, 2/3 recent PR failures",
    );
  });
});
