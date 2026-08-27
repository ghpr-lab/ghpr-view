import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { Window } from "happy-dom";

globalThis.__GHPR_TEST__ = true;
await import("../ghpr.user.js");

const {
  CLIENT,
  createGhprApp,
  isVersionNewer,
  isConversationSurface,
  parseGitHubPage,
  semanticTargets
} = globalThis.GhprUserscript;
const fixtureURL = new URL("./github-pr-fixture.html", import.meta.url);
const fixtureHTML = await readFile(fileURLToPath(fixtureURL), "utf8");
const userscriptSource = await readFile(
  new URL("../ghpr.user.js", import.meta.url),
  "utf8"
);

function jsonResponse(value, status = 200) {
  return {
    status,
    responseText: JSON.stringify(value)
  };
}

class FakeGM {
  constructor({
    online = true,
    paired = true,
    snapshot = makeSnapshot(),
    latestVersion = CLIENT.version,
    scopes = CLIENT.requested_scopes,
    pairingScopes = scopes
  } = {}) {
    this.online = online;
    this.snapshot = snapshot;
    this.latestVersion = latestVersion;
    this.scopes = [...scopes];
    this.pairingScopes = [...pairingScopes];
    this.storage = new Map(paired ? [
      ["ghpr.bridge.port", 48120],
      ["ghpr.bridge.instance", "ghpr-test"],
      ["ghpr.bridge.token", "cap_test"]
    ] : []);
    this.requests = [];
    this.opened = [];
    this.commands = new Map();
  }

  async getValue(key, fallback) {
    return this.storage.has(key) ? this.storage.get(key) : fallback;
  }

  async setValue(key, value) {
    this.storage.set(key, value);
  }

  openInTab(url) {
    this.opened.push(url);
  }

  registerMenuCommand(label, callback) {
    this.commands.set(label, callback);
  }

  async request(options) {
    this.requests.push(options);
    if (!this.online) throw new Error("offline");
    const url = new URL(options.url);
    if (url.pathname === "/.well-known/ghpr-browser-bridge") {
      return jsonResponse({
        protocol: "ghpr.browser-bridge/v1",
        instance_id: "ghpr-test",
        app_version: "1.0.0",
        official_userscript_version: this.latestVersion,
        api_versions: [1],
        pairing_required: true
      });
    }
    if (url.pathname === "/api/v1/pairings" && options.method === "POST") {
      return jsonResponse({
        request_id: "pair_permissions",
        pairing_secret: "pair_secret",
        pairing_url: "http://127.0.0.1:48120/ui/pair/pair_permissions?secret=pair_secret",
        expires_at: "2026-08-24T00:05:00Z"
      }, 201);
    }
    if (url.pathname === "/api/v1/pairings/pair_permissions") {
      this.scopes = [...this.pairingScopes];
      return jsonResponse({
        state: "approved",
        token: "cap_upgraded",
        client: {
          id: CLIENT.id,
          name: CLIENT.name,
          version: CLIENT.version,
          scopes: this.scopes,
          created_at: "2026-08-24T00:00:00Z",
          last_seen_at: "2026-08-24T00:00:00Z",
          revoked_at: null
        },
        error: null
      });
    }
    if (url.pathname === "/api/v1/client") {
      return jsonResponse({
        id: CLIENT.id,
        name: CLIENT.name,
        version: CLIENT.version,
        scopes: this.scopes,
        created_at: "2026-08-24T00:00:00Z",
        last_seen_at: "2026-08-24T00:00:00Z",
        revoked_at: null
      });
    }
    if (url.pathname === "/api/v1/page") return jsonResponse(this.snapshot);
    if (url.pathname === "/api/v1/actions") {
      const body = JSON.parse(options.data);
      const action = body.action;
      const detailURL = action.kind === "open_detail" && action.run_id
        ? `http://127.0.0.1:48120/ui/run/${action.run_id}?cap=detail_cap`
        : null;
      return jsonResponse({
        run: null,
        url: detailURL,
        tags: [],
        rerun_count: null,
        event: null
      });
    }
    if (url.pathname === "/api/v1/slot-health") return jsonResponse({ ok: true });
    if (url.pathname.includes("/contributions/") && url.pathname.endsWith("/invoke")) {
      return jsonResponse({ run: null, url: null, tags: null, rerun_count: null, event: null });
    }
    throw new Error(`Unhandled fake request: ${options.method} ${url.pathname}`);
  }
}

