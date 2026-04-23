const FAILURE_PATTERN = /\b(?:Error|FAIL(?:ED|URE)?|panic|Exception|fatal)\b/i;

export function tailTruncate(input: string, maxBytes: number): string {
  const buf = Buffer.from(input, "utf8");
  if (buf.length <= maxBytes) return input;
  const trimmed = buf.subarray(buf.length - maxBytes).toString("utf8");
  // Drop a potentially mangled first line from the cut boundary.
  const firstNewline = trimmed.indexOf("\n");
  const cleaned = firstNewline >= 0 ? trimmed.slice(firstNewline + 1) : trimmed;
  return `… (truncated, showing last ${maxBytes} bytes)\n${cleaned}`;
}

// Keep a window around the first failure-like line when the log exceeds
// maxBytes. Falls back to tailTruncate when no failure line is found.
export function sliceAroundFailure(input: string, maxBytes: number): string {
  const buf = Buffer.from(input, "utf8");
  if (buf.length <= maxBytes) return input;

  const match = input.match(FAILURE_PATTERN);
  if (!match || match.index === undefined) return tailTruncate(input, maxBytes);

  const failByte = Buffer.byteLength(input.slice(0, match.index), "utf8");
  const beforeBudget = Math.floor(maxBytes * 0.3);
  const afterBudget = maxBytes - beforeBudget;

  let start = Math.max(0, failByte - beforeBudget);
  let end = Math.min(buf.length, failByte + afterBudget);
  // Rebalance if one side is clipped.
  if (start === 0) end = Math.min(buf.length, end + (beforeBudget - failByte));
  if (end === buf.length) start = Math.max(0, start - (afterBudget - (buf.length - failByte)));

  let slice = buf.subarray(start, end).toString("utf8");
  if (start > 0) {
    const nl = slice.indexOf("\n");
    if (nl >= 0) slice = slice.slice(nl + 1);
  }
  if (end < buf.length) {
    const nl = slice.lastIndexOf("\n");
    if (nl >= 0) slice = slice.slice(0, nl);
  }

  const head = start > 0 ? `… (${start} bytes elided before first failure)\n` : "";
  const tail = end < buf.length ? `\n… (${buf.length - end} bytes elided after)` : "";
  return `${head}${slice}${tail}`;
}
