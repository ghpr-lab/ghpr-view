import path from "node:path";
import { fileURLToPath } from "node:url";
import { test, expect } from "@playwright/test";

const browserRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const userscriptPath = path.join(browserRoot, "ghpr.user.js");

function pageContext(pathname) {
  return {
    type: pathname.includes("/actions/runs/") ? "workflow_run" : "pull_request",
    key: pathname.includes("/actions/runs/")
      ? "github:acme/widgets:run:1001"
      : "github:acme/widgets:pr:42",
    repository: "acme/widgets",
    pr_number: 42,
    workflow_run_id: pathname.includes("/actions/runs/") ? 1001 : null,
    head_sha: "b".repeat(40)
  };
}

function snapshot(pathname, overrides = {}) {
  return {
    page: pageContext(pathname),
    pull_request: {
      id: 42,
      repository: "acme/widgets",
      number: 42,
      title: "Make CI history comparison deterministic",
      ci_status: "FAILURE"
    },
    current_revision_subject: {
      type: "pull_request_revision",
      repository: "acme/widgets",
      pr_number: 42,
      base_sha: "a".repeat(40),
      head_sha: "b".repeat(40)
    },
    analyses: [],
    tags: [],
    runs: [],
    findings: [],
    skills: [],
    contributions: [],
    github_surface_v2: true,
    ...overrides
  };
}

function workflowRun(skillID, jobID, status, result) {
  return {
    id: `run-${skillID}-${jobID}`,
    skill_id: skillID,
    subject: {
      type: "workflow_job",
      workflow_run_id: 1001,
      workflow_job_id: jobID
    },
    status,
    started_at: "2026-08-24T00:00:00Z",
    completed_at: status === "completed" ? "2026-08-24T00:01:00Z" : null,
    result: result ? { payload: result } : null
  };
}

function reviewRun(findings) {
  return {
    id: "run-pr-review",
    skill_id: "pr.review",
    agent: "codex",
    status: "completed",
    started_at: "2026-08-24T00:00:00Z",
    completed_at: "2026-08-24T00:01:00Z",
    result: {
      code_review: {
        head_sha: "b".repeat(40),
        overview_markdown: `${findings.length} findings.`,
        findings
      }
    }
  };
}

function persistedReviewFindings(findings) {
  return findings.map((finding) => ({
    id: finding.id,
    subject_key: `github:diff-line:${finding.id}`,
    subject: {
      type: "diff_line",
      repository: "acme/widgets",
      pr_number: 42,
      base_sha: "a".repeat(40),
      head_sha: "b".repeat(40),
      blob_sha: "c".repeat(40),
      file_path: finding.file,
      side: finding.side === "deletion" ? "left" : "right",
      start_line: finding.start_line || finding.line,
      end_line: finding.end_line || finding.line,
      hunk_fingerprint: `hunk-${finding.id}`,
      quoted_code: finding.quoted_code || null
    },
    kind: "review_finding",
    severity: finding.severity,
    title: finding.title || finding.body,
    summary: finding.body,
    details: finding.details?.why || null,
    confidence: finding.confidence,
    lifecycle: "exact",
    created_at: "2026-08-24T00:01:00Z",
    fingerprint: `fingerprint-${finding.id}`
  }));
}

async function installApp(page, fixtureName, pathname, pageSnapshot) {
  const parsed = new URL(`https://github.com${pathname}`);
  await page.goto(`/${fixtureName}`);
  await page.addStyleTag({
    content: `
      :root {
        --fgColor-default: #1f2328;
        --fgColor-muted: #59636e;
        --bgColor-default: #ffffff;
        --bgColor-muted: #f6f8fa;
        --borderColor-default: #d1d9e0;
      }
      * { box-sizing: border-box; }
      body {
        background: var(--bgColor-default);
        color: var(--fgColor-default);
        font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        margin: 24px auto;
        max-width: 1080px;
        padding: 0 20px;
      }
      main, section, .file { min-width: 0; }
      #partial-discussion-sidebar { width: 296px; }
      [data-testid="check-run-row"], [data-testid="failure-summary"], .file-header {
        border: 1px solid var(--borderColor-default);
        padding: 10px 12px;
      }
      [data-testid="check-run-row"] {
        align-items: center;
        display: flex;
        gap: 14px;
      }
      [data-testid="check-run-row"] > :first-child { flex: 1; }
      .js-timeline-item {
        border-left: 2px solid var(--borderColor-default);
        margin-left: 16px;
        padding: 10px 0 10px 20px;
      }
      .file { border: 1px solid var(--borderColor-default); border-radius: 6px; overflow: hidden; }
      .diff-table { border-collapse: collapse; width: 100%; }
      .blob-num { background: var(--bgColor-muted); color: var(--fgColor-muted); width: 42px; }
      .blob-code { font: 12px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace; padding: 2px 8px; }
      .blob-code-addition { background: #dafbe1; }
      .blob-code-deletion { background: #ffebe9; }
      @media (prefers-color-scheme: dark) {
        :root {
          --fgColor-default: #f0f6fc;
          --fgColor-muted: #8b949e;
          --bgColor-default: #0d1117;
          --bgColor-muted: #161b22;
          --borderColor-default: #30363d;
        }
        .blob-code-addition { background: #12261e; }
        .blob-code-deletion { background: #2d1618; }
      }
    `
  });
  await page.evaluate(() => {
    window.__GHPR_TEST__ = true;
  });
  await page.addScriptTag({ path: userscriptPath });
  await page.evaluate(async ({ pathname: pathValue, search, snapshotValue }) => {
    class FixtureGM {
      constructor() {
        this.storage = new Map([
          ["ghpr.bridge.port", 48120],
          ["ghpr.bridge.instance", "ghpr-playwright"],
          ["ghpr.bridge.token", "cap-playwright"]
        ]);
        this.requests = [];
      }

      async getValue(key, fallback) {
        return this.storage.has(key) ? this.storage.get(key) : fallback;
      }

      async setValue(key, value) {
        this.storage.set(key, value);
      }

      openInTab() {}

      registerMenuCommand() {}

      async request(options) {
        this.requests.push(options);
        const requestPath = new URL(options.url).pathname;
        let value;
        if (requestPath === "/.well-known/ghpr-browser-bridge") {
          value = {
            protocol: "ghpr.browser-bridge/v1",
            instance_id: "ghpr-playwright",
            app_version: "1.0.0",
            official_userscript_version: window.GhprUserscript.CLIENT.version,
            api_versions: [1],
            pairing_required: true,
            github_surface_v2: true
          };
        } else if (requestPath === "/api/v1/client") {
          value = {
            id: window.GhprUserscript.CLIENT.id,
            name: "GitHub Native Surfaces",
            version: window.GhprUserscript.CLIENT.version,
            scopes: window.GhprUserscript.CLIENT.requested_scopes,
            created_at: "2026-08-24T00:00:00Z",
            last_seen_at: "2026-08-24T00:00:00Z",
            revoked_at: null
          };
        } else if (requestPath === "/api/v1/page") {
          value = snapshotValue;
        } else if (requestPath === "/api/v1/subjects/resolve") {
          value = snapshotValue.current_revision_subject;
        } else {
          value = { ok: true };
        }
        return { status: 200, responseText: JSON.stringify(value) };
      }
    }

    const fixtureLocation = {
      pathname: pathValue,
      search,
      href: `https://github.com${pathValue}${search}`
    };
    const fixtureHistory = {
      replaceState(_state, _title, href) {
        const updated = new URL(href, fixtureLocation.href);
        fixtureLocation.pathname = updated.pathname;
        fixtureLocation.search = updated.search;
        fixtureLocation.href = updated.href;
      }
    };
    const fixtureWindow = new Proxy(window, {
      get(target, property) {
        if (property === "location") return fixtureLocation;
        if (property === "history") return fixtureHistory;
        const value = target[property];
        if (
          typeof value === "function" &&
          ["setTimeout", "clearTimeout", "addEventListener", "removeEventListener", "confirm"].includes(property)
        ) {
          return value.bind(target);
        }
        return value;
      }
    });
    window.__ghprFixtureLocation = fixtureLocation;
    window.__ghprFixtureGM = new FixtureGM();
    window.__ghprFixtureApp = window.GhprUserscript.createGhprApp({
      window: fixtureWindow,
      document,
      gm: window.__ghprFixtureGM
    });
    await window.__ghprFixtureApp.start();
  }, {
    pathname: parsed.pathname,
    search: parsed.search,
    snapshotValue: pageSnapshot
  });
}


