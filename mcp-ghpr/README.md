# mcp-ghpr

Read-only MCP server that talks **directly** to PRDashboard's local Unix socket
(`/tmp/com.xiaocang.PRDashboard.<uid>.sock`). No `ghpr` CLI binary required.

For normal reads it uses the snapshot PRDashboard already maintains, so it
inherits whatever data is in the app: auth, refresh interval, rate-limit
headroom, sections, etc. If `get_pr` cannot find a requested PR in that local
snapshot (or the app is not reachable), it automatically falls back to
`gh pr view` for that single PR.

## Tools

All read-only.

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

`repository` is matched as a case-insensitive substring of `OWNER/NAME`, so
`"example-org"` and `"example-org/example-repo"` both work.

## Prerequisites

PRDashboard should be running locally for snapshot-backed tools.

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
  either `snapshot` / `pullRequest` / `error`.
- Schema version is `1`.

Supported commands: `ping`, `snapshot`, `pr` (requires `repository` + `number`).
