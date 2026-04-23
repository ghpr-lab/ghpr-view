export type Classification = "likely_flaky" | "likely_blocker" | "investigate";
export type Verdict = "flaky" | "blocker";
export type Confidence = "low" | "medium" | "high";

export interface FailedJob {
  job_id: number;
  job_name: string;
}

export interface HistorySummary {
  main_matches: number;
  main_sampled: number;
  pr_matches: number;
  pr_sampled: number;
  sample_run_urls: string[];
}

export interface AgentOutput {
  failure_signature: string;
  root_cause: string;
  error_summary: string;
  verdict: Verdict;
  relatedness_score: number;
  related_files: string[];
  rationale: string;
  confidence: Confidence;
  tools_used: string[];
}

export interface FlakyResult {
  schema_version: 1;
  classification: Classification;
  verdict: Verdict;
  relatedness_score: number;
  confidence: Confidence;
  failure_signature: string;
  history: HistorySummary;
  history_influenced: boolean;
  root_cause: string;
  error_summary: string;
  related_files: string[];
  evidence: string[];
  suggested_actions: string[];
  explanation: string;
  tools_used: string[];
  agent_model: string;
  ci_provider: "github_actions";
  backend: "workflow";
  run_id: number;
  failed_jobs: FailedJob[];
  correlation_id?: string;
}

export interface ClassifyMeta {
  run_id: number;
  failed_jobs: FailedJob[];
  agent_model: string;
  failure_signature: string;
  history: HistorySummary;
  correlation_id?: string;
}
