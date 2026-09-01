import assert from "node:assert/strict";
import { beforeEach, test } from "node:test";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { Ghpr, GhprSDKError, parseGitHubPage } = require("../../userscript-sdk/index.js");

async function connectedClient(gm, overrides = {}) {
  return Ghpr.connect({
    id: "com.example.helper",
    name: "Example Helper",
    version: "1.0.0",
    requestedScopes: ["pr:read", "ci:read", "skill:run", "analysis:read", "finding:write"],
    location: new URL("https://github.com/example-org/example-repo/pull/42"),
    gm,
    ...overrides
  });
}

function baseGM(handler, initial = {}) {
  return makeGM((request) => {
    const path = new URL(request.url).pathname;
    if (path === "/.well-known/ghpr-browser-bridge") return response(discovery());
    if (path === "/api/v1/client") {
      return response({
        id: "com.example.helper",
        scopes: ["pr:read", "ci:read", "skill:run", "analysis:read", "finding:write"]
      });
    }
    return handler(request, path);
  }, {
    "ghpr.sdk.bridge.port": 48120,
    "ghpr.sdk.bridge.instance": "instance-a",
    "ghpr.sdk.com.example.helper.token": "client-capability",
    ...initial
  });
}

beforeEach(() => {
  delete globalThis.GM;
});

function response(value, status = 200) {
  return { status, responseText: JSON.stringify(value) };
}

function makeGM(handler, initial = {}) {
  const storage = new Map(Object.entries(initial));
  const opened = [];
  const requests = [];
  return {
    storage,
    opened,
    requests,
    getValue(key, fallback) {
      return storage.has(key) ? storage.get(key) : fallback;
    },
    setValue(key, value) {
      storage.set(key, value);
    },
    openInTab(url) {
      opened.push(url);
    },
    xmlHttpRequest(options) {
      requests.push(options);
      Promise.resolve()
        .then(() => handler(options))
        .then(options.onload, options.onerror);
    }
  };
}

function discovery(instanceID = "instance-a") {
  return {
    protocol: "ghpr.browser-bridge/v1",
    instance_id: instanceID,
    app_version: "1.0.0",
    api_versions: [1],
    pairing_required: true
  };
}

test("parses supported GitHub pages without exposing a page global", () => {
  assert.deepEqual(
    parseGitHubPage(new URL("https://github.com/example-org/example-repo/pull/42/checks")),
    {
      type: "pull_request",
      key: "github:example-org/example-repo:pr:42",
      repository: "example-org/example-repo",
      pr_number: 42,
      workflow_run_id: null
    }
  );
  assert.equal(parseGitHubPage(new URL("https://github.com/issues")), null);
  assert.equal(globalThis.ghpr, undefined);
});

test("uses a client-specific capability token for scoped SDK calls", async () => {
  const gm = makeGM((request) => {
    const path = new URL(request.url).pathname;
    if (path === "/.well-known/ghpr-browser-bridge") return response(discovery());
    if (path === "/api/v1/client") {
      return response({
        id: "com.example.helper",
        scopes: ["pr:read", "tag:read", "tag:write"]
      });
    }
    if (path === "/api/v1/page") {
      return response({
        pull_request: {
          number: 42,
          ci_workflows: [
            { name: "unit-test", failure_count: 1 },
            { name: "lint", failure_count: 0 }
          ]
        }
      });
    }
    if (path === "/api/v1/tags") return response({ tags: ["flaky"] });
    throw new Error(`Unexpected request: ${request.url}`);
  }, {
    "ghpr.sdk.bridge.port": 48120,
    "ghpr.sdk.bridge.instance": "instance-a",
    "ghpr.sdk.com.example.helper.token": "client-capability"
  });

  const client = await Ghpr.connect({
    id: "com.example.helper",
    name: "Example Helper",
    version: "1.0.0",
    requestedScopes: ["pr:read", "tag:read", "tag:write"],
    location: new URL("https://github.com/example-org/example-repo/pull/42"),
    gm
  });
  assert.equal((await client.page.current()).pr_number, 42);
  assert.deepEqual((await client.ci.listFailedJobs()).map((run) => run.name), ["unit-test"]);
  assert.deepEqual(await client.tags.set("flaky"), ["flaky"]);

  const authenticated = gm.requests.filter((request) =>
    new URL(request.url).pathname.startsWith("/api/v1/")
  );
  assert.ok(authenticated.length >= 3);
  for (const request of authenticated) {
    assert.equal(request.headers.Authorization, "Bearer client-capability");
  }
  const tagRequest = authenticated.find((request) =>
    request.method === "PUT" && new URL(request.url).pathname === "/api/v1/tags"
  );
  assert.deepEqual(JSON.parse(tagRequest.data), {
    page_key: "github:example-org/example-repo:pr:42",
    tag: "flaky"
  });
});

