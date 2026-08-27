import assert from "node:assert/strict";
import { beforeEach, test } from "node:test";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { Ghpr, GhprSDKError, parseGitHubPage } = require("../../userscript-sdk/index.js");

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

  assert.equal(client.client.id, "com.example.pairing");
  assert.deepEqual(pairingDescriptor.requested_scopes, ["pr:read", "skill:run"]);
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