test("Completed latest review asks before running again", async ({ page }) => {
  const pathname = "/acme/widgets/pull/42";
  await installApp(page, "conversation.html", pathname, snapshot(pathname, {
    runs: [reviewRun([])]
  }));

  const reviewButton = page.getByRole("button", { name: "Review latest" }).first();
  await expect(reviewButton).toBeVisible();

  await reviewButton.click();
  const dialog = page.locator("[data-ghpr-surface='github.pr.review-launch-dialog']");
  await expect(dialog).toBeVisible();
  const startReview = dialog.locator("[data-action-id='start-review']");

  const dismissDialogPromise = page.waitForEvent("dialog");
  const dismissClickPromise = startReview.click();
  const dismissDialog = await dismissDialogPromise;
  expect(dismissDialog.message()).toBe(
    "Revision bbbbbbb has already been reviewed. Review it again?"
  );
  await dismissDialog.dismiss();
  await dismissClickPromise;
  await expect(startReview).toBeEnabled();
  expect(await page.evaluate(() =>
    window.__ghprFixtureGM.requests.filter((request) =>
      new URL(request.url).pathname === "/api/v1/actions"
    ).length
  )).toBe(0);

  const acceptDialogPromise = page.waitForEvent("dialog");
  const acceptClickPromise = startReview.click();
  const acceptDialog = await acceptDialogPromise;
  await acceptDialog.accept();
  await acceptClickPromise;
  await expect.poll(() => page.evaluate(() =>
    window.__ghprFixtureGM.requests.filter((request) =>
      new URL(request.url).pathname === "/api/v1/actions"
    ).length
  )).toBe(1);
});


test("Active review keeps a collapsed, scrollable execution terminal in the page", async ({ page }) => {
  const pathname = "/acme/widgets/pull/42";
  await installApp(page, "conversation.html", pathname, snapshot(pathname, {
    pull_request: {
      id: 42,
      repository: "acme/widgets",
      number: 42,
      title: "Make CI history comparison deterministic",
      ci_status: "SUCCESS"
    },
    runs: [{
      id: "run-pr-review-active",
      skill_id: "pr.review",
      agent: "omp",
      status: "running",
      started_at: "2026-08-24T00:00:00Z",
      progress_message: "Receiving Agent output",
      log_entries: [
        {
          timestamp: "2026-08-24T00:00:00Z",
          kind: "running",
          message: "Skill: Review PR (pr.review)",
          stream: "skill_input"
        },
        {
          timestamp: "2026-08-24T00:00:01Z",
          kind: "running",
          message: "Target: pull_request_revision · acme/widgets#42 @ bbbbbbb",
          stream: "skill_input"
        },
        {
          timestamp: "2026-08-24T00:00:02Z",
          kind: "running",
          message: "Diff: 4 files · 186 lines · 8240 bytes",
          stream: "skill_input"
        },
        {
          timestamp: "2026-08-24T00:00:03Z",
          kind: "running",
          message: "File: src/cache/manager.ts",
          stream: "skill_input"
        },
        {
          timestamp: "2026-08-24T00:00:04Z",
          kind: "running",
          message: "Inspecting concurrent cache writes",
          stream: "agent_output"
        },
        {
          timestamp: "2026-08-24T00:00:05Z",
          kind: "running",
          message: "Finding: possible lost update at src/cache/manager.ts:87",
          stream: "agent_output"
        }
      ],
      result: null
    }]
  }));

  const card = page.locator("#ghpr-operation-card");
  await expect(card).toContainText("Coding agent · OMP");
  const progress = card.locator(".ghpr-operation-progress");
  const steps = progress.locator(".ghpr-operation-progress-step");
  const inputLog = steps.nth(0).locator(".ghpr-operation-progress-log");
  const outputLog = steps.nth(1).locator(".ghpr-operation-progress-log");
  await expect(progress).not.toHaveAttribute("open", "");
  await expect(inputLog).not.toBeVisible();
  await expect(outputLog).not.toBeVisible();
  await expect(progress.locator(".ghpr-operation-progress-line code")).toHaveText([
    "Skill: Review PR (pr.review)",
    "Target: pull_request_revision · acme/widgets#42 @ bbbbbbb",
    "Diff: 4 files · 186 lines · 8240 bytes",
    "File: src/cache/manager.ts",
    "Inspecting concurrent cache writes",
    "Finding: possible lost update at src/cache/manager.ts:87"
  ]);
  const terminalStyle = await outputLog.evaluate((element) => {
    const style = getComputedStyle(element);
    return { maxHeight: style.maxHeight, overflowY: style.overflowY };
  });
  expect(terminalStyle).toEqual({ maxHeight: "220px", overflowY: "auto" });

  await progress.locator(":scope > summary").click();
  await expect(progress).toHaveAttribute("open", "");
  await expect(outputLog).toBeVisible();
  await expect(inputLog).not.toBeVisible();
  await steps.nth(0).locator("summary").click();
  await expect(inputLog).toBeVisible();
  await steps.nth(0).locator("summary").click();
  await expect(card).toHaveScreenshot("active-review-terminal.png", {
    animations: "disabled"
  });
  await page.evaluate(() => window.__ghprFixtureApp.render());
  await expect(page.locator(".ghpr-operation-progress")).toHaveAttribute("open", "");
});