test("pairs through native approval and persists only that client token", async () => {
  let pairingDescriptor = null;
  const gm = makeGM((request) => {
    const url = new URL(request.url);
    if (url.pathname === "/.well-known/ghpr-browser-bridge") return response(discovery());
    if (url.pathname === "/api/v1/pairings" && request.method === "POST") {
      pairingDescriptor = JSON.parse(request.data);
      return response({
        request_id: "pair-1",
        pairing_secret: "secret-1",
        pairing_url: "http://127.0.0.1:48120/ui/pair/pair-1?secret=secret-1"
      });
    }
    if (url.pathname === "/api/v1/pairings/pair-1") {
      return response({
        state: "approved",
        token: "approved-capability",
        client: {
          id: "com.example.pairing",
          scopes: ["pr:read", "skill:run"]
        }
      });
    }
    throw new Error(`Unexpected request: ${request.url}`);
  });

  const states = [];
  const client = await Ghpr.connect({
    id: "com.example.pairing",
    name: "Pairing Example",
    version: "2.0.0",
    requestedScopes: ["pr:read", "skill:run"],
    requiredScopes: ["skill:run"],
    page: {
      type: "pull_request",
      key: "github:example-org/example-repo:pr:42",
      repository: "example-org/example-repo",
      pr_number: 42,
      workflow_run_id: null
    },
    gm,
    pairingPollIntervalMs: 0,
    onPairingState: (state) => states.push(state)
  });

  assert.deepEqual(pairingDescriptor.requested_scopes, ["pr:read", "skill:run"]);
  assert.deepEqual(pairingDescriptor.required_scopes, ["skill:run"]);
  assert.deepEqual(states, ["requesting", "approved"]);
  assert.equal(
    gm.storage.get("ghpr.sdk.com.example.pairing.token"),
    "approved-capability"
  );
  assert.equal(gm.storage.has("ghpr.bridge.token"), false);
  assert.equal(gm.opened.length, 1);
});

test("invalidates a token when the bridge instance changes", async () => {
  const gm = makeGM((request) => {
    const path = new URL(request.url).pathname;
    if (path === "/.well-known/ghpr-browser-bridge") return response(discovery("instance-b"));
    throw new Error(`Unexpected request: ${request.url}`);
  }, {
    "ghpr.sdk.bridge.port": 48120,
    "ghpr.sdk.bridge.instance": "instance-a",
    "ghpr.sdk.com.example.stale.token": "stale-token"
  });

  await assert.rejects(
    Ghpr.connect({
      id: "com.example.stale",
      name: "Stale Client",
      version: "1.0.0",
      requestedScopes: ["pr:read"],
      pair: false,
      gm
    }),
    (error) => error instanceof GhprSDKError && error.code === "pairing_required"
  );
  assert.equal(gm.storage.get("ghpr.sdk.com.example.stale.token"), null);
});

test("preserves bridge denial status and error code", async () => {
  const gm = makeGM((request) => {
    const path = new URL(request.url).pathname;
    if (path === "/.well-known/ghpr-browser-bridge") return response(discovery());
    if (path === "/api/v1/client") {
      return response({ id: "com.example.denied", scopes: ["pr:read"] });
    }
    if (path === "/api/v1/skills") {
      return response(
        { error: { code: "missing_scope", message: "Missing scope: skill:list" } },
        403
      );
    }
    throw new Error(`Unexpected request: ${request.url}`);
  }, {
    "ghpr.sdk.bridge.port": 48120,
    "ghpr.sdk.bridge.instance": "instance-a",
    "ghpr.sdk.com.example.denied.token": "read-only-capability"
  });

  const client = await Ghpr.connect({
    id: "com.example.denied",
    name: "Denied Client",
    version: "1.0.0",
    requestedScopes: ["pr:read"],
    gm
  });
  await assert.rejects(
    client.skills.list(),
    (error) => error.status === 403 && error.code === "missing_scope"
  );
});

test("parses Actions job URLs into a workflow_run_job page context", () => {
  assert.deepEqual(
    parseGitHubPage(new URL("https://github.com/example-org/example-repo/actions/runs/555/job/777")),
    {
      type: "workflow_run_job",
      key: "github:example-org/example-repo:run:555:job:777",
      repository: "example-org/example-repo",
      pr_number: null,
      workflow_run_id: 555,
      workflow_job_id: 777
    }
  );
  assert.deepEqual(
    parseGitHubPage(new URL("https://github.com/example-org/example-repo/actions/runs/555")),
    {
      type: "workflow_run",
      key: "github:example-org/example-repo:run:555",
      repository: "example-org/example-repo",
      pr_number: null,
      workflow_run_id: 555
    }
  );
});

