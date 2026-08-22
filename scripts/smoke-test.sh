#!/usr/bin/env bash
set -euo pipefail

# Expects EXPECTED_TAG in the environment (the image tag the calling job just deployed) and a
# kubeconfig already authenticated against inframonitor-aks (azure/login + kubelogin
# convert-kubeconfig -l azurecli, done by the calling workflow step before this runs).
#
# Environment-agnostic by design - optional inputs, each defaulting to events-service/staging's
# values so existing callers (events-service-ci.yml's smoke-test-staging job) keep working
# unchanged:
#   NAMESPACE          K8s namespace the pod/Deployment live in.
#   ARGOCD_APP_NAME     The ArgoCD Application to force-refresh - a DIFFERENT resource per
#                        environment (events-service-staging vs events-service-production), not
#                        implied by NAMESPACE alone, so it's its own parameter rather than derived.
#   ENVIRONMENT_LABEL   Written into the synthetic test document's own "environment" field.
#                        Staging and production share one Cosmos account but use separate
#                        databases, so this only affects the data written INTO whichever database
#                        the pod's own env vars already point at - it doesn't route the write
#                        anywhere.
#   SERVICE_NAME        Both the Deployment name / pod label (app=$SERVICE_NAME) AND which
#                        write/cleanup logic below applies (see verify_write_* below) - added for
#                        incidents-service. Genuinely does double duty: which K8s resources to
#                        poll for and which API schema to speak are the same underlying "which
#                        service is this" fact, not two independent things that happen to share a
#                        value.
NAMESPACE="${NAMESPACE:-inframonitor}"
ARGOCD_APP_NAME="${ARGOCD_APP_NAME:-events-service-staging}"
ENVIRONMENT_LABEL="${ENVIRONMENT_LABEL:-staging}"
SERVICE_NAME="${SERVICE_NAME:-events-service}"

if [ "$SERVICE_NAME" != "events-service" ] && [ "$SERVICE_NAME" != "incidents-service" ]; then
  echo "::error::SERVICE_NAME must be 'events-service' or 'incidents-service', got '${SERVICE_NAME}' - no write/verify check defined for it"
  exit 1
fi

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
  if [ -n "${WRITE_ID:-}" ]; then
    # events-service and incidents-service genuinely differ here, not just by parameter:
    # events-service has a real DELETE /events/:id route, so cleanup removes the record
    # entirely. incidents-service has no delete endpoint at all (confirmed against the real
    # controller) - the closest genuine equivalent using only endpoints that actually exist is
    # PATCH-ing it to a terminal status, which leaves the record in Cosmos DB but clearly closed
    # out rather than deleted.
    case "$SERVICE_NAME" in
      events-service)
        echo "Cleaning up smoke-test event ${WRITE_ID}..."
        CLEANUP_STATUS=$(curl -s -o "$EVIDENCE_DIR/cleanup-response.json" -w '%{http_code}' \
          -X DELETE "http://localhost:3000/events/${WRITE_ID}" 2>/dev/null || echo "000")
        ;;
      incidents-service)
        echo "Closing out smoke-test incident ${WRITE_ID}..."
        CLEANUP_STATUS=$(curl -s -o "$EVIDENCE_DIR/cleanup-response.json" -w '%{http_code}' \
          -X PATCH "http://localhost:3000/incidents/${WRITE_ID}?severity=${WRITE_PARTITION_KEY:-}" \
          -H "Content-Type: application/json" \
          -d '{"status":"resolved","message":"auto-closed by CI smoke test cleanup","updatedBy":"ci-smoke-test"}' \
          2>/dev/null || echo "000")
        ;;
    esac
    if [ "$CLEANUP_STATUS" = "200" ]; then
      echo "Cleanup succeeded for ${WRITE_ID}"
    else
      echo "::warning::Cleanup failed for ${WRITE_ID} (source=${TEST_SOURCE:-unknown}, service=${SERVICE_NAME}) - HTTP ${CLEANUP_STATUS} - may need manual attention"
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
    --arg service "$SERVICE_NAME" \
    --arg environment "$ENVIRONMENT_LABEL" \
    --arg namespace "$NAMESPACE" \
    --arg image_tag "${EXPECTED_TAG:-}" \
    --arg pod_name "${READY_POD:-}" \
    --arg health_status "${HTTP_STATUS:-}" \
    --arg write_id "${WRITE_ID:-}" \
    --arg post_status "${POST_STATUS:-}" \
    --arg read_status "${GET_STATUS:-}" \
    --arg cleanup_status "${CLEANUP_STATUS:-}" \
    --arg result "$([ "$exit_code" -eq 0 ] && echo success || echo failure)" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{run_id: $run_id, service: $service, environment: $environment, namespace: $namespace, image_tag: $image_tag, pod_name: $pod_name, health_status: $health_status, write_id: $write_id, post_status: $post_status, read_status: $read_status, cleanup_status: $cleanup_status, result: $result, timestamp: $timestamp}' \
    > "$EVIDENCE_DIR/summary.json" 2>/dev/null || true
  exit "$exit_code"
}
trap cleanup EXIT