test("Checks keeps independent verdicts and expands one inline CI Insight", async ({ page }) => {
  const pathname = "/acme/widgets/pull/42/checks";
  const runs = [
    workflowRun("ci.failure.explain", 2001, "completed", {
      why_it_failed: "A timeout occurred while waiting for the database to become ready.",
      relevant_evidence: ["Readiness probe timed out after 60 seconds."],
      suggested_action: "Re-run the job to confirm."
    }),
    workflowRun("ci.failure.classify_flaky", 2001, "completed", {
      verdict: "likely_flaky",
      confidence: 0.87,
      flaky_evidence: ["Three similar failures passed on re-run."],
      history: { failed_runs: 2, total_runs: 12, window_days: 30 },
      suggested_action: "Re-run the job to confirm."
    }),
    workflowRun("ci.failure.classify_flaky", 2002, "completed", {
      verdict: "likely_related",
      confidence: 0.91
    }),
    workflowRun("ci.failure.classify_flaky", 2004, "running", null)
  ];
  await installApp(page, "checks.html", pathname, snapshot(pathname, { runs }));

  const rows = page.getByTestId("check-run-row");
  await expect(rows.filter({ hasText: "unit-test" })).toContainText("Likely flaky · 87%");
  await expect(rows.filter({ hasText: "lint" })).toContainText("Likely related · 91%");
  await expect(rows.filter({ hasText: "build" }).locator("[data-ghpr-surface]")).toHaveCount(0);
  await expect(rows.filter({ hasText: "e2e" })).toContainText("Investigating…");
  await expect(
    page.locator("[data-ghpr-surface='github.pr.checks.summary']")
  ).toContainText("A timeout occurred while waiting for the database");
  await expect(rows.filter({ hasText: "unit-test" })).toContainText(
    "A timeout occurred while waiting for the database to become ready."
  );
  await expect(page.locator("#checks_tab")).toHaveScreenshot("checks-row-verdict-light.png", {
    animations: "disabled"
  });
  await page.emulateMedia({ colorScheme: "dark" });
  await expect(page.locator("#checks_tab")).toHaveScreenshot("checks-row-verdict-dark.png", {
    animations: "disabled"
  });
  await page.emulateMedia({ colorScheme: "light" });

  await rows.filter({ hasText: "unit-test" }).getByRole("button", { name: "Explain" }).click();
  const insight = page.locator("[data-ghpr-surface='github.pr.checks.job.insight']");
  await expect(insight).toHaveCount(1);
  await expect(insight).toContainText("A timeout occurred while waiting for the database");
  await expect(insight).toContainText("Failed 2/12 runs (17%) in the last 30 days.");
  const rerunFailedJobs = insight.getByRole("button", { name: "Re-run failed jobs" });
  await expect(rerunFailedJobs).toBeVisible();
  await expect(insight).toHaveScreenshot("checks-inline-insight.png", {
    animations: "disabled"
  });
  await rerunFailedJobs.click();
  const rerunDialog = page.getByRole("dialog", { name: "Re-run failed jobs" });
  await expect(rerunDialog.getByRole("button", { name: "Explain CI Failure" })).toBeVisible();
  await expect(rerunDialog.getByRole("button", { name: "Re-run anyway" })).toBeVisible();
  await rerunDialog.getByRole("button", { name: "Re-run anyway" }).click();
  await expect.poll(() => page.evaluate(() =>
    window.__ghprFixtureGM.requests
      .filter((request) => new URL(request.url).pathname === "/api/v1/actions")
      .map((request) => JSON.parse(request.data))
      .some((body) => body.action?.kind === "rerun_failed_jobs")
  )).toBe(true);
});

test("Failed checks opens the first failed row and navigates only between failures", async ({ page }) => {
  const pathname = "/acme/widgets/pull/42/checks?ghpr_check=first";
  await installApp(page, "checks.html", pathname, snapshot(pathname));

  const rows = page.getByTestId("check-run-row");
  const unitTest = rows.filter({ hasText: "unit-test" });
  const lint = rows.filter({ hasText: "lint" });
  const e2e = rows.filter({ hasText: "e2e" });
  let insight = page.locator("[data-ghpr-surface='github.pr.checks.job.insight']");
  await expect(insight.locator(".ghpr-item-navigator-count")).toHaveText("1 of 3 failed checks");
  expect(await unitTest.evaluate((row) => row.nextElementSibling?.matches("[data-ghpr-surface='github.pr.checks.job.insight']"))).toBe(true);
  await expect(insight.getByRole("button", { name: "Previous" })).toBeDisabled();

  await insight.getByRole("button", { name: "Next" }).click();
  insight = page.locator("[data-ghpr-surface='github.pr.checks.job.insight']");
  await expect(insight.locator(".ghpr-item-navigator-count")).toHaveText("2 of 3 failed checks");
  expect(await lint.evaluate((row) => row.nextElementSibling?.matches("[data-ghpr-surface='github.pr.checks.job.insight']"))).toBe(true);

  await insight.getByRole("button", { name: "Next" }).click();
  insight = page.locator("[data-ghpr-surface='github.pr.checks.job.insight']");
  await expect(insight.locator(".ghpr-item-navigator-count")).toHaveText("3 of 3 failed checks");
  expect(await e2e.evaluate((row) => row.nextElementSibling?.matches("[data-ghpr-surface='github.pr.checks.job.insight']"))).toBe(true);
  await expect(insight.getByRole("button", { name: "Next" })).toBeDisabled();
});