test("resolves a canonical GitHub subject and starts a subject-keyed v2 run", async () => {
  let resolveInput = null;
  let runBody = null;
  const gm = baseGM((request, path) => {
    if (path === "/api/v1/subjects/resolve") {
      resolveInput = JSON.parse(request.data);
      return response({
        type: "workflow_job",
        repository: "example-org/example-repo",
        workflow_run_id: 555,
        workflow_attempt: 1,
        workflow_job_id: 777,
        head_sha: "a".repeat(40)
      });
    }
    if (path === "/api/v1/runs" && request.method === "POST") {
      runBody = JSON.parse(request.data);
      return response({ id: "run_1", state: "queued" });
    }
    throw new Error(`Unexpected request: ${request.url}`);
  });

  const client = await connectedClient(gm);
  const subject = await client.subjects.resolve({
    type: "workflow_job",
    repository: "example-org/example-repo",
    workflow_run_id: 555,
    workflow_job_id: 777
  });
  assert.deepEqual(resolveInput, {
    type: "workflow_job",
    repository: "example-org/example-repo",
    workflow_run_id: 555,
    workflow_job_id: 777
  });
  assert.equal(subject.type, "workflow_job");

  const run = await client.runs.start("ci.failure.explain", subject);
  assert.equal(run.id, "run_1");
  assert.deepEqual(runBody, { skill_id: "ci.failure.explain", subject });
});

test("rejects every path to start a v2 run without a precise resolved subject", async () => {
  const gm = baseGM(() => {
    throw new Error("No v2 run request should reach the Bridge for an imprecise subject.");
  });
  const client = await connectedClient(gm);
  const pageOnlyContexts = [
    undefined,
    null,
    {},
    { type: "pull_request", key: "github:example-org/example-repo:pr:42", repository: "example-org/example-repo", pr_number: 42, workflow_run_id: null },
    { type: "workflow_run", key: "github:example-org/example-repo:run:555", repository: "example-org/example-repo", pr_number: null, workflow_run_id: 555 },
    { type: "workflow_run_job", key: "github:example-org/example-repo:run:555:job:777", repository: "example-org/example-repo", pr_number: null, workflow_run_id: 555, workflow_job_id: 777 },
    "github:example-org/example-repo:pr:42"
  ];
  for (const pageOnly of pageOnlyContexts) {
    await assert.rejects(
      client.runs.start("ci.failure.explain", pageOnly),
      (error) => error instanceof GhprSDKError && error.code === "invalid_subject"
    );
  }
  const requestsToRuns = gm.requests.filter((request) => new URL(request.url).pathname === "/api/v1/runs");
  assert.equal(requestsToRuns.length, 0);
});

test("keeps the v1 page-based skills.run path unchanged for backward compatibility", async () => {
  let runBody = null;
  const gm = baseGM((request, path) => {
    if (path === "/api/v1/runs" && request.method === "POST") {
      runBody = JSON.parse(request.data);
      return response({ id: "run_v1", state: "queued" });
    }
    throw new Error(`Unexpected request: ${request.url}`);
  });
  const client = await connectedClient(gm);
  const run = await client.skills.run("pr.review");
  assert.equal(run.id, "run_v1");
  assert.deepEqual(runBody, {
    skill_id: "pr.review",
    page: {
      type: "pull_request",
      key: "github:example-org/example-repo:pr:42",
      repository: "example-org/example-repo",
      pr_number: 42,
      workflow_run_id: null
    }
  });
});

test("lists findings by subject key and dismisses one by id", async () => {
  let listedQuery = null;
  const gm = baseGM((request, path) => {
    if (path === "/api/v1/findings" && request.method === "GET") {
      listedQuery = new URL(request.url).searchParams.get("subject_key");
      return response({ findings: [{ id: "finding_1", severity: "warning" }] });
    }
    if (path === "/api/v1/findings/finding_1/dismiss" && request.method === "POST") {
      return response({ id: "finding_1", dismissed: true });
    }
    throw new Error(`Unexpected request: ${request.url}`);
  });
  const client = await connectedClient(gm);
  const findings = await client.findings.list("github:diff-line:deadbeef");
  assert.equal(listedQuery, "github:diff-line:deadbeef");
  assert.deepEqual(findings, [{ id: "finding_1", severity: "warning" }]);

  const dismissed = await client.findings.dismiss("finding_1");
  assert.equal(dismissed.dismissed, true);
});

test("requires a subjectKey before listing findings", async () => {
  const gm = baseGM(() => {
    throw new Error("No findings request should reach the Bridge without a subjectKey.");
  });
  const client = await connectedClient(gm);
  await assert.rejects(
    client.findings.list(),
    (error) => error instanceof GhprSDKError && error.code === "invalid_subject_key"
  );
  await assert.rejects(
    client.findings.list(""),
    (error) => error instanceof GhprSDKError && error.code === "invalid_subject_key"
  );
});