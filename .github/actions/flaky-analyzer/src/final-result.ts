import * as fs from "node:fs";
import * as path from "node:path";
import type { FlakyCIAnalysisResultV2 } from "./protocol-v2.ts";

export const FINAL_RESULT_FILENAME = "final-result.json";

export function writeFinalResult(ioDir: string, result: FlakyCIAnalysisResultV2): void {
  fs.writeFileSync(
    path.join(ioDir, FINAL_RESULT_FILENAME),
    `${JSON.stringify(result, null, 2)}\n`,
  );
}