test("Review Summary card carries the failed-CI rerun instead of the operation card", async ({ page }) => {
  const pathname = "/acme/widgets/pull/42";
  const pageSnapshot = snapshot(pathname);
  pageSnapshot.pull_request = {
    ...pageSnapshot.pull_request,
    ci_status: "PENDING",
    check_failure_count: 1,
    check_pending_count: 2,
    ci_is_running: true
  };
  pageSnapshot.skills = [{
    id: "ci.failure.explain",
    display_name: "Explain CI Failure",
    agents: ["codex"],
    default_agent: "codex",
    is_runnable: true
  }];
  pageSnapshot.agent_runtime = [{
    agent: "codex",
    preference: { model: "gpt-5.6", reasoning_effort: "high" }
  }];
  pageSnapshot.agent_catalogs = [{
    agent: "codex",
    models: [{
      slug: "gpt-5.6",
      display_name: "GPT-5.6",
      default_effort: "high",
      reasoning_efforts: [{ effort: "high", detail: "Thorough" }]
    }],
    reasoning_efforts: [{ effort: "high", detail: "Thorough" }]
  }];
  pageSnapshot.runs = [{
    id: "run-explain-completed",
    skill_id: "ci.failure.explain",
    subject: { type: "legacy_page", page: pageSnapshot.page },
    status: "completed",
    completed_at: "2026-08-24T00:03:00Z",
    result: {
      payload: {
        why_it_failed: "The lint job rejected an unused import.",
        relevant_evidence: ["eslint exited with code 1"],
        _ghpr_job: {
          repository: "acme/widgets",
          workflow_run_id: "1001",
          workflow_job_id: "2002",
          workflow_name: "lint"
        }
      }
    }
  }];
  await installApp(page, "conversation.html", pathname, pageSnapshot);

  const operationCard = page.locator("#ghpr-operation-card");
  await expect(operationCard.getByRole("button", { name: "Failed checks (1)" })).toBeVisible();
  await expect(operationCard.getByRole("button", { name: "Explain CI Failure" })).toHaveCount(0);
  await expect(operationCard.getByRole("button", { name: /Re-run failed/ })).toHaveCount(0);

  const summary = page.locator("[data-ghpr-surface='github.pr.conversation.review-summary']");
  const checksRow = summary.locator(".ghpr-review-summary-checks");
  const rerun = checksRow.getByRole("button", { name: "Re-run 1 failed job" });
  const explain = checksRow.getByRole("button", { name: "Explain again" });
  await expect(checksRow).toContainText("1 failed check");
  await expect(rerun).toBeVisible();
  await expect(explain).toBeVisible();
  const failureResult = checksRow.locator(".ghpr-review-summary-checks-copy");
  await expect(failureResult).toHaveAttribute(
    "data-hint",
    "• lint: The lint job rejected an unused import.\n  • eslint exited with code 1"
  );
  await failureResult.hover();
  expect(await failureResult.evaluate((node) =>
    getComputedStyle(node, "::after").display
  )).toBe("block");
  expect(await summary.evaluate((node) => {
    const card = node.querySelector(".ghpr-review-summary") ?? node;
    return card.firstElementChild?.classList.contains("ghpr-review-summary-checks") &&
      card.firstElementChild.nextElementSibling
        ?.classList.contains("ghpr-review-summary-identity");
  })).toBe(true);
  await expect(summary).toHaveScreenshot("conversation-checks-rerun.png", {
    animations: "disabled"
  });
  await rerun.click();
  const rerunDialog = page.getByRole("dialog", { name: "Re-run failed jobs" });
  await expect(rerunDialog).toBeVisible();
  await expect(rerunDialog.getByRole("button", { name: "Explain CI Failure" })).toBeVisible();
  await expect(rerunDialog.getByRole("button", { name: "Re-run anyway" })).toBeVisible();
  await expect(rerunDialog).toHaveScreenshot("rerun-failed-jobs-dialog.png", {
    animations: "disabled"
  });
  await rerunDialog.getByRole("button", { name: "Explain CI Failure" }).click();
  const explainDialog = page.getByRole("dialog", { name: "Explain failed checks" });
  await expect(explainDialog).toBeVisible();
  await expect(explainDialog.getByLabel("Review runtime")).toHaveValue("codex");
  await expect(explainDialog.getByLabel("Review model")).toHaveValue("gpt-5.6");
  await expect(explainDialog.getByLabel("Reasoning effort")).toHaveValue("high");
  await expect(explainDialog.getByRole("button", { name: "Copy import prompt" })).toHaveCount(0);
  await expect(explainDialog).toHaveScreenshot("explain-failure-launch-dialog.png", {
    animations: "disabled"
  });
  await explainDialog.getByRole("button", { name: "Explain failure" }).click();
  await expect.poll(() => page.evaluate(() =>
    window.__ghprFixtureGM.requests
      .filter((request) => new URL(request.url).pathname === "/api/v1/actions")
      .map((request) => JSON.parse(request.data).action)
      .find((action) => action.skill_id === "ci.failure.explain")
  )).toMatchObject({
    agent: "codex",
    model: "gpt-5.6",
    reasoning_effort: "high"
  });

  await rerun.click();
  const rerunAnywayDialog = page.getByRole("dialog", { name: "Re-run failed jobs" });
  await expect(rerunAnywayDialog).toBeVisible();
  await rerunAnywayDialog.getByRole("button", { name: "Re-run anyway" }).click();
  await expect.poll(() => page.evaluate(() =>
    window.__ghprFixtureGM.requests
      .filter((request) => new URL(request.url).pathname === "/api/v1/actions")
      .map((request) => JSON.parse(request.data))
      .some((body) => body.action?.kind === "rerun_failed_jobs")
  )).toBe(true);
});

