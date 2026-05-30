#!/usr/bin/env bash
# undeploy.sh — tear down the monitoring stack Helm releases and k8s resources
# PVCs are preserved so Prometheus retention data and Loki logs survive.
# Re-run deploy.sh to bring everything back.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load .env for MONITORING_NAMESPACE ────────────────────────────────────────
ENV_FILE="$SCRIPT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi
NS="${MONITORING_NAMESPACE:-monitoring}"

echo "Undeploying monitoring stack from namespace '$NS'..."
echo "(PVCs are NOT deleted — Prometheus + Loki data is preserved.)"
echo ""

# ── Helm releases ─────────────────────────────────────────────────────────────
helm uninstall kps   --namespace "$NS" --ignore-not-found 2>/dev/null || true
helm uninstall loki  --namespace "$NS" --ignore-not-found 2>/dev/null || true
helm uninstall alloy --namespace "$NS" --ignore-not-found 2>/dev/null || true

# ── Standalone k8s resources ──────────────────────────────────────────────────
kubectl -n "$NS" delete ingress grafana           --ignore-not-found
kubectl -n "$NS" delete configmap loki-datasource --ignore-not-found
kubectl -n "$NS" delete secret grafana-admin-secret --ignore-not-found

echo ""
echo "Monitoring stack torn down."
echo ""
echo "  Kept (data):"
echo "    - All PVCs in namespace '$NS' (Prometheus TSDB, Loki chunks, Grafana sqlite)"
echo ""
echo "  To also delete all data (DESTRUCTIVE):"
echo "    kubectl delete pvc -n $NS --all"
echo "    kubectl delete ns $NS"
echo ""
echo "  To redeploy:  ./deploy.sh"
