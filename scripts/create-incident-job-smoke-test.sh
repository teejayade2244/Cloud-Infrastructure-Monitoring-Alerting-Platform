#!/usr/bin/env bash
set -euo pipefail
NAMESPACE="${NAMESPACE:-inframonitor}"
ARGOCD_APP_NAME="${ARGOCD_APP_NAME:-create-incident-job-staging}"
ENVIRONMENT_LABEL="${ENVIRONMENT_LABEL:-staging}"
SERVICE_NAME="${SERVICE_NAME:-create-incident-job}"

if [ "$SERVICE_NAME" != "create-incident-job" ]; then
  echo "::error::SERVICE_NAME must be 'create-incident-job', got '${SERVICE_NAME}' - no verification logic defined for it"
  exit 1
fi

# Fixed across both environments - one Cosmos account, one Service Bus namespace for the whole
# project (confirmed against charts/create-incident-job/values-staging.yaml and
# values-production.yaml in inframonitor-gitops). Only the database/topic/subscription names
# actually split by environment, same as the real job's own env vars do at runtime.
COSMOS_ENDPOINT="https://inframonitor-aks-cosmos-eastus2.documents.azure.com:443/"
SERVICEBUS_NAMESPACE="inframonitor-aks-svcbus.servicebus.windows.net"
if [ "$ENVIRONMENT_LABEL" = "production" ]; then
  COSMOS_DATABASE="InfraMonitorProdDB"
  SERVICEBUS_TOPIC="infrastructure-events-prod"
else
  COSMOS_DATABASE="InfraMonitorDB"
  SERVICEBUS_TOPIC="infrastructure-events"
fi
export COSMOS_ENDPOINT COSMOS_DATABASE SERVICEBUS_NAMESPACE SERVICEBUS_TOPIC

EVIDENCE_DIR="smoke-test-evidence"
mkdir -p "$EVIDENCE_DIR"

# Scratch install, not a checkout of Microservices/functions/incident-function's own
# package.json - this script needs to run standalone, wired in purely via
# smoke_test_script_path, with no template or job-level npm-install step of its own. Versions
# match that project's real dependencies (package.json) for behavioral consistency, not lifted
# from it mechanically. Neither `az servicebus`/`az cosmosdb` CLI extensions support real
# message send or item-level document CRUD (management-plane only) - an SDK is the only way to
# do either from a script, matching how this whole service is already implemented in Node.
NODE_SCRATCH_DIR=$(mktemp -d)

cleanup() {
  local exit_code=$?
  if [ -n "${INCIDENT_ID:-}" ] && [ -n "${INCIDENT_SEVERITY:-}" ]; then
    echo "Cleaning up smoke-test incident ${INCIDENT_ID}..."
    if node "$NODE_SCRATCH_DIR/delete-incident.js" >"$EVIDENCE_DIR/cleanup-response.json" 2>&1; then
      CLEANUP_STATUS="deleted"
      echo "Cleanup succeeded for ${INCIDENT_ID}"
    else
      CLEANUP_STATUS="failed"
      echo "::warning::Cleanup failed for ${INCIDENT_ID} (source=${TEST_SOURCE:-unknown}) - may need manual attention"
    fi
  fi
  # Written unconditionally, from whatever variables happen to be set at this point - on a
  # failed run that's a partial snapshot (e.g. "ArgoCD refresh sent, but the ScaledJob never
  # picked up the new tag"), which is exactly what's useful for debugging a failure after the
  # runner is gone. Same reasoning and shape as scripts/smoke-test.sh's own summary.json.
  jq -n \
    --arg run_id "${GITHUB_RUN_ID:-manual}" \
    --arg service "$SERVICE_NAME" \
    --arg environment "$ENVIRONMENT_LABEL" \
    --arg namespace "$NAMESPACE" \
    --arg image_tag "${EXPECTED_TAG:-}" \
    --arg job_name "${JOB_NAME:-}" \
    --arg message_source "${TEST_SOURCE:-}" \
    --arg incident_id "${INCIDENT_ID:-}" \
    --arg cleanup_status "${CLEANUP_STATUS:-}" \
    --arg result "$([ "$exit_code" -eq 0 ] && echo success || echo failure)" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{run_id: $run_id, service: $service, environment: $environment, namespace: $namespace, image_tag: $image_tag, job_name: $job_name, message_source: $message_source, incident_id: $incident_id, cleanup_status: $cleanup_status, result: $result, timestamp: $timestamp}' \
    > "$EVIDENCE_DIR/summary.json" 2>/dev/null || true
  rm -rf "$NODE_SCRATCH_DIR"
  exit "$exit_code"
}
trap cleanup EXIT