test("Review Summary opens runtime confirmation and starts the selected model", async ({ page }) => {
  const pathname = "/acme/widgets/pull/42";
  await installApp(page, "conversation.html", pathname, snapshot(pathname, {
    skills: [{
      id: "pr.review",
      display_name: "Review PR",
      agents: ["omp", "claude_code", "codex"],
      default_agent: "omp",
      is_runnable: true
    }],
    agent_runtime: [{
      agent: "codex",
      preference: { model: "gpt-5.6", reasoning_effort: "high" }
    }],
    agent_catalogs: [{
      agent: "codex",
      models: [{
        slug: "gpt-5.6",
        display_name: "GPT-5.6",
        default_effort: "high",
        reasoning_efforts: [{ effort: "high", detail: "Thorough" }]
      }],
      reasoning_efforts: [{ effort: "high", detail: "Thorough" }]
    }]
  }));

  const summary = page.locator("[data-ghpr-surface='github.pr.conversation.review-summary']");
  await summary.getByRole("button", { name: "Review PR" }).click();
  const dialog = page.getByRole("dialog", { name: "Review pull request" });
  await expect(dialog).toBeVisible();
  await expect(dialog).toContainText("Run review with ghpr");
  await expect(dialog).toContainText("Import an existing review");
  await expect(dialog).toContainText("aaaaaaa");
  await expect(dialog).toContainText("bbbbbbb");

  await dialog.getByLabel("Review runtime").selectOption("codex");
  await expect(dialog.getByLabel("Review model")).toHaveValue("gpt-5.6");
  await expect(dialog.getByLabel("Reasoning effort")).toHaveValue("high");
  await expect(dialog).toHaveScreenshot("review-launch-dialog.png", {
    animations: "disabled"
  });
  await dialog.getByRole("button", { name: "Start review" }).click();

  await expect.poll(() => page.evaluate(() =>
    window.__ghprFixtureGM.requests
      .filter((request) => new URL(request.url).pathname === "/api/v1/actions")
      .map((request) => JSON.parse(request.data).action)
      .find((action) => action.skill_id === "pr.review")
  )).toMatchObject({
    agent: "codex",
    model: "gpt-5.6",
    reasoning_effort: "high"
  });
  await expect(dialog).toHaveCount(0);
});

test("Actions Job inserts the tabbed CI Insight immediately below the failure summary", async ({ page }) => {
  const pathname = "/acme/widgets/actions/runs/1001/job/2001";
  const runs = [
    workflowRun("ci.failure.explain", 2001, "completed", {
      why_it_failed: "Process completed with exit code 1.",
      relevant_evidence: ["lint failed on src/index.ts"],
      suggested_action: "Inspect the job logs."
    }),
    workflowRun("ci.failure.classify_flaky", 2001, "completed", {
      verdict: "likely_flaky",
      confidence: 0.87,
      flaky_evidence: ["The same failure passed on re-run."],
      history: { failed_runs: 2, total_runs: 12, window_days: 30 }
    })
  ];
  await installApp(page, "actions-job.html", pathname, snapshot(pathname, { runs }));

  const failureSummary = page.getByTestId("failure-summary");
  const insight = page.locator("[data-ghpr-surface='github.actions.job.after-failure-summary']");
  await expect(insight).toBeVisible();
  expect(await failureSummary.evaluate((node) => node.nextElementSibling?.getAttribute("data-ghpr-surface")))
    .toBe("github.actions.job.after-failure-summary");
  await expect(insight.getByRole("tab")).toHaveText([
    "Why it failed",
    "Flaky evidence",
    "History",
    "Suggested action"
  ]);
  await insight.getByRole("tab", { name: "Flaky evidence" }).click();
  await expect(insight).toContainText("Likely flaky · 87% confidence");
  await expect(page.getByTestId("logs-region")).toBeHidden();
  await insight.getByRole("button", { name: "View raw logs" }).click();
  await expect(page.getByTestId("logs-region")).toBeVisible();
  await expect(insight).toHaveScreenshot("actions-job-ci-insight.png", {
    animations: "disabled"
  });
});

