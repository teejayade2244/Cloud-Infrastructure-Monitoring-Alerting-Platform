#!/usr/bin/env bash
set -euo pipefail

# Expects EXPECTED_TAG in the environment (the image tag update-staging-values just pushed to
# inframonitor-gitops) and a kubeconfig already authenticated against inframonitor-aks (azure/login
# + kubelogin convert-kubeconfig -l azurecli, done by the calling workflow step before this runs).

# ArgoCD polls Git every ~3 minutes by default (confirmed: no timeout.reconciliation
# override in argocd-cm on this cluster, no GitHub webhook on inframonitor-gitops), so
# without this, the poll below would be racing that cycle rather than a fixed, known
# latency. events-service-staging has automated sync + selfHeal, so forcing a hard refresh
# is enough - ArgoCD applies the diff itself once it detects one, no separate sync call
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
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

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

HTTP_STATUS=$(curl -s -o /tmp/health-response.json -w '%{http_code}' http://localhost:3000/health)
echo "GET /health -> HTTP ${HTTP_STATUS}"
cat /tmp/health-response.json
if [ "$HTTP_STATUS" != "200" ]; then
  echo "::error::events-service /health on pod ${POD} returned HTTP ${HTTP_STATUS} (expected 200)"
  exit 1
fi
echo "Smoke test passed: pod ${POD} (image tag ${EXPECTED_TAG}) is healthy."
