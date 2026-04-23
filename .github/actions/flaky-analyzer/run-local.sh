#!/usr/bin/env bash
# Run the flaky-analyzer against a real PR/run without a GitHub Actions runner.
# Reads config from ./.env (git-ignored) or from the environment.
#
# Required env:
#   TARGET_REPO    owner/repo of the repo whose PR/run you want to analyze
#   PR_NUMBER      PR number on that repo
#   RUN_ID         Failed workflow run id on that PR's head
#   COPILOT_PAT    Fine-grained PAT with "Copilot Requests" permission
#
# Optional env:
#   HEAD_SHA           Defaults to PR.head.sha resolved via gh
#   GITHUB_TOKEN       Defaults to `gh auth token`; needs actions:read on TARGET_REPO
#   DRY_RUN            Default "true" — skips Check Run + PR comment writes
#   WRITE_PR_COMMENT   Default "false"
#   JOB_IDS            Comma-separated failed job ids (empty = all)
#   TRIGGER            Default "local"
#   SCHEMA_VERSION     Default "2"
#   CORRELATION_ID     Echoed in result_json
#   REQUEST_ID         Echoed in result_json; defaults to correlation id / run-<id>
#   WORK_DIR           Default <action_dir>/.local-run
set -euo pipefail

ACTION_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ACTION_DIR"

if [[ -f "$ACTION_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ACTION_DIR/.env"
  set +a
fi

: "${TARGET_REPO:?set TARGET_REPO=owner/repo (see .env.example)}"
: "${PR_NUMBER:?set PR_NUMBER}"
: "${RUN_ID:?set RUN_ID (failed workflow run id)}"
: "${COPILOT_PAT:?set COPILOT_PAT (fine-grained PAT with Copilot Requests)}"

GITHUB_TOKEN_VALUE="${GITHUB_TOKEN:-$(gh auth token)}"
DRY_RUN="${DRY_RUN:-true}"
WRITE_PR_COMMENT="${WRITE_PR_COMMENT:-false}"
WORK_DIR="${WORK_DIR:-$ACTION_DIR/.local-run}"
PR_CODE_DIR="$WORK_DIR/pr-code"

echo "==> target=$TARGET_REPO pr=$PR_NUMBER run=$RUN_ID dry_run=$DRY_RUN write_pr_comment=$WRITE_PR_COMMENT"

if [[ -z "${HEAD_SHA:-}" ]]; then
  HEAD_SHA="$(gh api "repos/$TARGET_REPO/pulls/$PR_NUMBER" --jq .head.sha)"
  echo "==> resolved head_sha=$HEAD_SHA"
fi

if [[ ! -d "$ACTION_DIR/node_modules" ]]; then
  echo "==> bun install"
  bun install --frozen-lockfile
fi

mkdir -p "$WORK_DIR"
if [[ -d "$PR_CODE_DIR/.git" ]]; then
  EXISTING_ORIGIN="$(git -C "$PR_CODE_DIR" remote get-url origin 2>/dev/null || true)"
  if [[ "$EXISTING_ORIGIN" != *"$TARGET_REPO"* ]]; then
    echo "==> $PR_CODE_DIR points at a different repo ($EXISTING_ORIGIN); re-cloning"
    rm -rf "$PR_CODE_DIR"
  fi
fi
if [[ ! -d "$PR_CODE_DIR/.git" ]]; then
  echo "==> cloning $TARGET_REPO -> $PR_CODE_DIR"
  rm -rf "$PR_CODE_DIR"
  git clone --depth 1 "https://github.com/$TARGET_REPO.git" "$PR_CODE_DIR"
fi
echo "==> fetching pull/$PR_NUMBER/head"
git -C "$PR_CODE_DIR" fetch --depth 1 origin "pull/$PR_NUMBER/head"
git -C "$PR_CODE_DIR" -c advice.detachedHead=false checkout -q FETCH_HEAD

ACTUAL_HEAD="$(git -C "$PR_CODE_DIR" rev-parse HEAD)"
if [[ "$ACTUAL_HEAD" != "$HEAD_SHA" ]]; then
  echo "!! head mismatch: checkout=$ACTUAL_HEAD expected=$HEAD_SHA"
  echo "   PR may have been updated — unset HEAD_SHA in .env and re-run to refetch."
  exit 1
fi

OUTPUT_FILE="$WORK_DIR/gha-output.txt"
SUMMARY_FILE="$WORK_DIR/gha-summary.md"
: > "$OUTPUT_FILE"
: > "$SUMMARY_FILE"

echo "==> running analyzer"
GITHUB_REPOSITORY="$TARGET_REPO" \
GITHUB_SERVER_URL="https://github.com" \
GITHUB_OUTPUT="$OUTPUT_FILE" \
GITHUB_STEP_SUMMARY="$SUMMARY_FILE" \
GITHUB_TOKEN="$GITHUB_TOKEN_VALUE" \
COPILOT_GITHUB_TOKEN="$COPILOT_PAT" \
INPUT_SCHEMA_VERSION="${SCHEMA_VERSION:-2}" \
INPUT_REQUEST_ID="${REQUEST_ID:-}" \
INPUT_PR_NUMBER="$PR_NUMBER" \
INPUT_HEAD_SHA="$HEAD_SHA" \
INPUT_RUN_ID="$RUN_ID" \
INPUT_JOB_IDS="${JOB_IDS:-}" \
INPUT_TRIGGER="${TRIGGER:-local}" \
INPUT_PR_CODE_DIR="$PR_CODE_DIR" \
INPUT_CORRELATION_ID="${CORRELATION_ID:-}" \
INPUT_WRITE_PR_COMMENT="$WRITE_PR_COMMENT" \
INPUT_DRY_RUN="$DRY_RUN" \
ACTION_PATH="$ACTION_DIR" \
bun run src/index.ts

echo ""
echo "==> GHA step outputs ($OUTPUT_FILE):"
cat "$OUTPUT_FILE"
echo ""
echo "==> job summary ($SUMMARY_FILE):"
cat "$SUMMARY_FILE"
