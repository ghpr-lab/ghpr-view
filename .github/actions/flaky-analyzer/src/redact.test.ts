import { describe, expect, test } from "bun:test";
import { redactSecrets } from "./redact.ts";

describe("redactSecrets", () => {
  test("redacts GitHub token prefixes and fine-grained PATs", () => {
    const classic = `ghp_${"a".repeat(36)}`;
    const fineGrained = `github_pat_${"A".repeat(82)}`;

    expect(redactSecrets(`${classic} ${fineGrained}`)).toBe("<REDACTED> <REDACTED>");
  });

  test("redacts AWS access keys and secret access keys", () => {
    const accessKey = "AKIA1234567890ABCDEF";
    const secret = `aws_secret_access_key=${"a".repeat(40)}`;

    expect(redactSecrets(`${accessKey}\n${secret}`)).toBe("<REDACTED>\n<REDACTED>");
  });

  test("redacts bearer tokens", () => {
    expect(redactSecrets("Authorization: Bearer abc.def_ghi-jklmnopqrstuvwxyz")).toBe(
      "Authorization: <REDACTED>",
    );
  });

  test("redacts basic-auth URL credentials", () => {
    expect(redactSecrets("clone https://user:pass@example.com/repo.git")).toBe(
      "clone <REDACTED>example.com/repo.git",
    );
  });

  test("redacts ngrok URLs", () => {
    expect(redactSecrets("callback foo-bar.ngrok-free.app ready")).toBe(
      "callback <REDACTED> ready",
    );
  });

  test("redacts uppercase secret assignments while preserving the key name", () => {
    expect(redactSecrets("GITHUB_TOKEN=ghs_notlongenough OTHER_SECRET:super-secret")).toBe(
      "GITHUB_TOKEN=<REDACTED> OTHER_SECRET=<REDACTED>",
    );
  });
});
