// Word-boundary-safe pattern for "this line looks like a failure."
//
// The negative lookbehind/-ahead on `[-\w]` is what separates a real failure
// keyword from package-install noise: `libgpg-error (1.47-r2)` would match a
// plain `\berror\b` because `-` is a non-word char, but `(?<![-\w])` rejects
// the hyphen-joined form while still accepting `Error:`, `SyntaxError`,
// `TypeError`, etc. via the optional `\w*` prefix on the Error branch.
export const FAILURE_PATTERN =
  /(?<![-\w])(?:\w*Error|FAIL(?:ED|URE)?|panic|Exception|fatal)(?![-\w])/i;
