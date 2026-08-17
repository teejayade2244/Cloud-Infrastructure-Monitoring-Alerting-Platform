#!/usr/bin/env bash
set -euo pipefail

# Expects EXPECTED_TAG in the environment (the image tag update-staging-values just pushed to
# inframonitor-gitops) and a kubeconfig already authenticated against inframonitor-aks (azure/login
# + kubelogin convert-kubeconfig -l azurecli, done by the calling workflow step before this runs).

# Response bodies + a summary go here instead of /tmp, so the calling workflow step can upload
# this whole directory as a build artifact (actions/upload-artifact, if: always()) - the evidence
# a run actually produced, not just its pass/fail conclusion, kept around after the runner is gone.
EVIDENCE_DIR="smoke-test-evidence"
mkdir -p "$EVIDENCE_DIR"

# Registered here, before anything that can fail, rather than after the polling loops - so
# summary.json (and whatever response bodies exist) always gets written, even if the failure was
# in the ArgoCD refresh or either poll loop below, not just a late-stage failure. Combined into
# one handler (rather than a separate trap per concern) because bash's `trap` replaces any
# previous handler for the same signal - a second `trap ... EXIT` call would silently drop this
# one instead of adding to it. Each branch is a no-op until the thing it references actually
# gets set - safe under set -u via the ${VAR:-} guards throughout.
cleanup() {
  local exit_code=$?
  if [ -n "${EVENT_ID:-}" ]; then
    echo "Cleaning up smoke-test event ${EVENT_ID}..."
    # Real DELETE /events/:id route (src/routes/events.js), called over the same port-forward
    # already established below - not kubectl exec. Requires zero new K8s RBAC: no pods/exec
    # grant, ci-rbac.yaml is untouched. Runs before the port-forward is killed further down, since
    # it needs that tunnel still open. Cleanup failure is a warning, not a job failure: it doesn't
    # invalidate what was actually verified above, and the event is clearly marked (source) for
    # manual removal.
    DELETE_STATUS=$(curl -s -o "$EVIDENCE_DIR/event-delete-response.json" -w '%{http_code}' \
      -X DELETE "http://localhost:3000/events/${EVENT_ID}" 2>/dev/null || echo "000")
    if [ "$DELETE_STATUS" = "200" ]; then
      echo "Deleted smoke-test event ${EVENT_ID}"
    else
      echo "::warning::Failed to delete smoke-test event ${EVENT_ID} (source=${TEST_SOURCE}) via DELETE /events/${EVENT_ID} (HTTP ${DELETE_STATUS}) - may need manual removal"
    fi
  fi
  if [ -n "${PF_PID:-}" ]; then
    kill "$PF_PID" 2>/dev/null || true
  fi
  # Written unconditionally, from whatever variables happen to be set at this point - on a
  # failed run that's a partial snapshot (e.g. "ArgoCD refresh sent, but the deployment never
  # picked up the new tag"), which is exactly what's useful for debugging a failure after the
  # runner is gone.
  jq -n \
    --arg run_id "${GITHUB_RUN_ID:-manual}" \
    --arg image_tag "${EXPECTED_TAG:-}" \
    --arg pod_name "${READY_POD:-}" \
    --arg health_status "${HTTP_STATUS:-}" \
    --arg event_id "${EVENT_ID:-}" \
    --arg post_status "${POST_STATUS:-}" \
    --arg delete_status "${DELETE_STATUS:-}" \
    --arg result "$([ "$exit_code" -eq 0 ] && echo success || echo failure)" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{run_id: $run_id, image_tag: $image_tag, pod_name: $pod_name, health_status: $health_status, event_id: $event_id, post_status: $post_status, delete_status: $delete_status, result: $result, timestamp: $timestamp}' \
    > "$EVIDENCE_DIR/summary.json" 2>/dev/null || true
  exit "$exit_code"
}
trap cleanup EXIT

