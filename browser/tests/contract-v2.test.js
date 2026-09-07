import assert from "node:assert/strict";
import { test } from "node:test";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const require = createRequire(import.meta.url);
const {
  Ghpr,
  GhprSDKError,
  validateBrowserContractV2,
  CONTRACT_V2_TARGET_KINDS,
  CONTRACT_V2_SURFACES,
  CONTRACT_V2_VIEW_TYPES
} = require("../../userscript-sdk/index.js");

const fixturesDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "fixtures");

function loadFixture(name) {
  return JSON.parse(readFileSync(path.join(fixturesDir, name), "utf8"));
}

test("validates a well-formed Browser Contract v2 document", () => {
  const contract = loadFixture("contract-v2-valid.json");
  const validated = validateBrowserContractV2(contract);
  assert.equal(validated.apiVersion, "ghpr.dev/browser/v2");
  assert.deepEqual(validated.targetKinds, ["github.pull_request_revision", "github.workflow_job"]);
  assert.equal(validated.placements.length, 4);

  const repeated = validated.placements.find((placement) => placement.id === "diff-findings");
  assert.deepEqual(repeated.repeat, { source: "result.findings" });
  assert.equal(repeated.bindTo, "item.finding");
  assert.equal(repeated.view.type, "review_finding");

  const single = validated.placements.find((placement) => placement.id === "review-summary");
  assert.equal(single.repeat, null);
  assert.equal(single.bindTo, "result.review");

  // Exposed via the connected client, too.
  assert.equal(typeof Ghpr.validateBrowserContractV2, "function");
});

test("is exhaustive: every fixture surface/view/target kind is a known enum member", () => {
  const contract = loadFixture("contract-v2-valid.json");
  for (const kind of contract.target_kinds) {
    assert.ok(CONTRACT_V2_TARGET_KINDS.includes(kind), `unexpected target kind ${kind}`);
  }
  for (const placement of contract.placements) {
    assert.ok(CONTRACT_V2_SURFACES.includes(placement.surface), `unexpected surface ${placement.surface}`);
    assert.ok(CONTRACT_V2_VIEW_TYPES.includes(placement.view.type), `unexpected view type ${placement.view.type}`);
  }
});

test("rejects a contract carrying a raw DOM selector and injected HTML/script", () => {
  const contract = loadFixture("contract-v2-malicious.json");
  assert.throws(
    () => validateBrowserContractV2(contract),
    (error) => error instanceof GhprSDKError && error.code === "contract_unknown_field"
  );
});

test("rejects a contract carrying an iframe/external-URL field inside a view", () => {
  const contract = loadFixture("contract-v2-malicious-iframe.json");
  assert.throws(
    () => validateBrowserContractV2(contract),
    (error) => error instanceof GhprSDKError && error.code === "contract_unknown_field"
  );
});

test("rejects a contract that targets a surface outside the seven known Surface IDs", () => {
  const contract = loadFixture("contract-v2-malicious-unknown-surface.json");
  assert.throws(
    () => validateBrowserContractV2(contract),
    (error) => error instanceof GhprSDKError && error.code === "contract_unknown_surface"
  );
});

test("rejects a binding path that escapes the result/item namespace", () => {
  const contract = loadFixture("contract-v2-malicious-binding.json");
  assert.throws(
    () => validateBrowserContractV2(contract),
    (error) => error instanceof GhprSDKError && error.code === "contract_invalid_binding"
  );
});

test("rejects an unsupported api_version", () => {
  assert.throws(
    () => validateBrowserContractV2({ api_version: "ghpr.dev/browser/v1", target_kinds: [], placements: [] }),
    (error) => error instanceof GhprSDKError && error.code === "contract_unsupported_version"
  );
});

test("rejects an unknown root-level key even when everything else is valid", () => {
  const contract = loadFixture("contract-v2-valid.json");
  const withExtra = { ...contract, javascript: "alert(1)" };
  assert.throws(
    () => validateBrowserContractV2(withExtra),
    (error) => error instanceof GhprSDKError && error.code === "contract_unknown_field"
  );
});

test("rejects duplicate placement ids", () => {
  const contract = loadFixture("contract-v2-valid.json");
  const duplicated = {
    ...contract,
    placements: [contract.placements[0], { ...contract.placements[0] }]
  };
  assert.throws(
    () => validateBrowserContractV2(duplicated),
    (error) => error instanceof GhprSDKError && error.code === "contract_duplicate_placement"
  );
});

test("rejects a placement view whose type is not one of the eight allowlisted views", () => {
  const contract = loadFixture("contract-v2-valid.json");
  const badView = {
    ...contract,
    placements: [{ ...contract.placements[0], view: { type: "arbitrary_custom_renderer" } }]
  };
  assert.throws(
    () => validateBrowserContractV2(badView),
    (error) => error instanceof GhprSDKError && error.code === "contract_unknown_view_type"
  );
});

test("rejects a placement missing both bind_to and repeat", () => {
  const contract = loadFixture("contract-v2-valid.json");
  const { bind_to, ...withoutBinding } = contract.placements[0];
  const missingBinding = { ...contract, placements: [withoutBinding] };
  assert.throws(
    () => validateBrowserContractV2(missingBinding),
    (error) => error instanceof GhprSDKError && error.code === "contract_invalid_placement"
  );
});

test("rejects a repeat.bind_to that is not scoped under item.", () => {
  const contract = loadFixture("contract-v2-valid.json");
  const repeated = contract.placements.find((placement) => placement.id === "diff-findings");
  const badItemScope = {
    ...contract,
    placements: [{ ...repeated, bind_to: "result.finding" }]
  };
  assert.throws(
    () => validateBrowserContractV2(badItemScope),
    (error) => error instanceof GhprSDKError && error.code === "contract_invalid_binding"
  );
});
