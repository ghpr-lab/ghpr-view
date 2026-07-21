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
- **PR Overview** - View your authored PRs and review requests in one place
- **Merged Today** - Dedicated section showing PRs merged in the last 24 hours
- **CI Status** - See CI check status (success/failure/pending) for each PR
- **CI Workflow Grouping** - CI checks grouped by workflow with running status indicators
- **Rerun Failed CI** - Rerun failed CI checks directly from the dashboard
- **Unresolved Comments** - Badge shows unresolved comment count for your authored PRs
- **Approval Count** - Badge shows approval count on PR rows
- **Review Status** - Shows your review status (approved, changes requested, etc.) on review-requested PRs
- **Notifications** - Desktop alerts for new unresolved comments and CI status changes
- **Rate Limit Display** - Shows GitHub API rate limit in footer
- **Local CLI** - Query the running app over a local Unix socket with `ghpr`

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
- **Settings** (gear icon) - Configure refresh interval, filters, notifications

### Local CLI

Build the command-line tool:

```bash
make build-cli
```

`make build-cli` prints the built `ghpr` path. Add it to your `PATH` or run that binary directly. Run PRDashboard, then query its current in-memory snapshot:

```bash
ghpr status
ghpr prs --section authored
ghpr prs --json
ghpr snapshot --json
```

The CLI connects to a read-only Unix socket at `/tmp/com.xiaocang.PRDashboard.<uid>.sock`. Use `GHPR_SOCKET_PATH` or `--socket PATH` to override the path.

### Settings

- **Refresh Interval** - How often to fetch updates (1min to 30min)
- **Refresh on Open** - Refresh immediately when opening the popover
- **Repositories** - Filter to specific repos, case-insensitive (e.g., `owner/repo` or `owner/` for all repos)
- **Show Drafts** - Include/exclude draft PRs
- **CI Status Exclude Filter** - Exclude status checks by keyword (e.g., "review")
- **Notifications** - Enable/disable desktop notifications for new unresolved comments
- **Pause in Low Power Mode** - Pause background refresh when macOS Low Power Mode is active
- **Pause on Cellular/Hotspot** - Pause background refresh on expensive networks (iPhone hotspot, etc.)
- **Launch at Login** - Start PRDashboard automatically when you log in
- **Show Review Status** - Show/hide review status badges on review-requested PRs

## Requirements

- macOS 13.0 or later
- GitHub account

## Building from Source

```bash
git clone https://github.com/xiaocang/ghpr-view.git
cd ghpr-view
./run.sh
make build-cli
```

## License

Apache License 2.0 - See [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.