# --- Stage 1: confirm ArgoCD sync -------------------------------------------------------------
# Same reasoning as scripts/smoke-test.sh: ArgoCD polls Git every ~3 minutes by default, so a
# hard refresh makes this deterministic rather than a race against that cycle. Requires get+patch
# on this one named Application, granted via inframonitor-gitops's inframonitor-namespace chart
# (ci-argocd-refresh-rbac.yaml, extended for create-incident-job-smoke-identity).
kubectl patch application "$ARGOCD_APP_NAME" -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# create-incident-job is a KEDA ScaledJob, not a Deployment - there's no rollout/pod to wait on
# here, only the ScaledJob spec ArgoCD applies. Same polling shape as smoke-test.sh's Deployment
# check, targeting scaledjobs.keda.sh instead of apps/deployments.
TIMEOUT=60
INTERVAL=10
ELAPSED=0
while true; do
  CURRENT_IMAGE=$(kubectl get scaledjob create-incident-job -n "$NAMESPACE" -o jsonpath='{.spec.jobTargetRef.template.spec.containers[0].image}' 2>/dev/null || true)
  CURRENT_TAG="${CURRENT_IMAGE##*:}"
  echo "Elapsed ${ELAPSED}s: ScaledJob image = ${CURRENT_IMAGE:-<none>}"
  if [ "$CURRENT_TAG" = "$EXPECTED_TAG" ]; then
    echo "ScaledJob now references image tag ${EXPECTED_TAG}"
    break
  fi
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "::error::Timed out after ${TIMEOUT}s waiting for the create-incident-job ScaledJob in namespace ${NAMESPACE} to reference image tag ${EXPECTED_TAG} (last seen: ${CURRENT_TAG:-<none>}). ArgoCD may not have synced yet, or the sync failed - check the ${ARGOCD_APP_NAME} Application in ArgoCD."
    exit 1
  fi
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

# --- Node SDK setup (Service Bus publish + Cosmos query/delete need a real SDK - see the note
# on NODE_SCRATCH_DIR above) -------------------------------------------------------------------
npm install --prefix "$NODE_SCRATCH_DIR" --no-save --silent \
  @azure/cosmos@^4.9.3 @azure/identity@^4.13.1 @azure/service-bus@^7.9.5

cat > "$NODE_SCRATCH_DIR/publish-message.js" <<'EOF'
const { ServiceBusClient } = require("@azure/service-bus")
const { DefaultAzureCredential } = require("@azure/identity")

