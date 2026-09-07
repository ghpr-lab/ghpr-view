# mcp-ghpr

MCP server that talks **directly** to PRDashboard's local Unix socket
(`/tmp/com.xiaocang.PRDashboard.<uid>.sock`). No `ghpr` CLI binary required.

For normal reads it uses the snapshot PRDashboard already maintains, so it
inherits whatever data is in the app: auth, refresh interval, rate-limit
headroom, sections, etc. If `get_pr` cannot find a requested PR in that local
snapshot (or the app is not reachable), it automatically falls back to
`gh pr view` for that single PR.

It also exposes one write tool, `import_review`, so heterogeneous
command-line review workflows (skills, `AGENTS.md`-driven agents, other local
context) can persist a completed review into PRDashboard without going
through the browser userscript.

## Tools

| Tool              | Description                                                                 |
|-------------------|-----------------------------------------------------------------------------|
| `ping`            | Is PRDashboard running?                                                     |
| `status`          | App version, auth, refresh, summary counters, rate limit.                   |
| `summary`         | Just the numeric counters.                                                  |
| `list_prs`        | List PRs, optional `repository` substring + `section` + `limit`.            |
| `get_pr`          | Single PR by `repository` + `number`.                                       |
| `list_unresolved` | PRs with unresolved review comments. Optional `repository` filter.          |
| `list_ci_failing` | PRs with failing CI checks. Optional `repository` filter.                   |
| `snapshot`        | Raw snapshot JSON (escape hatch).                                           |
| `import_review`   | Store a completed code review locally as a `pr.review` run. Write tool.     |

`repository` is matched as a case-insensitive substring of `OWNER/NAME`, so
`"example-org"` and `"example-org/example-repo"` both work. `list_prs`
accepts `section` values `authored`, `review`, `mentioned`,
`direct-mentions`, `merged`, or `all`.

### `import_review`

Persists a completed review as a `pr.review` run with line-anchored findings
that show up in PRDashboard's UI and the other read tools, exactly like a
native Skill run would. **It never submits a GitHub review or comment** —
the write is entirely local (PRDashboard's `extension-platform.json` store).

Input (all fields required unless noted):

```json
{
  "repository": "example-org/example-repo",
  "number": 123,
  "base_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "head_sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "engine": "claude-code",
  "overview_markdown": "## Summary\nLooks good overall, one correctness issue.",
  "findings": [
    {
      "file": "src/worker.ts",
      "start_line": 18,
      "end_line": 18,
      "side": "right",
      "title": "Lost update",
      "summary": "The write drops concurrent changes.",
      "why": "Both tasks replace the same stale value.",
      "suggested_fix": "Perform the mutation atomically.",
      "quoted_code": "state = next",
      "severity": "error",
      "confidence": 0.95,
      "category": "concurrency"
    }
  ]
}
```

Constraints: `base_sha`/`head_sha` are 40-character hex SHAs; at most 50
findings per call; `end_line >= start_line`; `confidence` in `0...1`;
`title`/`category`/`engine` at most 200 characters; `summary` at most 2,000;
`overview_markdown` at most 100,000; `why`/`suggested_fix`/`background`/
`quoted_code` at most 20,000 each. Invalid input is rejected before anything
is written.

**Idempotent**: importing the exact same `(repository, number, review)`
payload again returns the same `run_id` with `already_imported: true` and
does not create a duplicate run or bump the store revision.

Output (`structuredContent`):

```json
{
  "run_id": "run_mcp_1a2b3c4d5e6f7a8b9c0d1e2f",
  "repository": "example-org/example-repo",
  "number": 123,
  "head_sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "finding_count": 1,
  "imported_at": "2026-01-01T00:00:00Z",
  "already_imported": false
}
```

## Prerequisites

PRDashboard should be running locally for snapshot-backed tools and for
`import_review`.

The `get_pr` fallback requires the GitHub CLI (`gh`) to be installed and
authenticated for the requested repository. Fallback results include
`source: "gh"` and do not include PRDashboard-only enrichment such as local pin
state, Jira metadata, or unresolved review-thread tracking.

The socket path defaults to `/tmp/com.xiaocang.PRDashboard.<uid>.sock` and can
be overridden via `GHPR_SOCKET_PATH`.

## Install / run

```bash
cd mcp-ghpr
npm install
npm run build
# now node dist/index.js is the MCP entrypoint
```

For development without a build step:

```bash
npm run dev
```

## Wire into Claude Code

```json
{
  "mcpServers": {
    "ghpr": {
      "command": "node",
      "args": ["/absolute/path/to/ghpr-view/mcp-ghpr/dist/index.js"]
    }
  }
}
```

Optionally set `GHPR_SOCKET_PATH` in `env` if you run PRDashboard against a
non-default socket.

## Protocol details (for reference)

Wire format (matches `PRDashboard/LocalAPI/LocalAPIModels.swift`):

- Connect to `AF_UNIX` stream socket at the path above.
- Send one JSON request followed by `\n`, then half-close (`shutdown(WR)` via
  `socket.end()`).
- Read response until EOF; it's a JSON object with `schemaVersion`, `ok`, and
  either `snapshot` / `pullRequest` / `reviewImport` / `error`.
- Schema version is `2`.

Supported commands: `ping`, `snapshot`, `pr` (requires `repository` +
`number`), `import_review` (requires `repository`, `number`, and `review`;
the only write command — all others are read-only).
