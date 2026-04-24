import { FAILURE_PATTERN } from "./failure-pattern.ts";

const ISO_TIMESTAMP = /\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?\b/g;
const UUID = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi;
const FILE_PATH = /[A-Za-z0-9_./-]+\.(?:ts|js|go|py|rb|swift|rs|c|cpp|h|java|lua)(?::\d+)*/gi;
const IP_ADDRESS = /\b\d{1,3}(?:\.\d{1,3}){3}\b/g;
const HEX_HASH = /\b[0-9a-f]{7,}\b/gi;
const LONG_NUMBER = /\b\d{3,}\b/g;

function normalizeSignatureLine(line: string): string {
  return line
    .trim()
    .replace(ISO_TIMESTAMP, "<TS>")
    .replace(UUID, "<UUID>")
    .replace(FILE_PATH, "<FILE>")
    .replace(IP_ADDRESS, "<IP>")
    .replace(HEX_HASH, "<HEX>")
    .replace(LONG_NUMBER, "<N>")
    .slice(0, 200);
}

export function extractSignature(log: string): string {
  const lines = log.split("\n");
  const errorLine = lines.find((line) => FAILURE_PATTERN.test(line));
  if (errorLine !== undefined) return normalizeSignatureLine(errorLine);

  for (let i = lines.length - 1; i >= 0; i -= 1) {
    const line = lines[i];
    if (line !== undefined && line.trim() !== "") {
      return normalizeSignatureLine(line);
    }
  }
  return "";
}
