import assert from "node:assert/strict";
import { test } from "node:test";
import { Window } from "happy-dom";

globalThis.__GHPR_LOCAL_TEST__ = true;
await import("../app.js");
const { createLocalApp } = globalThis.GhprLocalUI;

function response(value, status = 200) {
  return { ok: status >= 200 && status < 300, status, async json() { return value; } };
}
function createWindow(url, page) {
  const window = new Window({ url });
  window.document.write(`<!doctype html><html><body data-ghpr-page="${page}"><div id="ghpr-app"></div></body></html>`);
  window.document.close();
  return window;
}
function shell(window, page) {
  assert.ok(window.document.querySelector(".app-header"));
  assert.ok(window.document.querySelector(".repo-header"));
  assert.equal(window.document.querySelector("[aria-current='page']")?.dataset.page, page);
}
function capabilities() {
  return { skill_contract: ["v1"], presentation_contract: ["v1"], browser_contract: ["v1"], supported_agents: ["codex"], supported_browser_slots: [], supported_sections: [] };
}
function localCapability(kind, resourceID = null) {
  return { kind, resource_id: resourceID, expires_at: "2099-01-01T00:00:00Z" };
}


async function settle(rounds = 4) {
  for (let index = 0; index < rounds; index += 1) {
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}

test("public overview explains privileged entry points", async () => {
  const window = createWindow("http://127.0.0.1:48120/ui", "home");
  const app = createLocalApp({ window, document: window.document, fetch: async (path) => {
    if (path === "/.well-known/ghpr-browser-bridge") return response({ protocol: "ghpr.browser-bridge/v1", app_version: "1.0.0" });
    if (path === "/api/v1/contracts/capabilities") return response(capabilities());
    throw new Error(path);
  }});
  await app.start();
  shell(window, "home");
  assert.match(window.document.body.textContent, /Open privileged tools from the ghpr app/);
  assert.equal(window.document.querySelector("nav [data-page='workbench']"), null);
  window.close();
});

test("overview never preserves privileged history navigation", async () => {

  const window = createWindow("http://127.0.0.1:48120/ui?cap=x&return=%2Fui%2Fanalysis%2Fa", "home");
  const app = createLocalApp({ window, document: window.document, fetch: async (path) => path === "/.well-known/ghpr-browser-bridge" ? response({ protocol: "ghpr.browser-bridge/v1", app_version: "1" }) : response(capabilities()) });
  await app.start();
  assert.equal(window.document.querySelector("nav [data-page='analysis']"), null);
  window.close();
});

test("analysis detail requires matching analysis capability", async () => {
  const window = createWindow("http://127.0.0.1:48120/ui/analysis/a1?cap=a", "analysis");
  const calls = [];
  const app = createLocalApp({ window, document: window.document, fetch: async (path) => {
    calls.push(path);
    if (path === "/api/v1/local-capability") return response(localCapability("analysis", "a1"));
    return response({ id: "a1", repository: "owner/repo", pr_number: 42, job_name: "CI", verdict: "likely_flaky", confidence: "high", confidence_score: 0.9, summary: "summary", history_matches: [], history_checked: 0, relatedness_score: null, relatedness_summary: null, reproduction: "not rerun", failure_signature: "x", changed_files: [], suggested_action: "rerun", agent: "codex", strict_context: true, duration_seconds: 1 });
  }});
  await app.start();
  shell(window, "analysis");
  assert.equal(calls[0], "/api/v1/local-capability");
  assert.equal(window.document.querySelector("a.button.primary")?.textContent, "Back to pull request");
  window.close();
});

test("run detail renders only after matching run capability", async () => {
  const window = createWindow("http://127.0.0.1:48120/ui/run/r1?cap=r", "run");
  const app = createLocalApp({ window, document: window.document, fetch: async (path) => {
    if (path === "/api/v1/local-capability") return response(localCapability("run", "r1"));
    return response({ id: "r1", skill_id: "skill", page: { repository: "owner/repo", pr_number: 42 }, status: "completed", progress_message: "Completed", log_entries: [], result: { title: "Result", summary: "Done" }, started_at: null, completed_at: null });
  }});
  await app.start();
  shell(window, "run");
  assert.match(window.document.body.textContent, /Result/);
  window.close();
});

test("missing capability renders detail recovery without protected data", async () => {
  const window = createWindow("http://127.0.0.1:48120/ui/analysis/a1?return=https%3A%2F%2Fgithub.com%2Fowner%2Frepo%2Fpull%2F42", "analysis");
  const app = createLocalApp({ window, document: window.document, fetch: async () => response({ error: { code: "unauthorized", message: "expired" } }, 401) });
  await app.start();
  assert.match(window.document.body.textContent, /Reopen this page from GitHub/);
  assert.equal(window.document.querySelector(".analysis-layout"), null);
  assert.equal(window.document.querySelector("a[href='https://github.com/owner/repo/pull/42']")?.textContent, "Return to GitHub");
  window.close();
});

test("wrong resource and malicious return are rejected", async () => {
  const window = createWindow("http://127.0.0.1:48120/ui/run/r1?cap=x&return=https%3A%2F%2Fgithub.com%3A8443%2Fowner%2Frepo%2Fpull%2F42", "run");
  const app = createLocalApp({ window, document: window.document, fetch: async (path) => path === "/api/v1/local-capability" ? response(localCapability("run", "other")) : response({}) });
  await app.start();
  assert.match(window.document.body.textContent, /Reopen this page from GitHub/);
  assert.equal(window.document.querySelector("a[href^='https://github.com']"), null);
  window.close();
});

test("Workbench family preserves capability navigation", async () => {
  const window = createWindow("http://127.0.0.1:48120/ui/github-preview?cap=work", "github-preview");
  const app = createLocalApp({ window, document: window.document, fetch: async (path) => path === "/api/v1/local-capability" ? response(localCapability("workbench")) : response(capabilities()) });
  await app.start();
  shell(window, "github-preview");
  assert.match(window.document.querySelector("nav")?.textContent || "", /Skill Workbench/);
  assert.match(window.document.querySelector("nav")?.querySelector("a[href*='cap=work']")?.href || "", /cap=work/);
  window.close();
});
test("Browser Test returns to Skill Workbench with the same capability", async () => {
  const window = createWindow("http://127.0.0.1:48120/ui/browser-test?cap=w", "browser-test");
  const app = createLocalApp({ window, document: window.document, fetch: async (path) => {
    if (path === "/api/v1/local-capability") return response(localCapability("workbench"));
    if (path === "/.well-known/ghpr-browser-bridge") return response({ protocol: "ghpr.browser-bridge/v1", app_version: "1" });
    return response(capabilities());
  }});
  await app.start();
  const back = [...window.document.querySelectorAll("a")].find((link) => link.textContent === "Back to Skill Workbench");
  assert.equal(back?.getAttribute("href"), "/ui/workbench?cap=w");
  window.close();
});

test("Workbench missing capability gives exact Settings recovery", async () => {
  const window = createWindow("http://127.0.0.1:48120/ui/workbench", "workbench");
  const app = createLocalApp({ window, document: window.document, fetch: async () => response({ error: { code: "unauthorized", message: "missing" } }, 401) });
  await app.start();
  assert.match(window.document.body.textContent, /Open ghpr → Settings → Skill Builder → Open Skill Workbench/);
  assert.equal(window.document.querySelector(".workbench"), null);
  window.close();
});

test("pairing pending lists required scopes and stops its timer", async () => {
  const window = createWindow("http://127.0.0.1:48120/ui/pair/p1?secret=s", "pairing");
  const app = createLocalApp({ window, document: window.document, fetch: async () => response({ descriptor: { id: "c", name: "Client", version: "1", requested_scopes: ["skill:run"], required_scopes: ["skill:run"] }, state: "pending", client: null, expires_at: "2099-01-01T00:00:00Z" }) });
  await app.start();
  assert.match(window.document.body.textContent, /Waiting for approval/);
  assert.match(window.document.body.textContent, /Required for this action/);
  assert.notEqual(app.pairingStatusTimer, null);
  app.stop();
  assert.equal(app.pairingStatusTimer, null);
  window.close();
});

test("pairing denied and expired states stop polling", async () => {
  for (const state of ["denied", "expired"]) {
    const window = createWindow(`http://127.0.0.1:48120/ui/pair/${state}?secret=s`, "pairing");
    const app = createLocalApp({ window, document: window.document, fetch: async () => response({ descriptor: { id: "c", name: "Client", version: "1", requested_scopes: ["skill:run"], required_scopes: ["skill:run"] }, state, client: null, expires_at: "2099-01-01T00:00:00Z" }) });
    await app.start();
    assert.match(window.document.body.textContent, new RegExp(state));
    assert.equal(app.pairingStatusTimer, null);
    app.stop();
    window.close();
  }
});

test("Workbench create flow performs scaffold, preview, test, and install", async () => {
  const window = createWindow("http://127.0.0.1:48120/ui/workbench?cap=w", "workbench");
  const operations = [];
  const fetch = async (path, options = {}) => {
    if (path === "/api/v1/local-capability") return response(localCapability("workbench"));
    if (path === "/api/v1/contracts/capabilities") return response(capabilities());
    const body = JSON.parse(options.body);
    operations.push(body.operation);
    return response({ path: "/tmp/draft/skill", validation: { valid: true, issues: [] }, install_statuses: null, preview: body.operation === "preview" ? { id: "skill", version: "1.0.0", display_name: "Skill", manifest: "", result_schema: "", presentation: "", browser_contributions: "", expected_result: "{}", requested_capabilities: [] } : null });
  };
  const app = createLocalApp({ window, document: window.document, fetch });
  await app.start();
  window.document.querySelector(".create-form").dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  await settle();
  assert.deepEqual(operations.slice(0, 2), ["scaffold", "preview"]);
  app.stop();
  window.close();
});

test("Enhance discovers native Skills from Claude Code, Codex, and OMP", async () => {
  const window = createWindow("http://127.0.0.1:48120/ui/workbench?cap=w", "workbench");
  const operations = [];
  const fetch = async (path, options = {}) => {
    if (path === "/api/v1/local-capability") return response(localCapability("workbench"));
    if (path === "/api/v1/contracts/capabilities") return response(capabilities());
    const body = JSON.parse(options.body);
    operations.push(body);
    if (body.operation === "discover_skills") {
      return response({
        skills: [
          {
            path: "/Users/example/.claude/skills/native-helper",
            display_name: "Native Helper",
            agents: ["claude_code"],
            is_ghpr_package: false
          },
          {
            path: "/Users/example/.codex/skills/team-policy",
            display_name: "Team Policy",
            agents: ["codex", "omp"],
            is_ghpr_package: true
          }
        ]
      });
    }
    if (body.operation === "preview") {
      return response({
        path: "/tmp/managed/team-policy",
        validation: { valid: true, issues: [] },
        install_statuses: null,
        preview: {
          id: "team.policy",
          version: "1.0.0",
          display_name: "Team Policy",
          manifest: "",
          result_schema: "{}",
          presentation: "",
          browser_contributions: "",
          expected_result: "{}",
          requested_capabilities: []
        }
      });
    }
    return response({
      path: "/tmp/managed/team-policy",
      validation: { valid: true, issues: [] },
      install_statuses: null,
      preview: null
    });
  };
  const app = createLocalApp({ window, document: window.document, fetch });
  await app.start();

  window.document.querySelector("[data-mode='enhance']").click();
  await settle();

  const select = window.document.querySelector(".discovered-skill-select");
  assert.ok(select);
  assert.match(select.textContent, /Native Helper — Claude Code/);
  assert.match(select.textContent, /Team Policy — Codex \+ OMP/);
  assert.match(
    window.document.querySelector(".enhance-form")?.textContent || "",
    /Found 2 compatible Skills in Claude Code, Codex, and OMP/
  );

  select.value = "/Users/example/.claude/skills/native-helper";
  window.document.querySelector(".enhance-form").dispatchEvent(
    new window.Event("submit", { bubbles: true, cancelable: true })
  );
  await settle();

  const enhance = operations.find((operation) => operation.operation === "enhance");
  assert.equal(enhance?.package_path, "/Users/example/.claude/skills/native-helper");
  app.stop();
  window.close();
});

test("run detail exposes structured live log output", async () => {
  const window = createWindow("http://127.0.0.1:48120/ui/run/live?cap=r", "run");
  const app = createLocalApp({ window, document: window.document, fetch: async (path) => {
    if (path === "/api/v1/local-capability") return response(localCapability("run", "live"));
    return response({ id: "live", skill_id: "skill", page: { repository: "owner/repo", pr_number: 42 }, status: "running", progress_message: "Comparing", log_entries: [{ kind: "running", message: "Comparing" }], result: null, started_at: null, completed_at: null });
  }});
  await app.start();
  assert.match(window.document.body.textContent, /Comparing/);
  assert.ok(window.document.querySelector("[role='log']"));
  app.stop();
  window.close();
});

test("run detail groups the lifecycle into expandable steps", async () => {
  const window = createWindow("http://127.0.0.1:48120/ui/run/steps?cap=r", "run");
  const run = {
    id: "steps",
    skill_id: "ci.failure.explain",
    page: { repository: "owner/repo", pr_number: 42 },
    status: "running",
    progress_message: "Receiving Agent output",
    created_at: "2026-08-24T00:00:00Z",
    started_at: "2026-08-24T00:00:00Z",
    completed_at: null,
    result: null,
    log_entries: [
      { timestamp: "2026-08-24T00:00:00Z", kind: "queued", message: "Queued" },
      { timestamp: "2026-08-24T00:00:01Z", kind: "running", message: "Preparing strict context" },
      { timestamp: "2026-08-24T00:00:02Z", kind: "running", message: "Starting Skill runtime" },
      { timestamp: "2026-08-24T00:00:03Z", kind: "running", message: "Executing Skill" },
      { timestamp: "2026-08-24T00:00:09Z", kind: "running", message: "Receiving Agent output" }
    ]
  };
  const app = createLocalApp({ window, document: window.document, fetch: async (path) => {
    if (path === "/api/v1/local-capability") return response(localCapability("run", "steps"));
    return response(run);
  }});
  await app.start();

  const steps = [...window.document.querySelectorAll(".run-step")];
  assert.deepEqual(steps.map((step) => step.dataset.step), [
    "queue",
    "context",
    "runtime",
    "execute"
  ]);
  assert.deepEqual(
    steps.map((step) => step.querySelector(".run-step-name").textContent),
    ["Queue run", "Prepare strict context", "Start Skill runtime", "Execute Skill"]
  );
  assert.deepEqual(steps.map((step) => step.open), [false, false, false, true]);
  assert.equal(steps[3].className, "run-step running");
  assert.match(steps[3].querySelector(".run-step-meta").textContent, /^2 events · \d+s$/);
  assert.deepEqual(
    [...steps[3].querySelectorAll(".run-log-line code")].map((line) => line.textContent),
    ["Executing Skill", "Receiving Agent output"]
  );
  assert.equal(steps[0].querySelector(".run-step-meta").textContent, "1 event · 1s");

  steps[0].querySelector("summary").click();
  assert.equal(steps[0].open, true);
  assert.equal(
    steps[0].querySelector(".run-log-line code").textContent,
    "Queued"
  );

  steps[3].querySelector("summary").click();
  run.log_entries.push({
    timestamp: "2026-08-24T00:00:12Z",
    kind: "success",
    message: "Completed"
  });
  run.status = "completed";
  run.completed_at = "2026-08-24T00:00:12Z";
  await app.renderRun();

  const refreshed = [...window.document.querySelectorAll(".run-step")];
  assert.deepEqual(refreshed.map((step) => step.dataset.step), [
    "queue",
    "context",
    "runtime",
    "execute",
    "complete"
  ]);
  assert.deepEqual(refreshed.map((step) => step.open), [true, false, false, false, false]);
  assert.equal(refreshed[3].className, "run-step success");
  assert.equal(refreshed[4].querySelector(".run-step-meta").textContent, "1 event · 0s");
  app.stop();
  window.close();
});

test("a failed run opens its failing step with the failure event", async () => {
  const window = createWindow("http://127.0.0.1:48120/ui/run/failed?cap=r", "run");
  const app = createLocalApp({ window, document: window.document, fetch: async (path) => {
    if (path === "/api/v1/local-capability") return response(localCapability("run", "failed"));
    return response({
      id: "failed",
      skill_id: "ci.failure.explain",
      page: { repository: "owner/repo", pr_number: 42 },
      status: "failed",
      progress_message: "Skill execution failed",
      error: "Skill execution failed",
      created_at: "2026-08-24T00:00:00Z",
      started_at: "2026-08-24T00:00:00Z",
      completed_at: "2026-08-24T00:00:05Z",
      result: null,
      log_entries: [
        { timestamp: "2026-08-24T00:00:00Z", kind: "queued", message: "Queued" },
        { timestamp: "2026-08-24T00:00:05Z", kind: "error", message: "Skill execution failed" }
      ]
    });
  }});
  await app.start();

  const steps = [...window.document.querySelectorAll(".run-step")];
  assert.deepEqual(steps.map((step) => step.dataset.step), ["queue", "complete"]);
  assert.deepEqual(steps.map((step) => step.open), [false, true]);
  assert.equal(steps[1].className, "run-step failed");
  assert.equal(steps[1].querySelector(".run-log-line.error code").textContent, "Skill execution failed");
  app.stop();
  window.close();
});

test("approved pairing without required scope remains actionable", async () => {
  const window = createWindow("http://127.0.0.1:48120/ui/pair/missing?secret=s&return=https%3A%2F%2Fgithub.com%2Fowner%2Frepo%2Fpull%2F1", "pairing");
  const app = createLocalApp({ window, document: window.document, fetch: async () => response({
    descriptor: { id: "c", name: "Client", version: "1", requested_scopes: ["skill:run"], required_scopes: ["skill:run"] },
    state: "approved",
    client: { scopes: [] },
    expires_at: "2099-01-01T00:00:00Z"
  }) });
  await app.start();
  assert.match(window.document.body.textContent, /Missing permissions: skill:run/);
  assert.match(window.document.body.textContent, /Return now/);
  app.stop();
  window.close();
});
