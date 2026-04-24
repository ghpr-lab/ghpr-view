import { describe, expect, test } from "bun:test";
import { sliceAroundFailure, tailTruncate } from "./logs.ts";

describe("tailTruncate", () => {
  test("returns input unchanged when within budget", () => {
    expect(tailTruncate("small log", 1000)).toBe("small log");
  });

  test("keeps the tail when input exceeds budget", () => {
    const big = `${"pad line\n".repeat(200)}tail marker`;
    const out = tailTruncate(big, 100);
    expect(out.startsWith("… (truncated, showing last 100 bytes)")).toBe(true);
    expect(out.endsWith("tail marker")).toBe(true);
  });
});

describe("sliceAroundFailure", () => {
  test("returns input unchanged when within budget", () => {
    expect(sliceAroundFailure("small log", 1000)).toBe("small log");
  });

  test("keeps the failure line and surrounding context", () => {
    const prelude = `${"setup noise line\n".repeat(500)}`;
    const failure = "FAIL spec/foo.ts:10 expected 3 got 2\n";
    const postlude = `${"cleanup noise line\n".repeat(500)}`;
    const input = prelude + failure + postlude;

    const out = sliceAroundFailure(input, 4000);

    expect(out).toContain("FAIL spec/foo.ts:10 expected 3 got 2");
    expect(out.length).toBeLessThan(input.length);
    expect(out).toContain("bytes elided");
  });

  test("falls back to tail truncation when no failure found", () => {
    const big = `${"mundane line\n".repeat(500)}tail marker`;
    const out = sliceAroundFailure(big, 200);
    expect(out.startsWith("… (truncated, showing last 200 bytes)")).toBe(true);
    expect(out.endsWith("tail marker")).toBe(true);
  });

  test("does not anchor on pipefail banner", () => {
    const prelude = "shell: /usr/bin/bash --noprofile --norc -e -o pipefail {0}\n";
    const middle = `${"setup noise\n".repeat(1000)}`;
    const failure = "FAIL spec/foo.ts:42 expected X got Y\n";
    const postlude = `${"trailing noise\n".repeat(200)}`;
    const input = prelude + middle + failure + postlude;

    const out = sliceAroundFailure(input, 3000);
    expect(out).toContain("FAIL spec/foo.ts:42 expected X got Y");
  });
});