test("Conversation finding navigates to and expands the exact Files changed line", async ({ page }) => {
  const findings = [
    {
      id: "finding-1",
      file: "src/index.ts",
      line: 10,
      side: "addition",
      severity: "warning",
      confidence: 0.92,
      body: "Possible lost update in cache write",
      quoted_code: "- return legacy();\n+ return next();",
      details: {
        why: "Concurrent requests can overwrite each other's updates.",
        suggestion: "Merge against the current value before writing."
      }
    },
    {
      id: "finding-2",
      file: "src/api.ts",
      line: 45,
      side: "addition",
      severity: "info",
      confidence: 0.70,
      body: "Null check can be simplified",
      quoted_code: "- if (result) {\n+ if (result != null) {"
    }
  ];
  const conversationPath = "/acme/widgets/pull/42";
  const reviewSnapshot = snapshot(conversationPath, {
    runs: [reviewRun(findings)],
    findings: persistedReviewFindings(findings),
    skills: [{
      id: "team.review.release-risk",
      version: "1.0.0",
      display_name: "Check release risk",
      summary: "Review release risk for this pull request.",
      targets: ["pull_request"],
      agents: ["codex"],
      default_agent: "codex",
      is_built_in: false,
      has_browser_companion: false,
      is_runnable: true
    }]
  });
  reviewSnapshot.pull_request = {
    ...reviewSnapshot.pull_request,
    ci_status: "PENDING",
    check_failure_count: 1,
    check_pending_count: 2,
    ci_is_running: true
  };
  await installApp(page, "conversation.html", conversationPath, reviewSnapshot);

  const summary = page.locator("[data-ghpr-surface='github.pr.conversation.review-summary']");
  await expect(summary).toBeVisible();
  await expect(summary).toContainText("2 findings · 2 files");
  await expect(summary).toContainText("ghpr-bot");
  await expect(summary.locator(".ghpr-diff-snippet")).toHaveCount(2);
  await expect(summary.getByRole("button", { name: /Dismiss|Open in editor/ })).toHaveCount(0);
  await expect(summary.getByRole("button", { name: "View diff context" })).toBeVisible();
  expect(await summary.evaluate((node) =>
    node.previousElementSibling?.matches("section[role='region'][aria-label='Checks']")
  )).toBe(true);
  await expect(summary).toHaveScreenshot("conversation-review-summary.png", {
    animations: "disabled"
  });

  const operationCard = page.locator("#ghpr-operation-card");
  await expect(operationCard).toBeVisible();
  await expect(operationCard).toContainText("Latest revision reviewed.");
  await expect(operationCard).toContainText("2 findings · 2 files");
  await expect(operationCard).toContainText("Coding agent · Codex");
  await expect(operationCard).toContainText("Checks failing");
  await expect(operationCard.getByRole("button", { name: "Review latest" })).toBeVisible();
  await expect(operationCard.getByRole("button", { name: "View findings" })).toBeVisible();
  await expect(operationCard.getByRole("button", { name: "Failed checks (1)" })).toBeVisible();
  await expect(operationCard.getByRole("button", { name: "Explain CI Failure" })).toHaveCount(0);
  await expect(operationCard.getByRole("button", { name: /Re-run failed/ })).toHaveCount(0);
  await expect(operationCard.getByRole("button", { name: "Open ghpr-view" })).toHaveCount(0);
  await expect(operationCard).toHaveScreenshot("conversation-operation-card.png", {
    animations: "disabled"
  });
  await expect(
    operationCard.locator("[data-action-id='run-skill-team.review.release-risk']")
  ).toHaveCount(1);
  await expect(page.locator("#ghpr-github-root")).toHaveCount(0);

  await expect(summary.getByRole("button", { name: "Explain CI Failure" })).toBeVisible();
  await expect(summary.getByRole("button", { name: "Re-run 1 failed job" })).toBeVisible();

  await operationCard.getByRole("button", { name: "View findings" }).click();
  await expect.poll(() => page.evaluate(() => window.__ghprFixtureLocation.href))
    .toBe("https://github.com/acme/widgets/pull/42/changes?ghpr_finding=finding-1&path=src%2Findex.ts&line=10#L10");
  await operationCard.getByRole("button", { name: "Failed checks (1)" }).click();
  await expect.poll(() => page.evaluate(() => window.__ghprFixtureLocation.href))
    .toBe("https://github.com/acme/widgets/pull/42/checks?ghpr_check=first");
  await summary.getByRole("button", { name: "View in Files changed" }).click();
  await expect.poll(() => page.evaluate(() => window.__ghprFixtureLocation.href))
    .toBe("https://github.com/acme/widgets/pull/42/changes?ghpr_finding=finding-1&path=src%2Findex.ts&line=10#L10");

  const filesFindings = [
    findings[0],
    {
      ...findings[1],
      file: "src/index.ts",
      line: 10
    }
  ];
  const filesPath = "/acme/widgets/pull/42/changes?ghpr_finding=finding-1";
  await installApp(page, "files-unified.html", filesPath, snapshot(filesPath, {
    runs: [reviewRun(filesFindings)],
    findings: persistedReviewFindings(filesFindings)
  }));
  const addition = page.locator(".blob-code-addition");
  const deletion = page.locator(".blob-code-deletion");
  const inlineCards = addition.locator(".ghpr-review-finding-preview[data-inline='true']");
  await expect(inlineCards).toHaveCount(2);
  await expect(inlineCards.first()).toContainText("Possible lost update in cache write");
  await expect(inlineCards.first()).toContainText("L10");
  await expect(inlineCards.first()).toContainText("bbbbbbb");
  await expect(deletion.locator("[data-ghpr-surface]")).toHaveCount(0);

  const inlineFinding = page.getByTestId("ghpr-inline-finding-panel");
  await expect(inlineFinding).toBeVisible();
  await expect(page.locator(".ghpr-surface-drawer")).toHaveCount(0);
  await expect(inlineFinding).toContainText("Possible lost update in cache write");
  await expect(inlineFinding.locator(".ghpr-diff-snippet-line[data-kind='removed']")).toHaveCount(1);
  await expect(inlineFinding.locator(".ghpr-diff-snippet-line[data-kind='added']")).toHaveCount(1);
  await expect(inlineFinding.locator(".ghpr-item-navigator-count")).toHaveText("1 of 2 findings");
  await inlineFinding.getByRole("button", { name: "Next" }).click();
  await expect(inlineFinding.locator(".ghpr-item-navigator-count")).toHaveText("2 of 2 findings");
  await expect(inlineFinding).toContainText("Null check can be simplified");
  await inlineFinding.getByRole("button", { name: "Previous" }).click();
  await expect(inlineFinding.locator(".ghpr-item-navigator-count")).toHaveText("1 of 2 findings");
  expect(await inlineFinding.evaluate((node) =>
    node.closest("tr")?.previousElementSibling?.querySelector(".blob-code-addition") !== null
  )).toBe(true);
  await expect(inlineFinding).toHaveScreenshot("files-inline-finding-unified.png", {
    animations: "disabled"
  });
  await expect(page.locator(".diff-table")).toHaveScreenshot("finding-navigation.png", {
    animations: "disabled"
  });
});

test("Review Summary copies one finding and the whole review to the system clipboard", async ({ page, context }) => {
  const findings = [
    {
      id: "finding-1",
      file: "src/index.ts",
      line: 10,
      side: "addition",
      severity: "warning",
      confidence: 0.92,
      body: "Possible lost update in cache write",
      quoted_code: "- return legacy();\n+ return next();",
      details: {
        why: "Concurrent requests can overwrite each other's updates.",
        suggestion: "Merge against the current value before writing."
      }
    },
    {
      id: "finding-2",
      file: "src/api.ts",
      line: 45,
      side: "addition",
      severity: "info",
      confidence: 0.70,
      body: "Null check can be simplified",
      quoted_code: "- if (result) {\n+ if (result != null) {"
    }
  ];
  const conversationPath = "/acme/widgets/pull/42";
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await installApp(page, "conversation.html", conversationPath, snapshot(conversationPath, {
    runs: [reviewRun(findings)],
    findings: persistedReviewFindings(findings)
  }));

  const summary = page.locator("[data-ghpr-surface='github.pr.conversation.review-summary']");
  const itemCopy = summary.locator("[data-action-id='copy-finding']");
  await expect(itemCopy).toHaveCount(2);

  await itemCopy.nth(1).click();
  await expect(itemCopy.nth(1)).toHaveText("Copied");
  const single = await page.evaluate(() => navigator.clipboard.readText());
  expect(single).toContain("[Info] Null check can be simplified");
  expect(single).toContain("src/api.ts · L45 · reviewed bbbbbbb");
  expect(single).not.toContain("Possible lost update in cache write");
  expect(await page.evaluate(() => window.__ghprFixtureLocation.href))
    .toBe("https://github.com/acme/widgets/pull/42");

  await summary.getByRole("button", { name: "Copy the review summary and every finding" }).click();
  const everything = await page.evaluate(() => navigator.clipboard.readText());
  expect(everything).toContain("ghpr Review Summary");
  expect(everything).toContain("2 findings · 2 files");
  expect(everything).toContain("1. [Warning] Possible lost update in cache write");
  expect(everything).toContain("2. [Info] Null check can be simplified");
});

