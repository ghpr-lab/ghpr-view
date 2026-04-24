# flaky-analyzer

Composite GitHub Action that analyzes **one failed workflow run** for a PR and reports a flaky-vs-blocker verdict.

The analyzer:

1. Checks out the PR head into a sandboxed directory.
2. Fetches the failed jobs' logs via the GitHub Actions REST API.
3. Redacts known secret patterns, then stages filtered + raw logs and diff data under `pr-code/.tmp/flaky/`.
4. Extracts a deterministic failure signature for the primary failed job and samples recent failed runs for matching history.
5. Invokes **GitHub Copilot CLI** as a sandboxed agent (read-only tools, no shell execution) to read both the logs and the actual checked-out code, then emit a JSON verdict.
6. Writes the history-aware verdict to the Actions Job Summary, a Check Run on the head SHA, and (optionally) a PR comment.

This action is invoked by `.github/workflows/flaky-ci-review.yml`, which is dispatched via `workflow_dispatch` (e.g. by the ghpr-view macOS App, or manually by a maintainer).

## One-time setup per adopting repo

1. Create a **fine-grained personal access token** at <https://github.com/settings/personal-access-tokens/new>.
2. Grant it the **"Copilot Requests"** permission, scoped to this repository.
3. Save it as repo secret **`COPILOT_PAT`**.

The built-in `GITHUB_TOKEN` **cannot** authorize Copilot CLI; a PAT is required. `GITHUB_TOKEN` is still used (separately) for the Actions REST calls (list runs, fetch logs, write Check Run / PR comment).

## Permissions

Default minimal set (declared in the calling workflow):

```yaml
permissions:
  actions: read
  contents: read
  checks: write
```

If you set `write_pr_comment: true`, also grant:

```yaml
  pull-requests: write
  issues: write
```

## Inputs

| Input | Required | Default | Notes |
| ----- | -------- | ------- | ----- |
| `pr_number` | yes | — | PR number |
| `head_sha` | yes | — | Validated against real PR head; fail-fast on mismatch |
| `run_id` | yes | — | The failed workflow run id to analyze |
| `schema_version` | no | `"2"` | Protocol schema version for callers |
| `request_id` | no | correlation id / `run-<run_id>` | Caller correlation id echoed in v2 result and Check Run external id |
| `job_ids` | no | `""` | Optional comma-separated failed job ids to include; empty means all failed jobs |
| `trigger` | no | `"manual"` | Logical trigger label for context metadata |
| `pr_code_dir` | yes | — | Absolute path to the PR head checkout (workflow hands this in) |
| `correlation_id` | no | `""` | Opaque caller-supplied id, echoed in result |
| `write_pr_comment` | no | `"false"` | Opt-in PR comment upsert |
| `dry_run` | no | `"false"` | Produce `result_json` output but skip Check Run + PR comment |
| `github_token` | yes | — | `${{ secrets.GITHUB_TOKEN }}` — for Actions REST |
| `copilot_token` | yes | — | `${{ secrets.COPILOT_PAT }}` — for Copilot CLI |

## Outputs

| Output | Notes |
| ------ | ----- |
| `classification` | `likely_flaky` \| `likely_blocker` \| `investigate` |
| `verdict` | `flaky` \| `blocker` (raw agent output) |
| `result_json` | Final compatibility `FlakyResult` JSON single-line |

`result_json` includes additive v2 fields:

```json
{
  "failure_signature": "Error: normalized failure line",
  "history": {
    "main_matches": 0,
    "main_sampled": 0,
    "pr_matches": 0,
    "pr_sampled": 0,
    "sample_run_urls": []
  },
  "history_influenced": false
}
```

The classifier applies a conservative history override: if the primary failed
job's signature appears in at least two sampled recent `main` failures, the final
classification is `likely_flaky`, confidence is `high`, and
`history_influenced` is `true`.

## Agent sandboxing

The Copilot CLI invocation runs with:

