const SECRET_PATTERNS: RegExp[] = [
  /gh[pousr]_[A-Za-z0-9]{36}/g,
  /github_pat_[A-Za-z0-9_]{82}/g,
  /AKIA[0-9A-Z]{16}/g,
  /aws_secret_access_key\s*[:=]\s*[A-Za-z0-9/+=]{40}/gi,
  /Bearer\s+[A-Za-z0-9._-]{20,}/g,
  /https?:\/\/[^:\s/]+:[^@\s/]+@/g,
  /[a-zA-Z0-9._-]+\.(?:[a-zA-Z0-9-]+\.)?ngrok(?:-free)?\.app/g,
];

const SECRET_ASSIGNMENT = /\b([A-Z_]+(?:TOKEN|SECRET|KEY))\s*[:=]\s*\S+/g;

export function redactSecrets(s: string): string {
  let out = s;
  for (const pattern of SECRET_PATTERNS) {
    out = out.replace(pattern, "<REDACTED>");
  }
  return out.replace(SECRET_ASSIGNMENT, (_match, name: string) => `${name}=<REDACTED>`);
}
