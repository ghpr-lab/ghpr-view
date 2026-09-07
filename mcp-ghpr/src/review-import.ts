import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

const shaSchema = z
  .string()
  .regex(/^[0-9a-fA-F]{40}$/, "must be a 40-character hex SHA");

const findingSchema = z
  .object({
    file: z.string().min(1).max(1024).describe("Repo-relative file path."),
    start_line: z.number().int().positive(),
    end_line: z.number().int().positive(),
    side: z.enum(["left", "right"]).describe("Diff side the finding anchors to."),
    title: z.string().min(1).max(200),
    summary: z.string().min(1).max(2000),
    why: z.string().max(20_000).optional(),
    suggested_fix: z.string().max(20_000).optional(),
    background: z.string().max(20_000).optional(),
    quoted_code: z.string().max(20_000).optional(),
    severity: z.enum(["error", "warning", "info"]),
    confidence: z.number().min(0).max(1),
    category: z.string().min(1).max(200),
  })
  .strict()
  .refine((finding) => finding.end_line >= finding.start_line, {
    message: "end_line must be greater than or equal to start_line",
    path: ["end_line"],
  });

export const importReviewInputShape = {
  repository: z.string().min(1).describe("OWNER/NAME, e.g. 'example-org/example-repo'."),
  number: z.number().int().positive().describe("PR number."),
  base_sha: shaSchema.describe("40-character hex SHA of the base commit that was reviewed."),
  head_sha: shaSchema.describe("40-character hex SHA of the head commit that was reviewed."),
  engine: z.string().min(1).max(200).describe("Free-form provenance label for the review tool/agent."),
  overview_markdown: z.string().min(1).max(100_000).describe("Markdown summary of the review."),
  findings: z.array(findingSchema).min(1).max(50).describe("Line-anchored findings, at most 50."),
};

const importReviewInputSchema = z.object(importReviewInputShape);

export type ImportReviewInput = z.infer<typeof importReviewInputSchema>;
export type ImportReviewFindingInput = z.infer<typeof findingSchema>;

export interface ImportReviewSocketFinding {
  file: string;
  startLine: number;
  endLine: number;
  side: "left" | "right";
  title: string;
  summary: string;
  why?: string;
  suggestedFix?: string;
  background?: string;
  quotedCode?: string;
  severity: "error" | "warning" | "info";
  confidence: number;
  category: string;
}

export interface ImportReviewSocketRequest {
  repository: string;
  number: number;
  review: {
    baseSHA: string;
    headSHA: string;
    engine: string;
    overviewMarkdown: string;
    findings: ImportReviewSocketFinding[];
  };
}

export interface ImportReviewResult {
  runID: string;
  repository: string;
  number: number;
  headSHA: string;
  findingCount: number;
  importedAt: string;
  alreadyImported: boolean;
}

export type ImportReviewImporter = (request: ImportReviewSocketRequest) => Promise<ImportReviewResult>;

const importReviewOutputShape = {
  run_id: z.string(),
  repository: z.string(),
  number: z.number(),
  head_sha: z.string(),
  finding_count: z.number(),
  imported_at: z.string(),
  already_imported: z.boolean(),
};

export function toSocketRequest(input: ImportReviewInput): ImportReviewSocketRequest {
  return {
    repository: input.repository,
    number: input.number,
    review: {
      baseSHA: input.base_sha,
      headSHA: input.head_sha,
      engine: input.engine,
      overviewMarkdown: input.overview_markdown,
      findings: input.findings.map((finding) => ({
        file: finding.file,
        startLine: finding.start_line,
        endLine: finding.end_line,
        side: finding.side,
        title: finding.title,
        summary: finding.summary,
        why: finding.why,
        suggestedFix: finding.suggested_fix,
        background: finding.background,
        quotedCode: finding.quoted_code,
        severity: finding.severity,
        confidence: finding.confidence,
        category: finding.category,
      })),
    },
  };
}

function toStructuredOutput(result: ImportReviewResult) {
  return {
    run_id: result.runID,
    repository: result.repository,
    number: result.number,
    head_sha: result.headSHA,
    finding_count: result.findingCount,
    imported_at: result.importedAt,
    already_imported: result.alreadyImported,
  };
}

/**
 * Registers the `import_review` tool, which stores a completed code review locally in
 * PRDashboard as a `pr.review` run with line-anchored findings. This never submits a
 * GitHub review or comment; the `importer` is injected so callers (and tests) can swap
 * out the real Unix-socket client for a stub.
 */
export function registerImportReviewTool(server: McpServer, importer: ImportReviewImporter): void {
  server.registerTool(
    "import_review",
    {
      title: "Import a code review into PRDashboard",
      description:
        "Store a completed code review locally in PRDashboard as a pr.review run with " +
        "line-anchored findings. This never submits a GitHub review or comment \u2014 it only " +
        "persists data for PRDashboard's local UI and MCP read tools.",
      inputSchema: importReviewInputShape,
      outputSchema: importReviewOutputShape,
      annotations: {
        title: "Import a code review into PRDashboard",
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async (input: ImportReviewInput) => {
      const request = toSocketRequest(input);
      const result = await importer(request);
      const structuredContent = toStructuredOutput(result);
      return {
        content: [
          {
            type: "text" as const,
            text: JSON.stringify(structuredContent, null, 2),
          },
        ],
        structuredContent,
      };
    },
  );
}
