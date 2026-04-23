import { describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { FINAL_RESULT_FILENAME, writeFinalResult } from "./final-result.ts";
import type { FlakyCIAnalysisResultV2 } from "./protocol-v2.ts";

function sampleResult(): FlakyCIAnalysisResultV2 {
  return {
    schema_version: 2,
    protocol: "ghpr_flaky_ci_analysis",
    analysis_id: "ghpr-flaky-ci:v2:acme/app#7:abc123:123:req-1",
    request_id: "req-1",
    backend: {
      kind: "workflow_dispatch",
      version: "0.2.0",
    },
    status: "completed",
    classification: "likely_flaky",
    flaky_score: 92,
    relatedness_score: 0.91,
    confidence: "high",
    history_influenced: true,
    target: {
      ci_provider: "github_actions",
      run_id: 123,
      workflow_name: "CI",
      head_sha: "abc123",
    },
    failed_jobs: [{
      job_id: 456,
      job_name: "test",
      conclusion: "failure",
      failure_signature: "Error: timeout waiting for service",
      history: {
        main_matches: 2,
        main_sampled: 3,
        pr_matches: 1,
        pr_sampled: 3,
        sample_run_urls: ["https://github.com/acme/app/actions/runs/1"],
      },
    }],
    summary: {
      title: "Likely flaky",
      evidence_line: "Same signature is active on main",
      detail: "The same timeout is already active on main.",
    },
    evidence: [
      { kind: "history", message: "history override: this signature is active on main" },
    ],
    suggested_actions: [{ id: "rerun_failed_jobs", label: "Rerun failed jobs", enabled: true }],
    links: {
      workflow_run_url: "https://github.com/acme/app/actions/runs/123",
    },
    timestamps: {
      created_at: "2026-04-23T10:00:00.000Z",
      completed_at: "2026-04-23T10:01:00.000Z",
    },
  };
}

describe("writeFinalResult", () => {
  test("writes the complete classified FlakyResult artifact", () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "flaky-final-result-"));
    try {
      const result = sampleResult();
      writeFinalResult(dir, result);

      const raw = fs.readFileSync(path.join(dir, FINAL_RESULT_FILENAME), "utf8");
      expect(raw.endsWith("\n")).toBe(true);
      const parsed = JSON.parse(raw) as FlakyCIAnalysisResultV2;

      expect(parsed.schema_version).toBe(2);
      expect(parsed.protocol).toBe("ghpr_flaky_ci_analysis");
      expect(parsed.classification).toBe("likely_flaky");
      expect(parsed.failed_jobs[0]?.failure_signature).toBe("Error: timeout waiting for service");
      expect(parsed.failed_jobs[0]?.history.main_matches).toBe(2);
      expect(parsed.failed_jobs[0]?.history.pr_matches).toBe(1);
      expect(parsed.history_influenced).toBe(true);
      expect(parsed.evidence[0]?.message).toBe("history override: this signature is active on main");
      expect(parsed.suggested_actions[0]?.id).toBe("rerun_failed_jobs");
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
});