function makeSnapshot() {
  const page = {
    type: "pull_request",
    key: "github:example-org/example-repo:pr:1238",
    repository: "example-org/example-repo",
    pr_number: 1238,
    workflow_run_id: null
  };
  return {
    page,
    pull_request: {
      id: 1238,
      repository: "example-org/example-repo",
      number: 1238,
      title: "Make CI history comparison deterministic",
      ci_status: "FAILURE"
    },
    analyses: [{
      id: "analysis_1",
      page_key: page.key,
      repository: "example-org/example-repo",
      pr_number: 1238,
      job_name: "unit-test",
      verdict: "likely_flaky",
      confidence: "high",
      confidence_score: 0.92,
      summary: "The same signature appeared in three main-branch runs.",
      history_matches: [
        {
          id: "history_1",
          run_number: 71,
          branch: "main",
          date: "2026-08-23T00:00:00Z",
          similarity: 0.96,
          result: "failure"
        }
      ],
      history_checked: 20,
      relatedness_score: 0.12,
      relatedness_summary: "No changed file overlaps the failing package.",
      reproduction: "Not rerun",
      failure_signature: "unit-test:timeout",
      changed_files: ["README.md"],
      suggested_action: "Rerun failed jobs",
      agent: "codex",
      strict_context: true,
      duration_seconds: 34,
      created_at: "2026-08-24T00:00:00Z"
    }],
    tags: ["needs_investigation"],
    runs: [],
    skills: [
      {
        id: "ci.failure.classify_flaky",
        version: "1.0.0",
        display_name: "Classify Flaky",
        summary: "Classify a failed check.",
        targets: ["pull_request"],
        agents: ["codex"],
        default_agent: "codex",
        is_built_in: true,
        has_browser_companion: false,
        is_runnable: true
      }
    ],
    contributions: [{
      id: "team-policy",
      client_id: "com.example.team-ci-helper",
      page_key: page.key,
      slot: "files.toolbar.actions",
      component: {
        type: "action",
        label: "Run Team Policy Check",
        text: null,
        tone: "analysis",
        presentation_ref: null
      },
      action: {
        kind: "client_event",
        skill_id: null,
        run_id: null,
        analysis_id: null,
        tag: null,
        event: "team-policy-check:clicked"
      },
      created_at: "2026-08-24T00:00:00Z",
      expires_at: "2026-08-24T00:05:00Z"
    }]
  };
}

function createWindow(pathname = "/example-org/example-repo/pull/1238/checks") {
  const window = new Window({ url: `https://github.com${pathname}` });
  window.document.write(fixtureHTML);
  window.document.close();
  window.confirm = () => true;
  return window;
}

function setViewport(window, width, height) {
  Object.defineProperties(window, {
    innerWidth: { configurable: true, value: width },
    innerHeight: { configurable: true, value: height }
  });
  Object.defineProperties(window.document.documentElement, {
    clientWidth: { configurable: true, value: width },
    clientHeight: { configurable: true, value: height }
  });
}

function actionBody(request) {
  return JSON.parse(request.data);
}

async function settle() {
  await new Promise((resolve) => setTimeout(resolve, 0));
  await new Promise((resolve) => setTimeout(resolve, 0));
}

test("parses supported GitHub PR and workflow URLs", () => {
  assert.deepEqual(
    parseGitHubPage(new URL("https://github.com/Example-Org/example-repo/pull/1238/files")),
    {
      type: "pull_request",
      key: "github:example-org/example-repo:pr:1238",
      repository: "Example-Org/example-repo",
      pr_number: 1238,
      workflow_run_id: null
    }
  );
  assert.deepEqual(
    parseGitHubPage(new URL("https://github.com/example-org/example-repo/actions/runs/9988")),
    {
      type: "workflow_run",
      key: "github:example-org/example-repo:run:9988",
      repository: "example-org/example-repo",
      pr_number: null,
      workflow_run_id: 9988
    }
  );
  assert.equal(
    parseGitHubPage(new URL("https://github.com/example-org/example-repo/issues/7")),
    null
  );
});

