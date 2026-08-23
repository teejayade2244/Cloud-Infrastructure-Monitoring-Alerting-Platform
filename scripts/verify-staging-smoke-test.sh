#!/usr/bin/env bash
set -euo pipefail

# Gates production promotion on a genuinely successful staging smoke test for this exact
# image_tag - a plausible-looking tag input must not be able to bypass this.
#
# image_tag IS ${GITHUB_SHA::7} of whatever commit build-image built it from (see
# <service>-ci.yml) - not a heuristic label, an exact, deterministic function of the commit. So
# finding "the run that built this tag" is exactly "the WORKFLOW_FILE run on main whose headSha
# starts with this value" - no artifact inspection or tag-to-commit lookup needed, the
# correspondence is already exact by construction.
#
# WORKFLOW_FILE defaults to events-service-ci.yml so events-service-production-promotion.yml's
# existing call (which doesn't set it) keeps working unchanged - shared by any service's
# production-promotion workflow, one per CI workflow it needs to verify against.

IMAGE_TAG="${IMAGE_TAG:?IMAGE_TAG must be set}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
WORKFLOW_FILE="${WORKFLOW_FILE:-events-service-ci.yml}"
# Was hardcoded "Smoke Test (staging)" until a real production-promotion run failed against it -
# once smoke-test-staging started running inside a reusable workflow_call template, GitHub Actions
# reports its name as "<calling job id> / Smoke Test (staging)", not the bare job name. Same fix
# find-rollback-target.sh's SMOKE_TEST_JOB_NAME already needed for the same reason.
SMOKE_TEST_JOB_NAME="${SMOKE_TEST_JOB_NAME:-Smoke Test (staging)}"

if ! [[ "$IMAGE_TAG" =~ ^[0-9a-f]{7}$ ]]; then
  echo "::error::image_tag '${IMAGE_TAG}' doesn't look like a short SHA (expected 7 lowercase hex characters) - refusing to promote an unverified artifact"
  exit 1
fi

echo "Searching recent ${WORKFLOW_FILE} runs on main for a commit matching ${IMAGE_TAG}..."

# --status completed: an in-progress/queued run can't have a successful smoke-test-staging job
# yet anyway, no point checking it.
RUNS=$(gh run list --repo "$REPO" --workflow="$WORKFLOW_FILE" --branch=main \
  --status completed --json databaseId,headSha --limit 100)

MATCHING_RUN_IDS=$(echo "$RUNS" | jq -r --arg tag "$IMAGE_TAG" '.[] | select(.headSha | startswith($tag)) | .databaseId')

if [ -z "$MATCHING_RUN_IDS" ]; then
  echo "::error::no verified staging smoke test found for tag ${IMAGE_TAG} - refusing to promote an unverified artifact (no completed ${WORKFLOW_FILE} run on main in the last 100 matched this commit)"
  exit 1
fi

# Rare in practice (a commit SHA maps to at most one push in the ordinary case), but handled
# defensively: check every matching run, not just the first, and accept any one of them having a
# genuinely successful smoke test.
FOUND_SUCCESS=false
for RUN_ID in $MATCHING_RUN_IDS; do
  echo "Checking run ${RUN_ID}..."
  JOB_CONCLUSION=$(gh run view "$RUN_ID" --repo "$REPO" --json jobs \
    | jq -r --arg name "$SMOKE_TEST_JOB_NAME" '.jobs[] | select(.name == $name) | .conclusion')
  echo "  ${SMOKE_TEST_JOB_NAME} conclusion: ${JOB_CONCLUSION:-<job not found in this run>}"
  if [ "$JOB_CONCLUSION" = "success" ]; then
    FOUND_SUCCESS=true
    echo "Verified: run ${RUN_ID} has a successful ${SMOKE_TEST_JOB_NAME} job for image tag ${IMAGE_TAG}."
    break
  fi
done

if [ "$FOUND_SUCCESS" != "true" ]; then
  echo "::error::no verified staging smoke test found for tag ${IMAGE_TAG} - refusing to promote an unverified artifact (found a matching commit, but no run of it has a successful ${SMOKE_TEST_JOB_NAME} job)"
  exit 1
fi

echo "Gate passed: image tag ${IMAGE_TAG} has a genuinely successful staging smoke test."
