import assert from "node:assert/strict";
import { test } from "node:test";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import {
  registerImportReviewTool,
  type ImportReviewImporter,
  type ImportReviewSocketRequest,
  type ImportReviewResult,
} from "../src/review-import.ts";

const VALID_SHA_A = "a".repeat(40);
const VALID_SHA_B = "b".repeat(40);

function validArgs() {
  return {
    repository: "example-org/example-repo",
    number: 42,
    base_sha: VALID_SHA_A,
    head_sha: VALID_SHA_B,
    engine: "claude-code",
    overview_markdown: "## Overview\nLooks good overall.",
    findings: [
      {
        file: "src/index.ts",
        start_line: 10,
        end_line: 12,
        side: "right" as const,
        title: "Missing null check",
        summary: "This can throw if `value` is null.",
        severity: "warning" as const,
        confidence: 0.8,
        category: "correctness",
      },
    ],
  };
}

async function withLinkedServer(
  importer: ImportReviewImporter,
): Promise<{ client: Client; server: McpServer; close: () => Promise<void> }> {
  const server = new McpServer({ name: "test-server", version: "0.0.0" });
  registerImportReviewTool(server, importer);

  const client = new Client({ name: "test-client", version: "0.0.0" });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();

  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);

  return {
    client,
    server,
    close: async () => {
      await client.close();
      await server.close();
    },
  };
}

test("import_review is listed with mutating, non-destructive, idempotent, closed-world annotations", async () => {
  const { client, close } = await withLinkedServer(async () => {
    throw new Error("importer should not be called by list_tools");
  });
  try {
    const { tools } = await client.listTools();
    const tool = tools.find((t) => t.name === "import_review");
    assert.ok(tool, "import_review tool must be registered");
    assert.equal(tool?.annotations?.readOnlyHint, false);
    assert.equal(tool?.annotations?.destructiveHint, false);
    assert.equal(tool?.annotations?.idempotentHint, true);
    assert.equal(tool?.annotations?.openWorldHint, false);
  } finally {
    await close();
  }
});

test("a valid call reaches the injected importer with the exact camelCase socket payload and returns the exact structured result", async () => {
  let received: ImportReviewSocketRequest | undefined;
  const stubResult: ImportReviewResult = {
    runID: "run_mcp_abc123",
    repository: "example-org/example-repo",
    number: 42,
    headSHA: VALID_SHA_B,
    findingCount: 1,
    importedAt: "2026-01-01T00:00:00Z",
    alreadyImported: false,
  };

  const { client, close } = await withLinkedServer(async (request) => {
    received = request;
    return stubResult;
  });

  try {
    const result = await client.callTool({
      name: "import_review",
      arguments: validArgs(),
    });

    assert.ok(received, "importer must have been invoked");
    assert.deepEqual(received, {
      repository: "example-org/example-repo",
      number: 42,
      review: {
        baseSHA: VALID_SHA_A,
        headSHA: VALID_SHA_B,
        engine: "claude-code",
        overviewMarkdown: "## Overview\nLooks good overall.",
        findings: [
          {
            file: "src/index.ts",
            startLine: 10,
            endLine: 12,
            side: "right",
            title: "Missing null check",
            summary: "This can throw if `value` is null.",
            why: undefined,
            suggestedFix: undefined,
            background: undefined,
            quotedCode: undefined,
            severity: "warning",
            confidence: 0.8,
            category: "correctness",
          },
        ],
      },
    });

    assert.equal(result.isError, undefined);
    assert.deepEqual(result.structuredContent, {
      run_id: "run_mcp_abc123",
      repository: "example-org/example-repo",
      number: 42,
      head_sha: VALID_SHA_B,
      finding_count: 1,
      imported_at: "2026-01-01T00:00:00Z",
      already_imported: false,
    });
  } finally {
    await close();
  }
});

test("an invalid SHA is rejected before the importer runs", async () => {
  let called = false;
  const { client, close } = await withLinkedServer(async () => {
    called = true;
    throw new Error("importer must not be reached for invalid input");
  });

  try {
    const args = validArgs();
    args.base_sha = "not-a-sha";
    const result = await client.callTool({ name: "import_review", arguments: args });
    assert.equal(result.isError, true);
  } finally {
    assert.equal(called, false, "importer must not be called for invalid base_sha");
    await close();
  }
});

test("an invalid line range (end_line < start_line) is rejected before the importer runs", async () => {
  let called = false;
  const { client, close } = await withLinkedServer(async () => {
    called = true;
    throw new Error("importer must not be reached for invalid input");
  });

  try {
    const args = validArgs();
    args.findings = [{ ...args.findings[0], start_line: 20, end_line: 10 }];
    const result = await client.callTool({ name: "import_review", arguments: args });
    assert.equal(result.isError, true);
  } finally {
    assert.equal(called, false, "importer must not be called for an invalid line range");
    await close();
  }
});