test("compares server userscript versions without false update prompts", () => {
  assert.equal(isVersionNewer("1.2.0", "1.1.9"), true);
  assert.equal(isVersionNewer("1.1.1", "1.1.1"), false);
  assert.equal(isVersionNewer("1.1.0", "1.1.1"), false);
  assert.equal(isVersionNewer("not-a-version", "1.1.1"), false);
});
test("publishes the client and update metadata as userscript v1.2.0", () => {
  const metadataVersion = userscriptSource.match(/^\/\/ @version\s+(\S+)$/m)?.[1];
  assert.equal(metadataVersion, "1.2.0");
  assert.equal(CLIENT.version, metadataVersion);
  assert.equal(CLIENT.requested_scopes.includes("tag:read"), true);
  assert.equal(CLIENT.requested_scopes.includes("tag:write"), true);
});

test("disables the run control of a Skill that is already running", async () => {
  const snapshot = makeSnapshot();
  snapshot.runs = [{
    id: "run_active",
    skill_id: "ci.failure.classify_flaky",
    page: snapshot.page,
    requested_by_client_id: CLIENT.id,
    created_at: "2026-08-24T00:00:00Z",
    started_at: "2026-08-24T00:00:01Z",
    completed_at: null,
    status: "running",
    progress_message: "Executing Skill",
    progress_current: null,
    progress_total: null,
    log_entries: [],
    result: null,
    error: null,
    retry_of_run_id: null
  }];
  const window = createWindow();
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();

  const controls = [...window.document.querySelectorAll(".ghpr-panel-action")];
  const busy = controls.find((control) => control.textContent.startsWith("Classify Flaky"));
  const idle = controls.find((control) => control.textContent.startsWith("Explain CI Failure"));
  assert.equal(busy?.textContent, "Classify Flaky · Running");
  assert.equal(busy?.disabled, true);
  assert.equal(busy?.getAttribute("aria-disabled"), "true");
  assert.equal(idle?.textContent, "Explain CI Failure");
  assert.equal(idle?.disabled, false);

  busy.click();
  await settle();
  assert.equal(
    gm.requests.filter((request) => new URL(request.url).pathname === "/api/v1/actions").length,
    0
  );

  gm.commands.get("Analyze current PR")();
  await settle();
  assert.equal(
    gm.requests.filter((request) => new URL(request.url).pathname === "/api/v1/actions").length,
    0
  );
  assert.match(
    window.document.getElementById("ghpr-github-root").textContent,
    /ci\.failure\.classify_flaky is already running/
  );

  app.stop();
  window.close();
});

test("a repeated run click submits the Skill once", async () => {
  const window = createWindow();
  const gm = new FakeGM();
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();

  const control = [...window.document.querySelectorAll(".ghpr-panel-action")]
    .find((candidate) => candidate.textContent === "Classify Flaky");
  control.click();
  control.click();
  control.click();
  await settle();

  const submitted = gm.requests
    .filter((request) => new URL(request.url).pathname === "/api/v1/actions")
    .map(actionBody)
    .filter((body) => body.action.kind === "run_skill");
  assert.equal(submitted.length, 1);
  assert.equal(submitted[0].action.skill_id, "ci.failure.classify_flaky");
  assert.equal(control.disabled, true);

  app.stop();
  window.close();
});


test("prompts for a userscript update reported by the Browser Bridge", async () => {
  const window = createWindow();
  const gm = new FakeGM({ latestVersion: "1.3.0" });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();

  const card = window.document.getElementById("ghpr-github-root");
  assert.ok(card.classList.contains("ghpr-compact"));
  assert.equal(card.querySelector(".ghpr-badge")?.textContent, "Update");
  card.querySelector("[aria-label='Expand ghpr card']").click();
  const notice = card.querySelector(".ghpr-update-notice");
  assert.match(notice?.textContent || "", /Userscript update available.*1\.2\.0 → 1\.3\.0/s);
  notice.querySelector("button").click();
  assert.deepEqual(gm.opened, ["http://127.0.0.1:48120/install/ghpr.user.js"]);

  app.stop();
  window.close();
});

