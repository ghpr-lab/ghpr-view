export function tailTruncate(input: string, maxBytes: number): string {
  const buf = Buffer.from(input, "utf8");
  if (buf.length <= maxBytes) return input;
  const trimmed = buf.subarray(buf.length - maxBytes).toString("utf8");
  // Drop a potentially mangled first line from the cut boundary.
  const firstNewline = trimmed.indexOf("\n");
  const cleaned = firstNewline >= 0 ? trimmed.slice(firstNewline + 1) : trimmed;
  return `… (truncated, showing last ${maxBytes} bytes)\n${cleaned}`;
}
