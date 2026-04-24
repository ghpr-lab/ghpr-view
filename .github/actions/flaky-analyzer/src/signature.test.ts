import { describe, expect, test } from "bun:test";
import { extractSignature } from "./signature.ts";

describe("extractSignature", () => {
  test("selects the first error-like line", () => {
    const log = [
      "setup complete",
      "WARN retrying",
      "panic: database crashed at worker.go:123",
      "Error: later failure",
    ].join("\n");

    expect(extractSignature(log)).toBe("panic: database crashed at <FILE>");
  });

  test("falls back to the last non-blank line", () => {
    expect(extractSignature("first line\n\ncompleted with exit code 123\n")).toBe(
      "completed with exit code <N>",
    );
  });

  test("returns empty string for genuinely empty logs", () => {
    expect(extractSignature(" \n\t\n")).toBe("");
  });

  test("normalizes unstable values", () => {
    const log =
      "2026-04-23T12:34:56.789Z Error in /tmp/work/src/App.swift:1234 uuid 123e4567-e89b-12d3-a456-426614174000 hash deadbeef42 ip 10.20.30.40 build 987654";

    expect(extractSignature(log)).toBe(
      "<TS> Error in <FILE> uuid <UUID> hash <HEX> ip <IP> build <N>",
    );
  });

  test("is stable across reruns with different paths, hashes, and numbers", () => {
    const first =
      "FAIL /home/runner/work/app/src/foo.ts:123 expected 200 got 500 commit abcdef123456";
    const second =
      "FAIL /tmp/build/src/foo.ts:987 expected 201 got 503 commit 0123456789ab";

    expect(extractSignature(first)).toBe(extractSignature(second));
  });

  test("truncates long signatures to 200 chars", () => {
    const signature = extractSignature(`Error: ${"x".repeat(500)}`);

    expect(signature.length).toBe(200);
  });

  test("does not match 'fail' embedded in words like pipefail", () => {
    const log = [
      "shell: /usr/bin/bash --noprofile --norc -e -o pipefail {0}",
      "setup complete",
      "FAIL spec/foo.ts:10 expected 3 got 2",
    ].join("\n");

    expect(extractSignature(log)).toBe("FAIL <FILE> expected 3 got 2");
  });

  test("matches FAILED and FAILURE as standalone words", () => {
    expect(extractSignature("setup ok\nFAILED spec/bar.go:42")).toBe("FAILED <FILE>");
    expect(extractSignature("setup ok\nFAILURE: boom")).toBe("FAILURE: boom");
  });
});