# ArgoCD polls Git every ~3 minutes by default (confirmed: no timeout.reconciliation
# override in argocd-cm on this cluster, no GitHub webhook on inframonitor-gitops), so
# without this, the poll below would be racing that cycle rather than a fixed, known
# latency. events-service-staging has automated sync + selfHeal, so forcing a hard refresh
# is enough ArgoCD applies the diff itself once it detects one, no separate sync call
# needed. Requires get+patch on this one named Application, granted via
# inframonitor-gitops's inframonitor-namespace chart (ci-argocd-refresh-rbac.yaml).
kubectl patch application events-service-staging -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# Refresh above makes this deterministic rather than a race against ArgoCD's poll cycle,
# but still poll (not check-once) to cover the real time ArgoCD needs to diff and apply.
TIMEOUT=60
INTERVAL=10
ELAPSED=0
while true; do
  CURRENT_IMAGE=$(kubectl get deployment events-service -n inframonitor -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
  CURRENT_TAG="${CURRENT_IMAGE##*:}"
  echo "Elapsed ${ELAPSED}s: deployment image = ${CURRENT_IMAGE:-<none>}"
  if [ "$CURRENT_TAG" = "$EXPECTED_TAG" ]; then
    echo "Deployment now references image tag ${EXPECTED_TAG}"
    break
  fi
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "::error::Timed out after ${TIMEOUT}s waiting for the events-service Deployment in namespace inframonitor to reference image tag ${EXPECTED_TAG} (last seen: ${CURRENT_TAG:-<none>}). ArgoCD may not have synced yet, or the sync failed - check the inframonitor-namespace/events-service-staging Application in ArgoCD."
    exit 1
  fi
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

# A matching image tag on the Deployment spec doesn't mean the new pod has finished
# starting - poll pods directly for one running the expected tag with containerStatuses
# ready=true.
TIMEOUT=60
INTERVAL=5
ELAPSED=0
READY_POD=""
while true; do
  # || true here (not present verbatim in the original inline step) preserves this loop's
  # existing tolerance of a transient kubectl failure under the pipefail added above - without
  # it, pipefail would make a single kubectl hiccup abort the whole script instead of retrying
  # on the next iteration, same as it does today.
  READY_POD=$(kubectl get pods -n inframonitor -l app=events-service \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containers[0].image}{" "}{.status.containerStatuses[0].ready}{"\n"}{end}' \
    | awk -v tag="$EXPECTED_TAG" '$2 ~ ":"tag"$" && $3=="true" {print $1; exit}' || true)
  if [ -n "$READY_POD" ]; then
    echo "Ready pod found: ${READY_POD} (image tag ${EXPECTED_TAG})"
    break
  fi
  echo "Elapsed ${ELAPSED}s: no Ready pod yet running tag ${EXPECTED_TAG}"
  kubectl get pods -n inframonitor -l app=events-service
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "::error::Timed out after ${TIMEOUT}s waiting for a Ready events-service pod running image tag ${EXPECTED_TAG}"
    exit 1
  fi
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done
echo "pod_name=${READY_POD}" >> "$GITHUB_OUTPUT"

# port-forward from the runner rather than kubectl exec+curl inside the pod: the image is
# node:20-alpine with no curl installed (confirmed against the Dockerfile), so exec+curl
# would fail on missing curl rather than reflect anything about the service itself.
# Targets the exact pod confirmed Ready above, not the Deployment/Service in general, so
# this can't accidentally hit a stale pod mid-rollout.
POD="$READY_POD"

kubectl port-forward -n inframonitor "pod/${POD}" 3000:3000 &
PF_PID=$!

CONNECTED=false
for _ in $(seq 1 10); do
  if curl -sf -o /dev/null http://localhost:3000/health; then
    CONNECTED=true
    break
  fi
  sleep 1
done
if [ "$CONNECTED" != "true" ]; then
  echo "::error::Could not reach pod ${POD} on localhost:3000 via kubectl port-forward"
  exit 1
fi

HTTP_STATUS=$(curl -s -o "$EVIDENCE_DIR/health-response.json" -w '%{http_code}' http://localhost:3000/health)
echo "GET /health -> HTTP ${HTTP_STATUS}"
cat "$EVIDENCE_DIR/health-response.json"
if [ "$HTTP_STATUS" != "200" ]; then
  echo "::error::events-service /health on pod ${POD} returned HTTP ${HTTP_STATUS} (expected 200)"
  exit 1
fi
echo "Process liveness confirmed: pod ${POD} (image tag ${EXPECTED_TAG}) answers /health."

# /health only proves the process is up, it has no dependencies on Cosmos DB or Workload
# Identity (see app.js). This section proves the real chain: the pod's actual Workload Identity
# authenticates to Azure AD and writes a real document into staging's real Cosmos DB
# (InfraMonitorDB - not a test database, deliberately, since this is testing the real staging
# path end to end).
#
# Schema per src/middleware/validate.js: type/environment/severity/
# message/source are required. severity is deliberately "info", not "critical"/"high" those
# trigger a real Service Bus publish in events.js, which is out of scope for this Cosmos-focused
# check and would leave a synthetic message in the real topic too. source carries the marker,
# matching the same convention __tests__/integration/events.integration.test.js already uses to
# keep synthetic data identifiable and sweepable.
EVENT_ENVIRONMENT="staging"
TEST_SOURCE="ci-smoke-test-${GITHUB_RUN_ID:-manual}"

POST_STATUS=$(curl -s -o "$EVIDENCE_DIR/event-post-response.json" -w '%{http_code}' \
  -X POST http://localhost:3000/events \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"metric\",\"environment\":\"${EVENT_ENVIRONMENT}\",\"severity\":\"info\",\"message\":\"CI smoke test event - safe to ignore\",\"source\":\"${TEST_SOURCE}\"}")
echo "POST /events -> HTTP ${POST_STATUS}"
cat "$EVIDENCE_DIR/event-post-response.json"
if [ "$POST_STATUS" != "201" ]; then
  echo "::error::POST /events on pod ${POD} returned HTTP ${POST_STATUS} (expected 201) - Workload Identity auth or the Cosmos DB write failed. See response body above."
  exit 1
fi

# events.js only returns 201 with an eventId after eventsContainer.items.create(event) actually
# succeeds (any Cosmos error is caught and returns 500 instead) - so a 201 + eventId here is
# itself the proof the write landed, not just that the HTTP handler ran.
EVENT_ID=$(jq -r '.eventId // empty' "$EVIDENCE_DIR/event-post-response.json")
if [ -z "$EVENT_ID" ]; then
  echo "::error::POST /events returned HTTP 201 but no eventId in the response body - cannot confirm the write or clean it up"
  exit 1
fi
echo "Cosmos DB write confirmed: event ${EVENT_ID} (source=${TEST_SOURCE}) created in InfraMonitorDB via pod ${POD}'s Workload Identity."

echo "Smoke test passed: pod ${POD} (image tag ${EXPECTED_TAG}) is healthy and can write to staging's Cosmos DB."