test("classifies only PR conversation URLs as the expanded surface", () => {
  assert.equal(
    isConversationSurface(new URL("https://github.com/example/repo/pull/42")),
    true
  );
  assert.equal(
    isConversationSurface(new URL("https://github.com/example/repo/pull/42/conversation")),
    true
  );
  assert.equal(
    isConversationSurface(new URL("https://github.com/example/repo/pull/42/checks")),
    false
  );
  assert.equal(
    isConversationSurface(new URL("https://github.com/example/repo/pull/42/files")),
    false
  );
  assert.equal(
    isConversationSurface(new URL("https://github.com/example/repo/actions/runs/9988")),
    false
  );
});

test("finds semantic anchors without depending on one GitHub selector", () => {
  const window = createWindow();
  assert.equal(semanticTargets(window.document, "pr.header.actions").length, 1);
  assert.equal(semanticTargets(window.document, "checks.run.trailing").length, 2);
  assert.equal(semanticTargets(window.document, "files.toolbar.actions").length, 0);
  window.close();
});

test("defaults the ghpr sidebar card to collapsed on PR checks", async () => {
  const window = createWindow();
  const app = createGhprApp({
    window,
    document: window.document,
    gm: new FakeGM()
  });
  await app.start();

  const sidebar = window.document.querySelector("#partial-discussion-sidebar");
  let card = window.document.getElementById("ghpr-github-root");
  assert.equal(card.parentElement, sidebar);
  assert.ok(card.classList.contains("ghpr-in-sidebar"));
  assert.ok(card.classList.contains("ghpr-compact"));
  const reviewers = sidebar.querySelector("[data-testid='reviewers-section']");
  const assignees = sidebar.querySelector("[data-testid='assignees-section']");
  assert.equal(
    reviewers.nextElementSibling,
    card,
    "The ghpr card should sit immediately after Reviewers"
  );
  assert.equal(
    card.nextElementSibling,
    assignees,
    "The ghpr card should stay above Assignees instead of falling to the sidebar bottom"
  );
  assert.equal(
    window.document.querySelector("[data-testid='issue-header'] #ghpr-github-root"),
    null,
    "The integration must not crowd the PR title or status row"
  );
  assert.equal(
    window.document.querySelector("[aria-label='ghpr CI Analysis']"),
    null,
    "The expanded conversation summary must stay off secondary PR tabs"
  );

  const toggle = card.querySelector("[aria-label='Expand ghpr card']");
  assert.equal(toggle.getAttribute("aria-expanded"), "false");
  toggle.click();
  assert.equal(card.classList.contains("ghpr-compact"), false);
  assert.equal(toggle.getAttribute("aria-label"), "Collapse ghpr card");
  assert.match(card.textContent, /ghpr.*Likely flaky.*Explain CI Failure/s);

  await app.refresh();
  card = window.document.getElementById("ghpr-github-root");
  assert.equal(
    card.classList.contains("ghpr-compact"),
    false,
    "Polling must preserve the user's expansion choice on the current surface"
  );

  app.stop();
  window.close();
});

test("defaults the ghpr card to expanded on the PR conversation", async () => {
  const window = createWindow("/example-org/example-repo/pull/1238");
  const app = createGhprApp({
    window,
    document: window.document,
    gm: new FakeGM()
  });
  await app.start();

  const card = window.document.getElementById("ghpr-github-root");
  assert.equal(card.classList.contains("ghpr-compact"), false);
  assert.ok(card.querySelector("[aria-label='Collapse ghpr card']"));
  assert.match(
    window.document.querySelector("[aria-label='ghpr CI Analysis']")?.textContent || "",
    /Likely flaky.*three main-branch runs/s
  );

  app.stop();
  window.close();
});

