#!/usr/bin/env bash
set -euo pipefail

WORKFLOW_FILE="${WORKFLOW_FILE:?WORKFLOW_FILE must be set}"
SMOKE_TEST_JOB_NAME="${SMOKE_TEST_JOB_NAME:?SMOKE_TEST_JOB_NAME must be set}"
TAG_SOURCE="${TAG_SOURCE:?TAG_SOURCE must be set (head_sha or artifact)}"
ARTIFACT_NAME="${ARTIFACT_NAME:-}"
LOOKBACK_LIMIT="${LOOKBACK_LIMIT:-10}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

if [ "$TAG_SOURCE" != "head_sha" ] && [ "$TAG_SOURCE" != "artifact" ]; then
  echo "::error::TAG_SOURCE must be 'head_sha' or 'artifact', got '${TAG_SOURCE}'"
  exit 1
fi
if [ "$TAG_SOURCE" = "artifact" ] && [ -z "$ARTIFACT_NAME" ]; then
  echo "::error::ARTIFACT_NAME must be set when TAG_SOURCE=artifact"
  exit 1
fi

# Only used in artifact mode - reads image_tag out of a run's own evidence artifact. Echoes
# nothing (not even an empty line) on any failure, so the caller's [ -z "$TAG" ] check catches
# it cleanly rather than treating a stray blank line as a value.
read_tag_from_artifact() {
  local run_id="$1"
  local artifact_id
  artifact_id=$(gh api "repos/${REPO}/actions/runs/${run_id}/artifacts" \
    --jq ".artifacts[] | select(.name == \"${ARTIFACT_NAME}\") | .id" 2>/dev/null | head -1)
  if [ -z "$artifact_id" ]; then
    return
  fi
  local tmpdir
  tmpdir=$(mktemp -d)
  if ! gh api "repos/${REPO}/actions/artifacts/${artifact_id}/zip" > "${tmpdir}/evidence.zip" 2>/dev/null; then
    rm -rf "$tmpdir"
    return
  fi
  if ! unzip -o -q "${tmpdir}/evidence.zip" -d "$tmpdir" 2>/dev/null; then
    rm -rf "$tmpdir"
    return
  fi
  if [ -f "${tmpdir}/summary.json" ]; then
    jq -r '.image_tag // empty' "${tmpdir}/summary.json"
  fi
  rm -rf "$tmpdir"
}

echo "Searching the ${LOOKBACK_LIMIT} most recent completed runs of ${WORKFLOW_FILE} for the most recent genuinely successful '${SMOKE_TEST_JOB_NAME}'..."

RUNS_JSON=$(gh run list --repo "$REPO" --workflow="$WORKFLOW_FILE" --status completed \
  --json databaseId,headSha --limit "$LOOKBACK_LIMIT")

RUN_IDS=$(echo "$RUNS_JSON" | jq -r '.[].databaseId')

if [ -z "$RUN_IDS" ]; then
  echo "::error::No completed runs of ${WORKFLOW_FILE} found at all - refusing to attempt an automatic rollback."
  exit 1
fi

for RUN_ID in $RUN_IDS; do
  echo "Checking run ${RUN_ID}..."
  JOB_CONCLUSION=$(gh run view "$RUN_ID" --repo "$REPO" --json jobs \
    | jq -r --arg name "$SMOKE_TEST_JOB_NAME" '.jobs[] | select(.name == $name) | .conclusion')

  if [ "$JOB_CONCLUSION" != "success" ]; then
    echo "  '${SMOKE_TEST_JOB_NAME}': ${JOB_CONCLUSION:-<not found in this run>} - skipping"
    continue
  fi
  echo "  '${SMOKE_TEST_JOB_NAME}': success"

  if [ "$TAG_SOURCE" = "head_sha" ]; then
    TAG=$(echo "$RUNS_JSON" | jq -r --argjson id "$RUN_ID" '.[] | select(.databaseId == $id) | .headSha[0:7]')
  else
    TAG=$(read_tag_from_artifact "$RUN_ID")
  fi

  if [ -z "$TAG" ]; then
    echo "  Could not resolve an image tag for run ${RUN_ID} - skipping"
    continue
  fi

  echo "Rollback target found: run ${RUN_ID}, tag ${TAG}"
  echo "rollback_tag=${TAG}" >> "$GITHUB_OUTPUT"
  echo "rollback_run_id=${RUN_ID}" >> "$GITHUB_OUTPUT"
  exit 0
done

echo "::error::No genuinely successful '${SMOKE_TEST_JOB_NAME}' found in the last ${LOOKBACK_LIMIT} completed ${WORKFLOW_FILE} runs - refusing to attempt an automatic rollback. This means something is systemically wrong and needs human investigation, not an automated action."
exit 1
