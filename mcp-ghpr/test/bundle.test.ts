import assert from "node:assert/strict";
import { copyFile, mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const sourceBundle = fileURLToPath(
  new URL("../../mcp-ghpr-bundle/index.mjs", import.meta.url),
);

test("the copied app-resource MCP bundle initializes without node_modules", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "ghpr-mcp-app-resources-"));
  const resources = path.join(root, "PRDashboard.app", "Contents", "Resources");
  const copiedBundle = path.join(resources, "mcp-ghpr-bundle", "index.mjs");
  await mkdir(path.dirname(copiedBundle), { recursive: true });
  await copyFile(sourceBundle, copiedBundle);

  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [copiedBundle],
    cwd: resources,
    env: {},
    stderr: "pipe",
  });
  const stderr: Buffer[] = [];
  transport.stderr?.on("data", (chunk) => stderr.push(Buffer.from(chunk)));
  const client = new Client({ name: "ghpr-bundle-smoke", version: "1.0.0" });

  try {
    await client.connect(transport);
    await client.ping();
    const tools = await client.listTools();
    assert.ok(
      tools.tools.some((tool) => tool.name === "import_review"),
      "the standalone bundle must expose the review-import tool",
    );
  } catch (error) {
    assert.fail(
      `${error instanceof Error ? error.stack ?? error.message : String(error)}\n${Buffer.concat(stderr).toString("utf8")}`,
    );
  } finally {
    await client.close();
    await rm(root, { recursive: true, force: true });
  }
});
