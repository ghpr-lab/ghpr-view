import * as core from "@actions/core";
import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import type { AgentOutput } from "./schema.ts";

export interface RunAgentOpts {
  actionPath: string;
  prCodeDir: string;
  ioDir: string;
  model: string;
  timeoutMs?: number;
}

const DEFAULT_TIMEOUT_MS = 10 * 60_000;

function renderPrompt(actionPath: string, prCodeDir: string): string {
  const promptPath = path.join(actionPath, "prompts", "agent.md");
  const template = fs.readFileSync(promptPath, "utf8");
  return template.replaceAll("{{PR_CODE_DIR}}", prCodeDir);
}

function buildArgv(opts: RunAgentOpts, prompt: string): string[] {
  return [
    "-p", prompt,
    "-s",
    "--no-ask-user",
    "--model", opts.model,
    "--add-dir", opts.prCodeDir,
    "--allow-tool", "read",
    "--allow-tool", "write",
    "--allow-tool", "shell(git:*,cat:*,grep:*,rg:*,find:*,wc:*,head:*,tail:*)",
    "--deny-tool", "shell(bash:*,sh:*,make:*,npm:*,pnpm:*,yarn:*,bun:*,python:*,node:*)",
    "--secret-env-vars", "COPILOT_GITHUB_TOKEN",
    "--share", path.join(opts.ioDir, "transcript.md"),
  ];
}

interface SpawnResult {
  code: number | null;
  signal: NodeJS.Signals | null;
  stdout: string;
  stderr: string;
  errorMessage?: string;
}

function spawnCopilot(argv: string[], cwd: string, timeoutMs: number): Promise<SpawnResult> {
  return new Promise((resolve) => {
    let stdout = "";
    let stderr = "";
    let settled = false;

    const proc = spawn("copilot", argv, {
      cwd,
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"],
    });

    const timer = setTimeout(() => {
      if (!settled) {
        core.warning(`Copilot CLI timed out after ${timeoutMs}ms; sending SIGTERM.`);
        proc.kill("SIGTERM");
      }
    }, timeoutMs);

    proc.stdout.on("data", (d: Buffer) => {
      stdout += d.toString("utf8");
    });
    proc.stderr.on("data", (d: Buffer) => {
      stderr += d.toString("utf8");
    });
    proc.on("error", (err) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ code: null, signal: null, stdout, stderr, errorMessage: err.message });
    });
    proc.on("close", (code, signal) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ code, signal, stdout, stderr });
    });
  });
}

function neutralStub(stderr: string, reason: string): AgentOutput {
  return {
    root_cause: "(agent unavailable)",
    error_summary: reason,
    verdict: "flaky",
    relatedness_score: 0.5,
    related_files: [],
    rationale: `Agent fallback: ${reason}`,
    confidence: "low",
    tools_used: [],
    // Preserve a short stderr hint in rationale if present
    ...(stderr
      ? { error_summary: `${reason} stderr: ${stderr.slice(-200).trim()}` }
      : {}),
  };
}

function parseResultJson(raw: string): AgentOutput | null {
  let obj: unknown;
  try {
    obj = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!obj || typeof obj !== "object") return null;
  const o = obj as Record<string, unknown>;
  const verdict = o.verdict;
  if (verdict !== "flaky" && verdict !== "blocker") return null;
  const score = typeof o.relatedness_score === "number" ? o.relatedness_score : null;
  if (score === null) return null;
  const confidence = o.confidence;
  if (confidence !== "low" && confidence !== "medium" && confidence !== "high") return null;
  return {
    root_cause: typeof o.root_cause === "string" ? o.root_cause : "",
    error_summary: typeof o.error_summary === "string" ? o.error_summary : "",
    verdict,
    relatedness_score: Math.max(0, Math.min(1, score)),
    related_files: Array.isArray(o.related_files) ? o.related_files.filter((x): x is string => typeof x === "string") : [],
    rationale: typeof o.rationale === "string" ? o.rationale : "",
    confidence,
    tools_used: Array.isArray(o.tools_used) ? o.tools_used.filter((x): x is string => typeof x === "string") : [],
  };
}

export async function runCopilotAgent(opts: RunAgentOpts): Promise<AgentOutput> {
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const resultPath = path.join(opts.ioDir, "result.json");
  const prompt = renderPrompt(opts.actionPath, opts.prCodeDir);
  const argv = buildArgv(opts, prompt);

  core.info(`Invoking Copilot CLI (model=${opts.model}, cwd=${opts.prCodeDir})`);
  const res = await spawnCopilot(argv, opts.prCodeDir, timeoutMs);

  if (res.errorMessage) {
    core.warning(`Copilot CLI spawn failed: ${res.errorMessage}. Using neutral stub.`);
    return neutralStub(res.stderr, `spawn error: ${res.errorMessage}`);
  }

  if (!fs.existsSync(resultPath)) {
    core.warning(`Agent did not produce result.json (exit=${res.code}, signal=${res.signal}). Using neutral stub.`);
    return neutralStub(res.stderr, `agent exited without result.json (exit=${res.code})`);
  }

  const raw = fs.readFileSync(resultPath, "utf8");
  const parsed = parseResultJson(raw);
  if (!parsed) {
    core.warning(`Agent produced malformed result.json. Using neutral stub.`);
    return neutralStub(res.stderr, "agent produced malformed JSON");
  }

  if (res.code !== 0) {
    core.warning(`Copilot CLI exit=${res.code} but result.json is valid — trusting the JSON.`);
  }
  return parsed;
}