# ArgoCD polls Git every ~3 minutes by default (confirmed: no timeout.reconciliation
# override in argocd-cm on this cluster, no GitHub webhook on inframonitor-gitops), so
# without this, the poll below would be racing that cycle rather than a fixed, known
# latency. The target Application has automated sync + selfHeal (confirmed for events-service
# and incidents-service, staging and production), so forcing a hard refresh is enough - ArgoCD
# applies the diff itself once it detects one, no separate sync call needed. Requires get+patch
# on this one named Application, granted via inframonitor-gitops's inframonitor-namespace chart
# (ci-argocd-refresh-rbac.yaml).
kubectl patch application "$ARGOCD_APP_NAME" -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# Refresh above makes this deterministic rather than a race against ArgoCD's poll cycle,
# but still poll (not check-once) to cover the real time ArgoCD needs to diff and apply.
TIMEOUT=60
INTERVAL=10
ELAPSED=0
while true; do
  CURRENT_IMAGE=$(kubectl get deployment "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
  CURRENT_TAG="${CURRENT_IMAGE##*:}"
  echo "Elapsed ${ELAPSED}s: deployment image = ${CURRENT_IMAGE:-<none>}"
  if [ "$CURRENT_TAG" = "$EXPECTED_TAG" ]; then
    echo "Deployment now references image tag ${EXPECTED_TAG}"
    break
  fi
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "::error::Timed out after ${TIMEOUT}s waiting for the ${SERVICE_NAME} Deployment in namespace ${NAMESPACE} to reference image tag ${EXPECTED_TAG} (last seen: ${CURRENT_TAG:-<none>}). ArgoCD may not have synced yet, or the sync failed - check the ${ARGOCD_APP_NAME} Application in ArgoCD."
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
  READY_POD=$(kubectl get pods -n "$NAMESPACE" -l app="$SERVICE_NAME" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containers[0].image}{" "}{.status.containerStatuses[0].ready}{"\n"}{end}' \
    | awk -v tag="$EXPECTED_TAG" '$2 ~ ":"tag"$" && $3=="true" {print $1; exit}' || true)
  if [ -n "$READY_POD" ]; then
    echo "Ready pod found: ${READY_POD} (image tag ${EXPECTED_TAG})"
    break
  fi
  echo "Elapsed ${ELAPSED}s: no Ready pod yet running tag ${EXPECTED_TAG}"
  kubectl get pods -n "$NAMESPACE" -l app="$SERVICE_NAME"
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "::error::Timed out after ${TIMEOUT}s waiting for a Ready ${SERVICE_NAME} pod running image tag ${EXPECTED_TAG}"
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

kubectl port-forward -n "$NAMESPACE" "pod/${POD}" 3000:3000 &
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
  echo "::error::${SERVICE_NAME} /health on pod ${POD} returned HTTP ${HTTP_STATUS} (expected 200)"
  exit 1
fi
echo "Process liveness confirmed: pod ${POD} (image tag ${EXPECTED_TAG}) answers /health."

# /health only proves the process is up, it has no dependencies on Cosmos DB or Workload
# Identity. This section proves the real chain: the pod's actual Workload Identity authenticates
# to Azure AD and writes a real document into this environment's real Cosmos DB (not a test
# database, deliberately, since this is testing the real deployment path end to end - staging
# and production use separate databases on the same Cosmos account, see values-*.yaml).
TEST_SOURCE="ci-smoke-test-${GITHUB_RUN_ID:-manual}"

# events-service and incidents-service have genuinely different write schemas and response
# shapes (confirmed against their real routes/controllers, not assumed) - not something that
# collapses into shared logic via parameters alone, so each gets its own function. What's
# actually shared is everything ABOVE this point (ArgoCD refresh, both polls, port-forward,
# /health) plus the trap/evidence/summary machinery - genuine infrastructure, not domain logic.

# Schema per src/middleware/validate.js: type/environment/severity/message/source are required.
# severity is deliberately "info", not "critical"/"high" - those trigger a real Service Bus
# publish in events.js, out of scope for this Cosmos-focused check and would leave a synthetic
# message in the real topic too. source carries the marker, matching the same convention
# __tests__/integration/events.integration.test.js already uses to keep synthetic data
# identifiable and sweepable.
verify_write_events() {
  POST_STATUS=$(curl -s -o "$EVIDENCE_DIR/write-response.json" -w '%{http_code}' \
    -X POST http://localhost:3000/events \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"metric\",\"environment\":\"${ENVIRONMENT_LABEL}\",\"severity\":\"info\",\"message\":\"CI smoke test event - safe to ignore\",\"source\":\"${TEST_SOURCE}\"}")
  echo "POST /events -> HTTP ${POST_STATUS}"
  cat "$EVIDENCE_DIR/write-response.json"
  if [ "$POST_STATUS" != "201" ]; then
    echo "::error::POST /events on pod ${POD} returned HTTP ${POST_STATUS} (expected 201) - Workload Identity auth or the Cosmos DB write failed. See response body above."
    exit 1
  fi

  # events.js only returns 201 with an eventId after eventsContainer.items.create(event)
  # actually succeeds (any Cosmos error is caught and returns 500 instead) - so a 201 + eventId
  # here is itself the proof the write landed, not just that the HTTP handler ran.
  WRITE_ID=$(jq -r '.eventId // empty' "$EVIDENCE_DIR/write-response.json")
  if [ -z "$WRITE_ID" ]; then
    echo "::error::POST /events returned HTTP 201 but no eventId in the response body - cannot confirm the write or clean it up"
    exit 1
  fi
  echo "Cosmos DB write confirmed: event ${WRITE_ID} (source=${TEST_SOURCE}) created via pod ${POD}'s Workload Identity."

  # A successful create doesn't prove GET /events/:id's separate query path works - it's a
  # structurally different Cosmos call (a cross-partition query, not the create response echoed
  # back), so read the same document back through the real API to close that gap.
  GET_STATUS=$(curl -s -o "$EVIDENCE_DIR/read-response.json" -w '%{http_code}' \
    "http://localhost:3000/events/${WRITE_ID}")
  echo "GET /events/${WRITE_ID} -> HTTP ${GET_STATUS}"
  cat "$EVIDENCE_DIR/read-response.json"
  if [ "$GET_STATUS" != "200" ]; then
    echo "::error::GET /events/${WRITE_ID} on pod ${POD} returned HTTP ${GET_STATUS} (expected 200) - the write succeeded but reading it back failed"
    exit 1
  fi
  READ_ID=$(jq -r '.id // empty' "$EVIDENCE_DIR/read-response.json")
  if [ "$READ_ID" != "$WRITE_ID" ]; then
    echo "::error::GET /events/${WRITE_ID} returned HTTP 200 but its id (${READ_ID:-<empty>}) doesn't match what was written (${WRITE_ID})"
    exit 1
  fi
  echo "Cosmos DB read confirmed: event ${WRITE_ID} reads back correctly via pod ${POD}'s Workload Identity."
}

# Schema per Controllers/IncidentsController.cs's CreateIncident validation: title/severity/
# environment are required (confirmed against the real controller, not assumed - there's no
# fixed severity enum here unlike events-service, any non-empty string is accepted). severity
# doubles as the Cosmos partition key (confirmed in IncidentService.cs), so it has to be
# captured from the response alongside the id - both are needed later just to PATCH it back.
verify_write_incidents() {
  POST_STATUS=$(curl -s -o "$EVIDENCE_DIR/write-response.json" -w '%{http_code}' \
    -X POST http://localhost:3000/incidents \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"CI smoke test incident - safe to ignore\",\"description\":\"Created by the staging/production smoke test to verify the real create+update path\",\"severity\":\"info\",\"environment\":\"${ENVIRONMENT_LABEL}\",\"source\":\"${TEST_SOURCE}\"}")
  echo "POST /incidents -> HTTP ${POST_STATUS}"
  cat "$EVIDENCE_DIR/write-response.json"
  if [ "$POST_STATUS" != "201" ]; then
    echo "::error::POST /incidents on pod ${POD} returned HTTP ${POST_STATUS} (expected 201) - Workload Identity auth or the Cosmos DB write failed. See response body above."
    exit 1
  fi

  # CreateIncidentAsync only returns after _container.CreateItemAsync succeeds - an unhandled
  # Cosmos exception would surface as a 500 via ErrorHandlingMiddleware instead, so a 201 + id
  # here is itself the proof the write landed, not just that the HTTP handler ran.
  WRITE_ID=$(jq -r '.id // empty' "$EVIDENCE_DIR/write-response.json")
  WRITE_PARTITION_KEY=$(jq -r '.severity // empty' "$EVIDENCE_DIR/write-response.json")
  if [ -z "$WRITE_ID" ] || [ -z "$WRITE_PARTITION_KEY" ]; then
    echo "::error::POST /incidents returned HTTP 201 but no id/severity in the response body - cannot confirm the write or clean it up"
    exit 1
  fi
  echo "Cosmos DB write confirmed: incident ${WRITE_ID} (source=${TEST_SOURCE}) created via pod ${POD}'s Workload Identity."

  # Same reasoning as events-service: a successful create doesn't prove GetIncidentByIdAsync's
  # point-read (a structurally different Cosmos call, keyed on id + the severity partition key)
  # actually works - read the same document back through the real API to close that gap.
  GET_STATUS=$(curl -s -o "$EVIDENCE_DIR/read-response.json" -w '%{http_code}' \
    "http://localhost:3000/incidents/${WRITE_ID}?severity=${WRITE_PARTITION_KEY}")
  echo "GET /incidents/${WRITE_ID}?severity=${WRITE_PARTITION_KEY} -> HTTP ${GET_STATUS}"
  cat "$EVIDENCE_DIR/read-response.json"
  if [ "$GET_STATUS" != "200" ]; then
    echo "::error::GET /incidents/${WRITE_ID} on pod ${POD} returned HTTP ${GET_STATUS} (expected 200) - the write succeeded but reading it back failed"
    exit 1
  fi
  READ_ID=$(jq -r '.id // empty' "$EVIDENCE_DIR/read-response.json")
  if [ "$READ_ID" != "$WRITE_ID" ]; then
    echo "::error::GET /incidents/${WRITE_ID} returned HTTP 200 but its id (${READ_ID:-<empty>}) doesn't match what was written (${WRITE_ID})"
    exit 1
  fi
  echo "Cosmos DB read confirmed: incident ${WRITE_ID} reads back correctly via pod ${POD}'s Workload Identity."
}

case "$SERVICE_NAME" in
  events-service) verify_write_events ;;
  incidents-service) verify_write_incidents ;;
esac

echo "Smoke test passed: pod ${POD} (image tag ${EXPECTED_TAG}) is healthy and can write to ${ENVIRONMENT_LABEL}'s Cosmos DB."
