#!/usr/bin/env bash
set -euo pipefail

# Gates production promotion on a genuinely successful staging smoke test for this exact
# image_tag - a plausible-looking tag input must not be able to bypass this.
#
# image_tag IS ${GITHUB_SHA::7} of whatever commit build-image built it from (see
# events-service-ci.yml) - not a heuristic label, an exact, deterministic function of the commit.
# So finding "the run that built this tag" is exactly "the events-service-ci.yml run on main
# whose headSha starts with this value" - no artifact inspection or tag-to-commit lookup needed,
# the correspondence is already exact by construction.
#
# Confidence note: the specific risk here was whether a job that failed once and was later
# re-run successfully (exactly what happened twice tonight, real precedent) would be missed by a
# naive query. Verified empirically against that real history, not assumed: `gh run view <id>
# --json jobs` (no filter param - this is the same as the REST API's default, undocumented as
# the literal word "default" but confirmed via a live call to return only the latest attempt per
# job) returned run_attempt 2 / conclusion "success" for a job whose FIRST attempt had failed -
# the stale failure never appeared. So this script's core mechanism is verified against real
# data, not just plausible in theory.
#
# What's NOT independently re-verified, and worth being explicit about: the --limit 100 lookback
# window below. If more than 100 events-service-ci.yml runs on main have happened since the
# target commit, this will report "not found" even though a real successful run exists further
# back - a false negative (blocks a valid promotion), never a false positive (never approves an
# unverified one). Given this repo's actual push cadence that's a generous window, but it's a
# real, stated bound, not an unconditional guarantee.

IMAGE_TAG="${IMAGE_TAG:?IMAGE_TAG must be set}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

if ! [[ "$IMAGE_TAG" =~ ^[0-9a-f]{7}$ ]]; then
  echo "::error::image_tag '${IMAGE_TAG}' doesn't look like a short SHA (expected 7 lowercase hex characters) - refusing to promote an unverified artifact"
  exit 1
fi

echo "Searching recent events-service-ci.yml runs on main for a commit matching ${IMAGE_TAG}..."

# --status completed: an in-progress/queued run can't have a successful smoke-test-staging job
# yet anyway, no point checking it.
RUNS=$(gh run list --repo "$REPO" --workflow=events-service-ci.yml --branch=main \
  --status completed --json databaseId,headSha --limit 100)

MATCHING_RUN_IDS=$(echo "$RUNS" | jq -r --arg tag "$IMAGE_TAG" '.[] | select(.headSha | startswith($tag)) | .databaseId')

if [ -z "$MATCHING_RUN_IDS" ]; then
  echo "::error::no verified staging smoke test found for tag ${IMAGE_TAG} - refusing to promote an unverified artifact (no completed events-service-ci.yml run on main in the last 100 matched this commit)"
  exit 1
fi

# Rare in practice (a commit SHA maps to at most one push in the ordinary case), but handled
# defensively: check every matching run, not just the first, and accept any one of them having a
# genuinely successful smoke test.
FOUND_SUCCESS=false
for RUN_ID in $MATCHING_RUN_IDS; do
  echo "Checking run ${RUN_ID}..."
  JOB_CONCLUSION=$(gh run view "$RUN_ID" --repo "$REPO" --json jobs \
    | jq -r '.jobs[] | select(.name == "Smoke Test (staging)") | .conclusion')
  echo "  Smoke Test (staging) conclusion: ${JOB_CONCLUSION:-<job not found in this run>}"
  if [ "$JOB_CONCLUSION" = "success" ]; then
    FOUND_SUCCESS=true
    echo "Verified: run ${RUN_ID} has a successful Smoke Test (staging) job for image tag ${IMAGE_TAG}."
    break
  fi
done

if [ "$FOUND_SUCCESS" != "true" ]; then
  echo "::error::no verified staging smoke test found for tag ${IMAGE_TAG} - refusing to promote an unverified artifact (found a matching commit, but no run of it has a successful Smoke Test (staging) job)"
  exit 1
fi

echo "Gate passed: image tag ${IMAGE_TAG} has a genuinely successful staging smoke test."