test("falls back to a responsive floating card when GitHub has no sidebar", async () => {
  const window = createWindow();
  window.document.querySelector("#partial-discussion-sidebar").remove();
  setViewport(window, 390, 640);
  const app = createGhprApp({
    window,
    document: window.document,
    gm: new FakeGM()
  });
  await app.start();

  const card = window.document.getElementById("ghpr-github-root");
  assert.equal(card.parentElement, window.document.body);
  assert.ok(card.classList.contains("ghpr-floating"));
  assert.ok(card.classList.contains("ghpr-compact"));
  const styles = window.document.getElementById("ghpr-github-styles").textContent;
  assert.match(styles, /@media \(max-width: 720px\)[\s\S]*left: 8px;[\s\S]*right: 8px;/);
  assert.match(styles, /max-height: min\(68vh, 520px\)/);
  assert.match(styles, /ghpr-compact \{[\s\S]*max-height: none;[\s\S]*padding: 8px 10px;/);
  assert.match(styles, /ghpr-floating\.ghpr-compact \{[\s\S]*left: auto;[\s\S]*width: min\(220px/);

  app.stop();
  window.close();
});

test("renders failed-check actions, local tags, and contribution fallback on PR checks", async () => {
  const window = createWindow();
  const gm = new FakeGM();
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();

  assert.equal(window.document.querySelector("#ghpr-github-root .ghpr-panel-title")?.textContent, "ghpr");
  assert.equal(
    window.document.querySelector("[aria-label='ghpr CI Analysis']"),
    null
  );
  window.document.querySelector("[aria-label='Expand ghpr card']").click();
  const failedRow = window.document.querySelectorAll("[data-testid='check-run-row']")[0];
  assert.match(failedRow.textContent, /Likely flaky.*Analyze/s);
  const successRow = window.document.querySelectorAll("[data-testid='check-run-row']")[1];
  assert.doesNotMatch(successRow.textContent, /Analyze/);
  assert.match(window.document.querySelector(".ghpr-panel-body")?.textContent || "", /Run Team Policy Check/);
  assert.match(
    window.document.querySelector(".ghpr-panel-body")?.textContent || "",
    /Local ghpr tags.*Flaky.*Not flaky.*Needs investigation/s
  );

  const health = gm.requests
    .filter((request) => new URL(request.url).pathname === "/api/v1/slot-health")
    .map((request) => JSON.parse(request.data));
  assert.ok(
    health.some((report) =>
      report.slot === "files.toolbar.actions" && report.healthy === false
    ),
    "missing semantic anchors must be reported and fall back to the ghpr card"
  );

  const classify = [...window.document.querySelectorAll(".ghpr-panel-action")]
    .find((element) => element.textContent === "Classify Flaky");
  classify.click();
  await settle();
  const action = gm.requests.find((request) =>
    new URL(request.url).pathname === "/api/v1/actions"
  );
  assert.deepEqual(actionBody(action).action, {
    kind: "run_skill",
    skill_id: "ci.failure.classify_flaky"
  });

  app.stop();
  window.close();
});

test("shows an active Skill run and opens its live log from GitHub surfaces", async () => {
  const snapshot = makeSnapshot();
  snapshot.runs = [{
    id: "run_live",
    skill_id: "ci.failure.explain",
    page: snapshot.page,
    requested_by_client_id: CLIENT.id,
    created_at: "2026-08-24T00:00:00Z",
    started_at: "2026-08-24T00:00:01Z",
    completed_at: null,
    status: "running",
    progress_message: "Comparing failure history",
    progress_current: 2,
    progress_total: 3,
    log_entries: [
      {
        timestamp: "2026-08-24T00:00:01Z",
        kind: "running",
        message: "Comparing failure history"
      }
    ],
    result: null,
    error: null,
    retry_of_run_id: null
  }];
  const checksWindow = createWindow();
  const checksGM = new FakeGM({ snapshot });
  const checksApp = createGhprApp({
    window: checksWindow,
    document: checksWindow.document,
    gm: checksGM
  });
  await checksApp.start();

  const root = checksWindow.document.getElementById("ghpr-github-root");
  assert.equal(root.dataset.state, "running");
  assert.equal(
    root.querySelector(".ghpr-panel-head .ghpr-badge")?.textContent,
    "Running"
  );
  const failedRow = checksWindow.document.querySelectorAll("[data-testid='check-run-row']")[0];
  assert.match(failedRow.textContent, /Running.*View log/s);
  assert.doesNotMatch(failedRow.textContent, /Analyze/);
  assert.match(
    checksWindow.document.querySelector(".ghpr-panel-body")?.textContent || "",
    /Running.*Comparing failure history.*View live log/s
  );

  failedRow.querySelector(".ghpr-check-tools button").click();
  await settle();
  const detailAction = checksGM.requests
    .filter((request) => new URL(request.url).pathname === "/api/v1/actions")
    .map(actionBody)
    .find((body) => body.action.kind === "open_detail");
  assert.deepEqual(detailAction?.action, {
    kind: "open_detail",
    run_id: "run_live"
  });
  assert.deepEqual(checksGM.opened, [
    "http://127.0.0.1:48120/ui/run/run_live?cap=detail_cap"
  ]);

  const conversationWindow = createWindow("/example-org/example-repo/pull/1238");
  const conversationApp = createGhprApp({
    window: conversationWindow,
    document: conversationWindow.document,
    gm: new FakeGM({ snapshot })
  });
  await conversationApp.start();
  const runningCard = conversationWindow.document.querySelector(
    "[aria-label='ghpr Skill Running']"
  );
  assert.match(
    runningCard?.textContent || "",
    /ci\.failure\.explain.*Running.*Comparing failure history.*2 \/ 3.*View live log/s
  );
  assert.equal(
    conversationWindow.document.querySelector("[aria-label='ghpr CI Analysis']"),
    null
  );

  checksApp.stop();
  conversationApp.stop();
  checksWindow.close();
  conversationWindow.close();
});

test("offers permission repair instead of actions when skill:run is not granted", async () => {
  const scopes = CLIENT.requested_scopes.filter((scope) => scope !== "skill:run");
  const window = createWindow();
  const snapshot = makeSnapshot();
  const contribution = {
    id: "scope-gated-run-skill",
    client_id: CLIENT.id,
    page_key: snapshot.page.key,
    slot: "pr.header.actions",
    component: {
      type: "action",
      label: "Run Scope-Gated Skill",
      text: null,
      tone: "analysis",
      presentation_ref: null
    },
    action: {
      kind: "run_skill",
      skill_id: "ci.failure.classify_flaky",
      run_id: null,
      analysis_id: null,
      tag: null,
      event: null
    },
    created_at: "2026-08-24T00:00:00Z",
    expires_at: null
  };
  snapshot.contributions.push(contribution);
  const gm = new FakeGM({
    scopes,
    pairingScopes: CLIENT.requested_scopes,
    snapshot
  });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  window.document.querySelector("[aria-label='Expand ghpr card']").click();

  const panel = window.document.querySelector(".ghpr-panel-body");
  assert.match(panel?.textContent || "", /skill:run required.*Grant Run Skills/s);
  assert.doesNotMatch(panel?.textContent || "", /Explain CI Failure|Classify Flaky/);
  const failedRow = window.document.querySelectorAll("[data-testid='check-run-row']")[0];
  assert.doesNotMatch(failedRow.textContent, /Analyze/);
  const contributionGrant = [...window.document.querySelectorAll("button")]
    .find((button) => button.textContent === "Grant Run Skill");
  assert.equal(Boolean(contributionGrant), true);
  await app.invokeAction({
    kind: "run_skill",
    skill_id: "ci.failure.classify_flaky"
  });
  assert.equal(
    gm.requests.some((request) => new URL(request.url).pathname === "/api/v1/actions"),
    false,
    "The userscript must not send a known unauthorized action."
  );
  assert.match(
    window.document.querySelector(".ghpr-error")?.textContent || "",
    /skill:run is not granted/
  );
  await app.invokeContribution(contribution);
  assert.equal(
    gm.requests.some((request) =>
      new URL(request.url).pathname.includes("/contributions/CLIENT_TEST/scope-gated-run-skill/invoke")
    ),
    false,
    "The userscript must not invoke a managed contribution with a missing scope."
  );

  const grant = [...window.document.querySelectorAll("button")]
    .find((button) => button.textContent === "Grant Run Skills");
  grant.click();
  await settle();
  assert.deepEqual(gm.opened, [
    "http://127.0.0.1:48120/ui/pair/pair_permissions?secret=pair_secret&return=https%3A%2F%2Fgithub.com%2Fexample-org%2Fexample-repo%2Fpull%2F1238%2Fchecks"
  ]);
  const pairingRequest = gm.requests.find((request) =>
    request.method === "POST" && new URL(request.url).pathname === "/api/v1/pairings"
  );
  assert.deepEqual(JSON.parse(pairingRequest.data).required_scopes, ["skill:run"]);
  assert.match(
    window.document.querySelector(".ghpr-panel-body")?.textContent || "",
    /Explain CI Failure.*Classify Flaky/s
  );
  assert.equal(
    gm.requests.some((request) => new URL(request.url).pathname === "/api/v1/actions"),
    false,
    "Approval must not replay the blocked action"
  );
  const grantedContributionButton = [...window.document.querySelectorAll("button")]
    .find((button) => button.textContent === "Run Scope-Gated Skill");
  assert.equal(grantedContributionButton?.disabled, false);
  app.stop();
  window.close();
});

test("renders declarative result cards and invokes them with page-scoped identity", async () => {
  const snapshot = makeSnapshot();
  snapshot.contributions.push({
    id: "skill.dev.example.static-review.result",
    client_id: CLIENT.id,
    page_key: snapshot.page.key,
    slot: "pr.mergebox.after",
    component: {
      type: "result_card",
      label: "Static Review",
      text: "<b>One actionable finding</b>",
      tone: "analysis",
      presentation_ref: "result.summary"
    },
    action: {
      kind: "open_detail",
      skill_id: null,
      run_id: "run_review",
      analysis_id: null,
      tag: null,
      event: null
    },
    created_at: "2026-08-24T00:00:00Z",
    expires_at: "2026-08-24T00:05:00Z"
  });
  snapshot.runs = [{
    id: "run_review",
    skill_id: "dev.example.static-review",
    page: snapshot.page,
    requested_by_client_id: CLIENT.id,
    created_at: "2026-08-24T00:00:00Z",
    started_at: "2026-08-24T00:00:01Z",
    completed_at: "2026-08-24T00:00:03Z",
    status: "completed",
    progress_message: "Completed",
    progress_current: 3,
    progress_total: 3,
    result: {
      kind: "code_review",
      title: "Static Review",
      summary: "One actionable finding",
      analysis: null,
      code_review: null,
      markdown: "One actionable finding",
      artifacts: []
    },
    error: null,
    retry_of_run_id: null
  }];
  const window = createWindow();
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();

  const card = window.document.querySelector("[aria-label='Static Review']");
  assert.match(card?.textContent || "", /One actionable finding.*Open Full Analysis/s);
  assert.equal(card.querySelector("b"), null, "Skill text must remain inert");
  card.querySelector("button").click();
  await settle();

  const invoke = gm.requests.find((request) =>
    new URL(request.url).pathname.includes("/contributions/") &&
    new URL(request.url).pathname.endsWith("/invoke")
  );
  assert.ok(invoke);
  assert.equal(new URL(invoke.url).searchParams.get("page_key"), snapshot.page.key);
  assert.match(window.document.querySelector("#ghpr-github-root")?.textContent || "", /Recent runs.*Static Review/s);

  app.stop();
  window.close();
});

test("renders untrusted analysis text without creating active markup", async () => {
  const snapshot = makeSnapshot();
  snapshot.analyses[0].summary = "<img src=x onerror='globalThis.pwned=true'>";
  const window = createWindow("/example-org/example-repo/pull/1238");
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();

  const card = window.document.querySelector("[aria-label='ghpr CI Analysis']");
  assert.match(card.textContent, /<img src=x/);
  assert.equal(card.querySelector("img"), null);

  app.stop();
  window.close();
});

test("stays silent when ghpr-view is offline", async () => {
  const window = createWindow();
  const gm = new FakeGM({ online: false });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();

  assert.equal(window.document.getElementById("ghpr-github-root"), null);
  assert.equal(window.document.querySelector("[data-ghpr-managed]"), null);

  app.stop();
  window.close();
});
