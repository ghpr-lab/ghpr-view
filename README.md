# PR Dashboard

A lightweight macOS menu bar app for tracking your GitHub pull requests and review requests.

![macOS](https://img.shields.io/badge/macOS-13.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.0-orange)

![Screenshot](assets/screenshot.png)

## Installation

### Homebrew (Recommended)

```bash
brew install xiaocang/tap/prdashboard
```

### Manual Download

1. Download the latest release from [Releases](https://github.com/xiaocang/ghpr-view/releases)
2. Extract the ZIP file
3. Move `PRDashboard.app` to your Applications folder
4. Open the app (you may need to right-click → Open the first time)


## Features

- **Menu Bar App** - Lives in your menu bar, no dock icon clutter
- **PR Overview** - View authored PRs, review requests, mentioned PRs, and direct mentions in one place
- **Merged Today** - Dedicated section showing PRs merged in the last 24 hours
- **Search & Summary** - Filter with free text or `jira:`, `ci:`, `pr:conflict`, and `approval:` queries
- **PR Actions** - Pin PRs, manage comment read state, rerun failed CI, and update out-of-date branches
- **CI Status** - See CI check status (success/failure/pending) for each PR
- **CI Workflow Grouping** - CI checks grouped by workflow with running status indicators
- **Rerun Failed CI** - Rerun failed CI checks directly from the dashboard
- **Unresolved Comments** - Badge shows unresolved comment count for your authored PRs
- **Approval Count** - Badge shows approval count on PR rows
- **Review Status** - Shows your review status (approved, changes requested, etc.) on review-requested PRs
- **Jira Integration** - Enrich detected Jira tickets with titles, statuses, and labels
- **Notifications** - Desktop alerts for new unresolved comments, CI status changes, and important changes on pinned PRs
- **Rate Limit Display** - Shows GitHub API rate limit in footer
- **Local Integrations** - Query the running app over a read-only Unix socket with `ghpr` or the bundled MCP server
- **GitHub Browser Integration** - Official `ghpr for GitHub` userscript adds CI analysis, Skill actions, tags, and local detail views to GitHub PR and Actions pages
- **Extension Platform** - Versioned Skill, presentation, and browser-contribution contracts with scoped third-party userscript capabilities
- **Skill Workbench** - Create, migrate, validate, fixture-test, preview, package, and install ghpr Skills

## Usage

### Option 1: GitHub Device Flow (Recommended)

1. Click the menu bar icon to open the dashboard
2. Click "Sign in with GitHub"
3. Enter the displayed code at github.com/login/device
4. Once authorized, your PRs will load automatically

### Option 2: Personal Access Token (PAT)

1. Create a [Personal Access Token](https://github.com/settings/tokens) with `["repo", "read:user", "workflow"]` scope
2. Click the menu bar icon to open the dashboard
3. Click "Sign in with GitHub", then "Use Personal Access Token"
4. Paste your token and click "Sign In"

### Controls

- **Left-click** menu bar icon - Open PR dashboard
- **Right-click** menu bar icon - Show context menu (version info, quit)
- **Cmd+R** - Refresh PR list
- **Settings** (gear icon) - Configure the account, refresh behavior, filters, integrations, notifications, and updates

### Local CLI

Build the command-line tool:

```bash
make build-cli
```

`make build-cli` prints the built `ghpr` path. Add it to your `PATH` or run that binary directly. Run PRDashboard, then query its current in-memory snapshot:

```bash
ghpr status
ghpr ping
ghpr prs --section authored
ghpr prs --section direct-mentions
ghpr pr --repo owner/repo --number 123
ghpr prs --json
ghpr snapshot --json
```

The CLI connects to a read-only Unix socket at `/tmp/com.xiaocang.PRDashboard.<uid>.sock`. Use `GHPR_SOCKET_PATH` or `--socket PATH` to override the path.

Available `prs` sections are `authored`, `review`, `mentioned`, `direct-mentions`, `merged`, and `all`. For MCP integration, run `make install-mcp` and see [`mcp-ghpr/README.md`](mcp-ghpr/README.md).

### GitHub Browser Integration

1. Open **Settings → Browser Integration** and confirm that the loopback Browser Bridge is running.
2. Click **Install Userscript** and install `ghpr for GitHub` in Tampermonkey.
3. Open a GitHub PR or Actions run. The standalone `ghpr` card is expanded on the PR conversation and starts collapsed on Checks, Files, and workflow-run pages; opening it starts the one-time pairing flow.
4. Review the requested scopes in the native ghpr window. Read-only scopes are selected by default; running Skills, cancelling runs, writing local ghpr tags, and reading artifacts require explicit approval. Local ghpr tags are stored only by ghpr and never change GitHub labels.

The bridge listens only on `127.0.0.1` within discovery ports `48120...48129`. Browser clients use individual revocable bearer capabilities—never cookies—and cannot obtain the GitHub token, local workspace paths, agent credentials, raw repository access, or shell execution. Third-party userscripts register declarative UI contributions through the bridge; the official userscript remains the only GitHub-page UI host.

Bridge discovery reports the version of the official userscript currently served by the app. When that version is newer than the installed script, the GitHub card shows an **Update** notice that opens the local Tampermonkey install route.

Installed Skill packages can contribute actions, badges, and result cards through `browser/contributions.yaml`; no companion userscript is required. Contributions are isolated by client, page, and id, and missing GitHub DOM slots fall back to the `ghpr` card. Active runs show `Running` on GitHub Checks and Conversation surfaces; **View live log** opens a capability-scoped, CI-style execution log that refreshes every two seconds until the run finishes. The execution timeline is a bounded stream of ghpr-defined lifecycle events rather than raw package output. Completed runs retain the structured output and execution log. Browser run APIs redact artifact metadata unless that client was explicitly approved for `artifact:read`.

Use **Open Browser Test Page** to verify bridge isolation and contract support. **Open Skill Workbench** provides Create, Migrate, and Enhance flows with fixture and permission gates. The equivalent contract-driven CLI workflow is:

```bash
ghpr contract capabilities --json
ghpr contract export --version latest --json
ghpr contract examples

ghpr skill scaffold --id team.ci.policy-check --name "Team CI Policy Check"
ghpr skill validate ./team.ci.policy-check
ghpr skill test ./team.ci.policy-check
ghpr skill preview ./team.ci.policy-check
ghpr skill pack ./team.ci.policy-check
ghpr skill install ./team.ci.policy-check
```

The app can install the bundled `ghpr-skill-builder` into Claude Code, Codex, and OMP user-skill directories. The builder reads the contracts exported by the installed `ghpr` binary instead of carrying a stale copy. Workbench Enhance automatically discovers Skills in those three user scopes and adds presentation and GitHub surfaces to an app-managed copy; the source `SKILL.md` and pass-through result semantics remain unchanged.

Runnable managed Skills execute through a restricted Claude Code, Codex, or OMP CLI invocation in a private temporary run directory. `execution.isolation: strict` describes the ghpr invocation contract, not an OS sandbox: ghpr disables Agent-exposed tools, shell actions, repository checkout, and task-directed network tools; passes the package instructions, result schema, and sanitized snapshot; and builds the child environment from an explicit model-provider allowlist so ambient application and repository credential variables are not inherited. The trusted host CLI still retains its normal `HOME`, configuration/plugins, provider credentials, and provider network transport. Codex starts after its working directory is switched to the private run root (`-C`) inside a read-only sandbox. ghpr validates final structured output against the package schema before persisting it.

While an Agent CLI is running, ghpr persists a fixed, sanitized lifecycle log. Browser and native clients can observe the transition from runtime launch to Agent execution, first output, result validation, and completion without receiving raw Agent output or credentials.

The model and reasoning effort for each coding agent are selectable. Claude Code and Codex lists are read from the agents themselves — `claude --help` for Claude Code model aliases and effort levels, `codex debug models` for the Codex model catalog and its per-model reasoning levels. Both lists are fetched on first use, cached with the app state, and refreshable from Settings. OMP takes a free-form model name because it resolves fuzzy names such as `opus` or `openai/gpt-5.2` itself. When nothing is selected, each agent keeps its own default.

A GitHub PR page never submits the same Skill twice: while a run for that Skill is queued or running, its run control is greyed out, and a repeated click cannot start a second run. The local run page groups the lifecycle log into GitHub Actions-style steps, and every step expands to its detailed events.


### Settings

- **Refresh Interval** - How often to fetch updates (1min to 30min)
- **Refresh on Open** - Refresh immediately when opening the popover
- **Repositories** - Filter to specific repos, case-insensitive (e.g., `owner/repo` or `owner/` for all repos)
- **Show Drafts** - Include/exclude draft PRs
- **CI Status Exclude Filter** - Exclude status checks by keyword (e.g., "review")
- **Notifications** - Enable/disable desktop notifications for unresolved comments and CI status changes
- **Pause in Low Power Mode** - Pause background refresh when macOS Low Power Mode is active
- **Pause on Cellular/Hotspot** - Pause background refresh on expensive networks (iPhone hotspot, etc.)
- **Launch at Login** - Start PRDashboard automatically when you log in
- **Show Review Status** - Show/hide review status badges on review-requested PRs
- **Open PRs in cmux First** - Reuse a matching cmux PR tab before falling back to the default browser
- **Jira** - Configure Jira Cloud credentials, metadata refresh interval, and connection testing
- **Browser Integration** - Install the official userscript, inspect bridge and GitHub-page health, test the local connection, and revoke paired clients
- **Skill Builder** - Install the user-level builder for supported coding agents and open the local Workbench or current contracts
- **Coding Agent Runtime** - Pin the model and reasoning effort ghpr passes to Claude Code, Codex, and OMP, with CLI-sourced lists and a refresh action
- **Updates** - Enable automatic update checks or check manually
- **Developer Options** - Replay onboarding, clear caches, override the GraphQL endpoint, or configure an HTTP proxy

## Requirements

- macOS 13.0 or later
- GitHub account

## Building from Source

```bash
git clone https://github.com/xiaocang/ghpr-view.git
cd ghpr-view
./run.sh
make build-cli
make install-mcp  # optional; requires Node.js and npm
```

## License

Apache License 2.0 - See [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.
