# Flaky CI Protocol v2

This protocol is shared by the GitHub App backend and the workflow fallback.
ghpr-view treats the Check Run marker as the canonical machine-readable result.

## Request

Logical request:

```json
{
  "schema_version": 2,
  "protocol": "ghpr_flaky_ci_analysis",
  "request_id": "uuid-or-client-correlation-id",
  "trigger": "manual",
  "repository": {
    "owner": "acme",
    "name": "web",
    "full_name": "acme/web"
  },
  "pull_request": {
    "number": 123,
    "head_sha": "abc123"
  },
  "target": {
    "ci_provider": "github_actions",
    "run_id": 987654321,
    "job_ids": [111, 222]
  },
  "requested_by": {
    "login": "alice"
  },
  "options": {
    "dry_run": false,
    "write_pr_comment": false
  }
}
```

Workflow transport maps this to primitive `workflow_dispatch` inputs:
`schema_version`, `request_id`, `pr_number`, `head_sha`, `run_id`, `job_ids`,
`trigger`, `dry_run`, and `write_pr_comment`. Owner and repo come from the
workflow repository context. Logs and diffs must not be passed through inputs.

## Result

One result describes one failed GitHub Actions workflow run. `failed_jobs`
contains all failed jobs known to the analyzer.

Canonical result shape:

```json
{
  "schema_version": 2,
  "protocol": "ghpr_flaky_ci_analysis",
  "analysis_id": "ghpr-flaky-ci:v2:acme/web#123:abc123:987654321:req-1",
  "request_id": "req-1",
  "backend": {
    "kind": "workflow_dispatch",
    "version": "0.2.0"
  },
  "status": "completed",
  "classification": "likely_flaky",
  "flaky_score": 92,
  "relatedness_score": 0.12,
  "confidence": "high",
  "history_influenced": true,
  "target": {
    "ci_provider": "github_actions",
    "run_id": 987654321,
    "workflow_name": "Swift",
    "head_sha": "abc123"
  },
  "failed_jobs": [
    {
      "job_id": 111,
      "job_name": "macos-latest / test",
      "conclusion": "failure",
      "failure_signature": "Timeout waiting for reconnect event",
      "history": {
        "main_matches": 2,
        "main_sampled": 3,
        "pr_matches": 1,
        "pr_sampled": 3,
        "sample_run_urls": ["https://github.com/acme/web/actions/runs/1"]
      }
    }
  ],
  "summary": {
    "title": "Likely flaky",
    "evidence_line": "Same signature is active on main",
    "detail": "The failure signature appeared in recent main runs."
  },
  "evidence": [
    {
      "kind": "history",
      "message": "Signature matched in 2/3 sampled main failures",
      "url": "https://github.com/acme/web/actions/runs/1"
    }
  ],
  "suggested_actions": [
    {
      "id": "rerun_failed_jobs",
      "label": "Rerun failed jobs",
      "enabled": true
    },
    {
      "id": "open_failed_run",
      "label": "Open failed workflow run",
      "enabled": true,
      "url": "https://github.com/acme/web/actions/runs/987654321"
    }
  ],
  "links": {
    "workflow_run_url": "https://github.com/acme/web/actions/runs/987654321"
  },
  "timestamps": {
    "created_at": "2026-04-23T10:00:00.000Z",
    "completed_at": "2026-04-23T10:02:00.000Z"
  }
}
```

Required stable enums:

- `classification`: `likely_flaky`, `likely_blocker`, or `investigate`
- `status`: `queued`, `in_progress`, `completed`, `stale`, or `error`
- `backend.kind`: `workflow_dispatch` or `github_app`
- `suggested_actions[].id`: `rerun_failed_jobs`, `open_failed_run`,
  `open_check_run`, `open_artifact`, `open_pr_comment`, `analyze_again`, or
  `investigate_manually`

Scores:

- `flaky_score`: integer `0...100`
- `relatedness_score`: number `0...1`

`analysis_id` should be stable for the input tuple and normally matches the
Check Run `external_id`. `failed_jobs[].history.sample_run_urls` contains matched
sample URLs only. Optional links may be absent when a backend cannot know them at
marker creation time.

## Check Run

Check Run name:

```text
Flaky CI Analysis (run <run_id>)
```

Check Run `external_id`:

```text
ghpr-flaky-ci:v2:<owner>/<repo>#<pr_number>:<head_sha>:<run_id>:<request_id>
```

Check Run `output.text` must start with a hidden marker:

```markdown
<!-- ghpr-flaky-ci-result:v2:<base64url-json> -->

## Flaky CI Analysis
Human-readable markdown follows.
```

The decoded marker JSON is the canonical app-readable result. Artifacts are for
diagnostics; PR comments are optional human-facing output and are not a source of
truth.

## App Decoding

ghpr-view discovers matching Check Runs by name prefix `Flaky CI Analysis (run `
or `external_id` prefix `ghpr-flaky-ci:v2:`. It fetches Check Run details, parses
the marker from `output.text`, validates `schema_version == 2` and
`protocol == "ghpr_flaky_ci_analysis"`, and marks a result stale when
`target.head_sha` differs from the PR's current head SHA.

Status mapping:

- `queued` and `in_progress` show an analyzing state.
- `completed + likely_flaky` shows a likely flaky badge.
- `completed + likely_blocker` shows a real issue badge.
- `completed + investigate` shows a needs investigation badge.
- `stale` or a head SHA mismatch shows an outdated state.
- Missing or invalid marker means no completed report is available, but the app
  may still offer to open the Check Run.

The app only binds known `suggested_actions[].id` values; labels are display
text and are not used as behavior keys.
