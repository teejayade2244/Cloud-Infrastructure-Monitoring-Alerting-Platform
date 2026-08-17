#!/usr/bin/env bash
set -euo pipefail

# Shared by rollback-staging (events-service-ci.yml) and rollback-production
# (events-service-production-promotion.yml) - walks backward through the most recent completed
# runs of a workflow, most recent first, looking for the first one whose smoke test job
# genuinely succeeded. This is NOT "one commit prior" - it's "the most recent deployment that
# was itself actually verified," which can be several commits back if intervening ones broke
# something. If nothing verified-good turns up within the lookback window, this fails loudly and
# writes no output - a rollback target that can't be verified must never be guessed at.
#
# Uses the exact same gh run list / gh run view --json jobs query mechanism as
# verify-staging-smoke-test.sh, including the same reliance on the jobs endpoint's default
# (no filter param) behavior of returning a job's LATEST attempt - empirically verified earlier
# tonight against a run that genuinely failed once and was later re-run to success, where the
# default query correctly surfaced the success, never the stale failure.
#
# Where staging and production genuinely differ (not just parameters, a different mechanism):
# a staging run is push-triggered, so its image tag IS ${headSha::7} - exact by construction,
# same correspondence verify-staging-smoke-test.sh already relies on. A production run is
# workflow_dispatch-triggered with image_tag as a manual input; empirically confirmed (checked
# the full run object, and gh run view's complete --json field list) that GitHub's Actions API
# exposes NO input-value field for a completed run at all - head_sha there is just whatever
# commit main was on at dispatch time, unrelated to the promoted tag. So for production, the
# tag is instead read from the smoke-test-evidence-production artifact's summary.json that
# Smoke Test (production) already uploads - confirmed empirically against a real run, not
# assumed - since that's the only reliable record of which tag a given run actually tested.

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