async function main() {
  const credential = new DefaultAzureCredential({
    managedIdentityClientId: process.env.AZURE_CLIENT_ID || undefined,
    excludeInteractiveBrowserCredential: true,
  })
  const client = new ServiceBusClient(process.env.SERVICEBUS_NAMESPACE, credential, {
    transportType: "AmqpWebSockets",
  })
  const sender = client.createSender(process.env.SERVICEBUS_TOPIC)
  const body = JSON.parse(process.env.TEST_MESSAGE_BODY)
  try {
    await sender.sendMessages({ body, contentType: "application/json", subject: body.type })
  } finally {
    await sender.close()
    await client.close()
  }
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
EOF

cat > "$NODE_SCRATCH_DIR/find-incident.js" <<'EOF'
const { CosmosClient } = require("@azure/cosmos")
const { DefaultAzureCredential } = require("@azure/identity")

async function main() {
  const credential = new DefaultAzureCredential({
    managedIdentityClientId: process.env.AZURE_CLIENT_ID || undefined,
    excludeInteractiveBrowserCredential: true,
  })
  const client = new CosmosClient({
    endpoint: process.env.COSMOS_ENDPOINT,
    aadCredentials: credential,
  })
  const container = client.database(process.env.COSMOS_DATABASE).container("Incidents")

  const { resources } = await container.items
    .query({
      query: "SELECT * FROM c WHERE c.source = @source",
      parameters: [{ name: "@source", value: process.env.TEST_SOURCE }],
    })
    .fetchAll()

  if (resources.length === 0) {
    process.exit(1)
  }
  console.log(JSON.stringify(resources[0]))
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
EOF

cat > "$NODE_SCRATCH_DIR/delete-incident.js" <<'EOF'
const { CosmosClient } = require("@azure/cosmos")
const { DefaultAzureCredential } = require("@azure/identity")

async function main() {
  const credential = new DefaultAzureCredential({
    managedIdentityClientId: process.env.AZURE_CLIENT_ID || undefined,
    excludeInteractiveBrowserCredential: true,
  })
  const client = new CosmosClient({
    endpoint: process.env.COSMOS_ENDPOINT,
    aadCredentials: credential,
  })
  const container = client.database(process.env.COSMOS_DATABASE).container("Incidents")
  await container.item(process.env.INCIDENT_ID, process.env.INCIDENT_SEVERITY).delete()
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
EOF

# --- Stage 2: publish one synthetic message to the REAL topic --------------------------------
# The real topic/subscription this environment's create-incident-job actually consumes from -
# deliberately not the test-tier topic integration tests use, since this is proving the real
# deployed artifact's real Workload Identity against the real deployment path end to end, same
# reasoning scripts/smoke-test.sh already uses for writing to the real (not test) Cosmos DB.
TEST_SOURCE="ci-smoke-test-${GITHUB_RUN_ID:-manual}"
export TEST_SOURCE
TEST_MESSAGE_BODY=$(jq -n \
  --arg id "smoke-test-${GITHUB_RUN_ID:-manual}" \
  --arg environment "$ENVIRONMENT_LABEL" \
  --arg source "$TEST_SOURCE" \
  '{id: $id, type: "metric", environment: $environment, severity: "info", message: "CI smoke test event - safe to ignore", source: $source}')
export TEST_MESSAGE_BODY

SCRIPT_START_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
node "$NODE_SCRATCH_DIR/publish-message.js"
echo "Published synthetic message (source=${TEST_SOURCE}) to ${SERVICEBUS_TOPIC}"

# --- Stage 3: watch for KEDA to create a new Job, then wait for it to succeed -----------------
# scaledjob.keda.sh/name is the label KEDA sets on every batch/v1 Job it creates per scaling
# decision (one ScaledJob execution = one new Job object, not a reused one) - filtered to jobs
# created after SCRIPT_START_TIME (captured before publishing, above) so a stale, unrelated
# prior execution can't be mistaken for this run's own. ISO8601's fixed-width, zero-padded
# format means plain string comparison (awk's $2 > since) is chronologically correct here,
# without needing a date-parsing library.
TIMEOUT=90
INTERVAL=10
ELAPSED=0
JOB_NAME=""
while true; do
  # || true here, same reasoning as smoke-test.sh's own precedent: preserves this loop's
  # tolerance of a transient kubectl failure under the pipefail set above, so one hiccup retries
  # on the next iteration instead of aborting the whole script - the ELAPSED/TIMEOUT check below
  # is what actually detects a genuine failure.
  JOB_NAME=$(kubectl get jobs -n "$NAMESPACE" -l "scaledjob.keda.sh/name=create-incident-job" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.creationTimestamp}{"\n"}{end}' \
    | awk -v since="$SCRIPT_START_TIME" '$2 > since {print $1}' | sort | tail -n1 || true)
  if [ -n "$JOB_NAME" ]; then
    echo "Found KEDA-created Job: ${JOB_NAME}"
    break
  fi
  echo "Elapsed ${ELAPSED}s: no new create-incident-job Job yet"
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "::error::Timed out after ${TIMEOUT}s waiting for KEDA to create a new Job for create-incident-job (labeled scaledjob.keda.sh/name=create-incident-job, created after ${SCRIPT_START_TIME})"
    echo "--- kubectl describe scaledjob create-incident-job (KEDA's own trigger status) ---"
    kubectl describe scaledjob create-incident-job -n "$NAMESPACE" || true
    exit 1
  fi
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

TIMEOUT=60
INTERVAL=5
ELAPSED=0
while true; do
  SUCCEEDED=$(kubectl get job "$JOB_NAME" -n "$NAMESPACE" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)
  FAILED=$(kubectl get job "$JOB_NAME" -n "$NAMESPACE" -o jsonpath='{.status.failed}' 2>/dev/null || true)
  if [ "$SUCCEEDED" = "1" ]; then
    echo "Job ${JOB_NAME} succeeded"
    break
  fi
  if [ -n "$FAILED" ] && [ "$FAILED" -ge 1 ]; then
    echo "::error::Job ${JOB_NAME} failed (status.failed=${FAILED})"
    echo "--- kubectl describe job ---"
    kubectl describe job "$JOB_NAME" -n "$NAMESPACE" || true
    echo "--- kubectl logs ---"
    kubectl logs -n "$NAMESPACE" "job/${JOB_NAME}" --all-containers --prefix || true
    exit 1
  fi
  echo "Elapsed ${ELAPSED}s: Job ${JOB_NAME} still running (succeeded=${SUCCEEDED:-0}, failed=${FAILED:-0})"
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "::error::Timed out after ${TIMEOUT}s waiting for Job ${JOB_NAME} to report success"
    echo "--- kubectl describe job ---"
    kubectl describe job "$JOB_NAME" -n "$NAMESPACE" || true
    echo "--- kubectl logs ---"
    kubectl logs -n "$NAMESPACE" "job/${JOB_NAME}" --all-containers --prefix || true
    exit 1
  fi
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

# --- Stage 4: query Cosmos directly for the real write ----------------------------------------
# A successful Job exit only proves the process ran to completion, not that the Cosmos write
# itself landed (same reasoning as smoke-test.sh's own note: /health alone doesn't prove a
# write succeeded) - this is the actual proof, via an independent client, not the job's own.
TIMEOUT=30
INTERVAL=5
ELAPSED=0
INCIDENT_JSON=""
while true; do
  if INCIDENT_JSON=$(node "$NODE_SCRATCH_DIR/find-incident.js" 2>"$EVIDENCE_DIR/find-incident-error.log"); then
    break
  fi
  echo "Elapsed ${ELAPSED}s: no Incident document found yet for source=${TEST_SOURCE}"
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "::error::Timed out after ${TIMEOUT}s waiting for an Incident document with source=${TEST_SOURCE} in Cosmos DB - Job ${JOB_NAME} reported success, but no matching write was found."
    exit 1
  fi
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done
echo "$INCIDENT_JSON" > "$EVIDENCE_DIR/incident-response.json"
INCIDENT_ID=$(echo "$INCIDENT_JSON" | jq -r '.id')
INCIDENT_SEVERITY=$(echo "$INCIDENT_JSON" | jq -r '.severity')
export INCIDENT_ID INCIDENT_SEVERITY
echo "Cosmos DB write confirmed: incident ${INCIDENT_ID} (source=${TEST_SOURCE}) created via Job ${JOB_NAME}'s Workload Identity."

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "job_name=${JOB_NAME}" >> "$GITHUB_OUTPUT"
fi

echo "Smoke test passed: Job ${JOB_NAME} (image tag ${EXPECTED_TAG}) processed a real Service Bus message and wrote to ${ENVIRONMENT_LABEL}'s Cosmos DB."