- `--add-dir` scoped to the PR checkout (which contains the `.tmp/flaky/` IO dir). Nothing else is readable.
- An explicit tool allowlist: `read`, `write`, `shell(git:*, cat:*, grep:*, rg:*, find:*, wc:*, head:*, tail:*)`.
- An explicit deny for `bash`, `sh`, `make`, `npm`, `pnpm`, `yarn`, `bun`, `python`, `node`. Fork PR code cannot be executed.
- `--no-ask-user` — non-interactive.
- `--secret-env-vars=COPILOT_GITHUB_TOKEN` — redacts the token from captured output.
- 10-minute wall-clock cap.

On any agent failure (missing binary, timeout, malformed output, non-zero exit), the action falls back to a neutral **investigate** stub and still writes the Job Summary + Check Run. It never fails the workflow just because Copilot misbehaved.

## IO layout (under `pr-code/.tmp/flaky/`)

```
logs.txt            redacted filtered logs, 40 KB tail — primary input
logs.raw.txt        full redacted raw logs       — escalation
diff-files.txt      noise-filtered changed paths — primary input
diff-files.raw.txt  full list of changed paths   — escalation
diff.patch          full PR diff (unified patch) — escalation
context.json        PR/run/jobs metadata, primary job, failure signature
history.json        sampled main/recent-PR signature history
result.json         agent raw verdict output (primary agent contract)
final-result.json   final ghpr Flaky CI protocol v2 result, pretty JSON
transcript.md       copilot --share output       — audit
```

The calling workflow uploads this directory as an artifact named
`flaky-ci-review-<run_id>` with a 7-day retention period, even when analyzer
execution fails. Use `final-result.json` for offline debugging and ghpr-view
integration checks; `result.json` is intentionally the raw agent output before
the workflow classifier adds history, evidence, and suggested actions. The
legacy `result_json` action output remains the single-line v1-compatible
`FlakyResult` during migration.

## Protocol v2 Check Run

The workflow fallback writes one Check Run per failed run with name
`Flaky CI Analysis (run <run_id>)` and external id
`ghpr-flaky-ci:v2:<owner>/<repo>#<pr_number>:<head_sha>:<run_id>:<request_id>`.
The Check Run body begins with a hidden marker:

```markdown
<!-- ghpr-flaky-ci-result:v2:<base64url-json> -->
```

The marker payload is the same compact v2 JSON represented by
`final-result.json`. ghpr-view should discover Check Runs by this name/external
id contract and parse the marker as the canonical app-readable result. Logs and
agent transcript remain diagnostic artifact content, not protocol transport.

## Verification

For local changes, run:

```bash
./node_modules/.bin/tsc --noEmit
bun test
```

For live GitHub Actions verification, dispatch `.github/workflows/flaky-ci-review.yml`
with a failed PR workflow run and `dry_run=true` if you do not want Check Run or
PR comment writes. After the run completes, download the `flaky-ci-review-<run_id>`
artifact and confirm it contains `logs.txt`, `logs.raw.txt`, `context.json`,
`history.json`, `result.json`, `final-result.json`, and `transcript.md`.

Inspect `final-result.json` rather than `result.json` for `schema_version`,
`protocol`, `classification`, `failed_jobs[].failure_signature`,
`failed_jobs[].history`, `history_influenced`, and `evidence`. Also verify that
the Check Run output marker decodes to the same result and that `logs.txt`,
`logs.raw.txt`, and `final-result.json` do not contain token,
AWS key, bearer-token, basic-auth URL, ngrok URL, or uppercase secret assignment
plaintext.

## Redaction and signatures

Known token shapes are scrubbed before logs are written to disk, summarized, or
uploaded as artifacts. The redactor covers GitHub token prefixes, fine-grained
PATs, AWS access keys, bearer tokens, basic-auth URL credentials, ngrok URLs, and
uppercase `*_TOKEN` / `*_SECRET` / `*_KEY` assignments.

The primary failed job is the first failed job returned by the Actions jobs API.
Its filtered, redacted log is converted into a stable `failure_signature` by
selecting the first error-like line, normalizing volatile paths, timestamps,
UUIDs, hashes, IPs, and large numbers, and truncating to 200 characters.