test("GitHub React changes DOM anchors an inline finding to the exact side", async ({ page }) => {
  const finding = {
    id: "finding-react",
    file: "src/index.ts",
    line: 10,
    side: "addition",
    severity: "warning",
    confidence: 0.92,
    body: "Possible lost update in cache write",
    quoted_code: "- return legacy();\n+ return next();"
  };
  const pathname = "/acme/widgets/pull/42/changes?ghpr_finding=finding-react";
  await installApp(page, "files-changes-react.html", pathname, snapshot(pathname, {
    runs: [reviewRun([finding])],
    findings: persistedReviewFindings([finding])
  }));
  const fileTreeBadge = page.locator("#src\\/index\\.ts [data-ghpr-file-tree-badge]");
  await expect(fileTreeBadge).toHaveText("1");
  await expect(fileTreeBadge).toHaveAttribute(
    "aria-label",
    "Open first of 1 ghpr finding in src/index.ts"
  );
  await expect(page.locator("#src\\/index\\.ts [data-testid='native-comments-count']"))
    .toHaveText("3");
  await expect(page.locator("#src\\/other\\.ts [data-ghpr-file-tree-badge]"))
    .toHaveCount(0);
  await expect(fileTreeBadge).toHaveCSS("border-radius", "999px");
  await expect(fileTreeBadge).toHaveCSS("background-color", "rgb(111, 107, 175)");
  await expect(page.locator("[role='tree']")).toHaveScreenshot("file-tree-ghpr-badge.png", {
    animations: "disabled"
  });


  const targetRegion = page.locator("#diff-reactfixture");
  const addition = targetRegion.locator(
    "td[data-line-anchor][data-diff-side='right'][data-line-number='10']"
  );
  const deletion = targetRegion.locator(
    "td[data-line-anchor][data-diff-side='left'][data-line-number='10']"
  );
  const sameLineInOtherFile = page.locator(
    "#diff-reactother td[data-line-anchor][data-diff-side='right'][data-line-number='10']"
  );
  const inlineCard = addition.locator(".ghpr-review-finding-preview[data-inline='true']");
  await expect(inlineCard).toHaveCount(1);
  await expect(inlineCard).toContainText("Possible lost update in cache write");
  await expect(inlineCard).toContainText("L10 · bbbbbbb");
  await expect(deletion.locator("[data-ghpr-surface]")).toHaveCount(0);
  await expect(sameLineInOtherFile.locator("[data-ghpr-surface]")).toHaveCount(0);
  await expect(page.getByTestId("ghpr-inline-finding-panel")).toContainText(
    "Possible lost update in cache write"
  );
  await expect(page.locator("[data-ghpr-files-review-menu]")).toHaveCount(0);
});

test("Finding navigation changes files without opening the native comment composer", async ({ page }) => {
  const findings = [
    {
      id: "finding-index",
      file: "src/index.ts",
      line: 10,
      side: "addition",
      severity: "warning",
      confidence: 0.92,
      body: "Index finding"
    },
    {
      id: "finding-other",
      file: "src/other.ts",
      line: 10,
      side: "addition",
      severity: "warning",
      confidence: 0.88,
      body: "Other file finding"
    }
  ];
  const pathname = "/acme/widgets/pull/42/changes?ghpr_finding=finding-index";
  await installApp(page, "files-changes-react.html", pathname, snapshot(pathname, {
    runs: [reviewRun(findings)],
    findings: persistedReviewFindings(findings)
  }));
  await page.evaluate(() => {
    window.__nativeCommentClicks = 0;
    const button = document.createElement("button");
    button.setAttribute("aria-expanded", "false");
    button.setAttribute("aria-label", "Add comment on file");
    button.textContent = "Add comment";
    button.addEventListener("click", () => {
      window.__nativeCommentClicks += 1;
    });
    document.querySelector("#diff-reactother [data-diff-header-wrapper]").append(button);
  });

  let panel = page.getByTestId("ghpr-inline-finding-panel");
  await panel.getByRole("button", { name: "Next" }).click();
  await expect(panel).toContainText("Other file finding");
  expect(await page.evaluate(() => window.__nativeCommentClicks)).toBe(0);
  expect(await page.evaluate(() => window.__ghprFixtureLocation.search))
    .toBe("?ghpr_finding=finding-other");

  const firstFindingBadge = page.getByRole("button", {
    name: "Open first of 1 ghpr finding in src/index.ts"
  });
  await firstFindingBadge.click();
  panel = page.getByTestId("ghpr-inline-finding-panel");
  await expect(panel).toContainText("Index finding");
  expect(await page.evaluate(() => window.__ghprFixtureLocation.search))
    .toBe("?ghpr_finding=finding-index");
});

test("Files changed split view anchors the finding to the added side", async ({ page }) => {
  const finding = {
    id: "finding-split",
    file: "src/index.ts",
    line: 10,
    side: "addition",
    severity: "warning",
    confidence: 0.92,
    body: "Possible lost update in cache write",
    quoted_code: "- return legacy();\n+ return next();",
    details: {
      why: "Concurrent requests can overwrite each other's updates.",
      suggestion: "Merge against the current value before writing."
    }
  };
  const pathname = "/acme/widgets/pull/42/files?ghpr_finding=finding-split";
  await installApp(page, "files-split.html", pathname, snapshot(pathname, {
    runs: [reviewRun([finding])],
    findings: persistedReviewFindings([finding])
  }));

  const addition = page.locator(".blob-code-addition");
  const deletion = page.locator(".blob-code-deletion");
  await expect(addition.locator(".ghpr-review-finding-preview[data-inline='true']")).toHaveCount(1);
  await expect(deletion.locator("[data-ghpr-surface]")).toHaveCount(0);
  const inlineFinding = page.getByTestId("ghpr-inline-finding-panel");
  await expect(inlineFinding).toBeVisible();
  await expect(page.locator(".ghpr-surface-drawer")).toHaveCount(0);
  await expect(page.locator(".diff-table")).toHaveScreenshot("files-inline-finding-split.png", {
    animations: "disabled",
    maxDiffPixels: 20
  });
});

test("Files changed operation card defaults collapsed without moving Submit review", async ({ page }) => {
  const pathname = "/acme/widgets/pull/42/changes";
  await installApp(page, "files-changes-react.html", pathname, snapshot(pathname));

  const submitReview = page.getByRole("button", { name: /Submit review/ });
  const filesToolbar = page.locator("section[data-file-tree-expanded]");
  const operationCardHost = page.locator("#ghpr-operation-card");
  const operationCard = operationCardHost.locator(".ghpr-operation-card");
  const body = operationCard.locator(".ghpr-operation-card-body");
  const toggle = operationCard.getByRole("button", { name: "Expand ghpr card" });

  await expect(submitReview).toBeVisible();
  await expect(filesToolbar.locator(":scope > *")).toHaveCount(2);
  await expect(filesToolbar.locator("[data-ghpr-files-review-menu]")).toHaveCount(0);
  await expect(operationCard).toHaveAttribute("data-collapsed", "true");
  await expect(body).toBeHidden();
  await expect(toggle).toHaveAttribute("aria-expanded", "false");
  await expect(operationCard).toHaveScreenshot("files-operation-card-collapsed.png", {
    animations: "disabled"
  });
  expect(await operationCardHost.evaluate((node) => ({
    parent: node.parentElement?.tagName,
    position: getComputedStyle(node).position
  }))).toEqual({ parent: "BODY", position: "fixed" });

  const collapsedSubmitBox = await submitReview.boundingBox();
  await toggle.click();
  await expect(operationCard).toHaveAttribute("data-collapsed", "false");
  await expect(body).toBeVisible();
  await expect(operationCard.getByRole("button", { name: "Collapse ghpr card" }))
    .toHaveAttribute("aria-expanded", "true");
  expect(await submitReview.boundingBox()).toEqual(collapsedSubmitBox);
  await operationCard.getByRole("button", { name: "Collapse ghpr card" }).click();
  await expect(operationCard).toHaveAttribute("data-collapsed", "true");
  await expect(body).toBeHidden();
  expect(await submitReview.boundingBox()).toEqual(collapsedSubmitBox);
});

test("Reviewed revision diff anchors an outdated finding and flags the revision", async ({ page }) => {
  const finding = {
    id: "finding-outdated",
    file: "src/index.ts",
    line: 10,
    side: "addition",
    severity: "warning",
    confidence: 0.92,
    body: "Possible lost update in cache write",
    quoted_code: "- return legacy();\n+ return next();",
    details: {
      why: "Concurrent requests can overwrite each other's updates.",
      suggestion: "Merge against the current value before writing."
    }
  };
  const base = "a".repeat(40);
  const reviewed = "b".repeat(40);
  const pathname =
    `/acme/widgets/pull/42/files/${base}..${reviewed}?ghpr_finding=finding-outdated`;
  const outdatedFindings = persistedReviewFindings([finding])
    .map((persisted) => ({ ...persisted, lifecycle: "outdated" }));
  await installApp(page, "files-unified.html", pathname, snapshot(pathname, {
    current_revision_subject: {
      type: "pull_request_revision",
      repository: "acme/widgets",
      pr_number: 42,
      base_sha: base,
      head_sha: "d".repeat(40)
    },
    findings: outdatedFindings
  }));

  const inlineCard = page.locator(
    ".blob-code-addition .ghpr-review-finding-preview[data-inline='true']"
  );
  await expect(inlineCard).toHaveCount(1);
  await expect(inlineCard).toContainText("Reviewed revision");
  await expect(inlineCard).toContainText("L10 · bbbbbbb");
  await expect(page.locator(".ghpr-surface-drawer")).toHaveCount(0);
  await expect(page.getByTestId("ghpr-inline-finding-panel")).toBeVisible();

  const operationCard = page.locator("#ghpr-operation-card .ghpr-operation-card");
  await expect(operationCard).toHaveAttribute("data-collapsed", "true");
  await operationCard.getByRole("button", { name: "Expand ghpr card" }).click();
  await expect(operationCard).toContainText("Outdated revision");
  await expect(operationCard).toContainText("Findings from the reviewed revision bbbbbbb");
  await expect(operationCard.getByRole("button", { name: "Back to latest revision" }))
    .toBeVisible();
  await operationCard.getByRole("button", { name: "Collapse ghpr card" }).click();
  await expect(operationCard).toHaveAttribute("data-collapsed", "true");
  await expect(page.locator(".diff-table")).toHaveScreenshot("files-outdated-revision.png", {
    animations: "disabled"
  });
});

test("A finding without a diff row becomes a file-level band above the diff", async ({ page }) => {
  const finding = {
    id: "finding-file-level",
    file: "src/index.ts",
    line: 10,
    side: "addition",
    severity: "warning",
    confidence: 0.92,
    body: "Possible lost update in cache write",
    quoted_code: "- return legacy();\n+ return next();",
    details: {
      why: "Concurrent requests can overwrite each other's updates.",
      suggestion: "Merge against the current value before writing."
    }
  };
  const pathname = "/acme/widgets/pull/42/files";
  const outdatedFindings = persistedReviewFindings([finding])
    .map((persisted) => ({ ...persisted, lifecycle: "outdated" }));
  await installApp(page, "files-unified.html", pathname, snapshot(pathname, {
    current_revision_subject: {
      type: "pull_request_revision",
      repository: "acme/widgets",
      pr_number: 42,
      base_sha: "a".repeat(40),
      head_sha: "d".repeat(40)
    },
    findings: outdatedFindings
  }));

  const band = page.locator("[data-ghpr-surface='github.pr.files.file.header']");
  await expect(band).toHaveCount(1);
  await expect(band).toHaveAttribute("data-file-level", "true");
  await expect(band).toContainText("File-level");
  await expect(band).toContainText("Outdated");
  await expect(band).toContainText("src/index.ts · L10 · reviewed bbbbbbb");
  await expect(page.locator(".ghpr-finding-count-pill")).toHaveCount(0);
  await expect(page.locator("[data-ghpr-surface='github.pr.files.diff.line.after']"))
    .toHaveCount(0);
  await expect(page.locator(".file[data-path='src/index.ts']"))
    .toHaveScreenshot("files-file-level-finding.png", {
      animations: "disabled"
    });

  await band.click();
  const expanded = page.locator("[data-ghpr-surface='github.pr.files.file.header']");
  await expect(expanded).toHaveClass(/ghpr-review-finding/);
  await expect(expanded.getByRole("button", { name: "Collapse" })).toBeVisible();
  await expect(page.locator(".ghpr-surface-drawer")).toHaveCount(0);
});
