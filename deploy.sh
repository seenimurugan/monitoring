#!/usr/bin/env bash
# deploy.sh — idempotent deploy for the homelab monitoring stack
# (Prometheus + Grafana + Alertmanager + Loki + Alloy + WhatsApp adapter + alerting)
# Usage: ./deploy.sh
# Safe to re-run; existing Helm releases are upgraded, not replaced.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 1. Load .env ──────────────────────────────────────────────────────────────
ENV_FILE="$SCRIPT_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env not found."
  echo "       Copy .env.example to .env and fill in real values, then re-run."
  echo "         cp .env.example .env && \$EDITOR .env"
  exit 1
fi
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

# ── 2. Prereq checks ──────────────────────────────────────────────────────────
for cmd in kubectl helm envsubst; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' not found in PATH."
    [[ "$cmd" == "envsubst" ]] && echo "       Install via: brew install gettext"
    exit 1
  fi
done
if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: Cannot reach the Kubernetes cluster. Is OrbStack running?"
  exit 1
fi

# ── 3. Helm repos ─────────────────────────────────────────────────────────────
echo "[1/8] Adding Helm repos..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community grafana >/dev/null

# ── 4. Ensure namespace ───────────────────────────────────────────────────────
NS="${MONITORING_NAMESPACE:-monitoring}"
echo "[2/8] Ensuring namespace '$NS'..."
if ! kubectl get namespace "$NS" &>/dev/null; then
  echo "  Namespace '$NS' not found — creating it."
  kubectl create namespace "$NS"
else
  echo "  Namespace '$NS' already exists."
fi

# ── 5. Create / update grafana-admin-secret ───────────────────────────────────
echo "[3/11] Ensuring grafana-admin-secret..."
kubectl -n "$NS" create secret generic grafana-admin-secret \
  --from-literal=admin-user="${GRAFANA_ADMIN_USERNAME}" \
  --from-literal=admin-password="${GRAFANA_ADMIN_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── 5b. Create / update telegram-alert-config ────────────────────────────────
echo "[4/11] Ensuring telegram-alert-config..."
kubectl -n "$NS" create secret generic telegram-alert-config \
  --from-literal=bot_token="${ALERTMANAGER_TELEGRAM_BOT_TOKEN}" \
  --from-literal=chat_id="${ALERTMANAGER_TELEGRAM_CHAT_ID}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── 5c. Create / update whatsapp-alert-config ────────────────────────────────
echo "[5/11] Ensuring whatsapp-alert-config..."
kubectl -n "$NS" create secret generic whatsapp-alert-config \
  --from-literal=target_number="${ALERTMANAGER_WHATSAPP_TARGET}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── 6. kube-prometheus-stack (Prometheus + Grafana + Alertmanager + exporters) -
echo "[6/11] Installing/upgrading kube-prometheus-stack..."
# envsubst expands MONITORING_NAMESPACE and ALERTMANAGER_TELEGRAM_CHAT_ID from .env.
envsubst < "$SCRIPT_DIR/values/kube-prometheus-stack-values.yaml" > /tmp/kps-values.yaml
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  --namespace "$NS" \
  --version 86.1.0 \
  --values /tmp/kps-values.yaml \
  --wait --timeout 10m

# ── 7. Loki ───────────────────────────────────────────────────────────────────
echo "[7/11] Installing/upgrading Loki..."
helm upgrade --install loki grafana/loki \
  --namespace "$NS" \
  --version 7.0.0 \
  --values "$SCRIPT_DIR/values/loki-values.yaml" \
  --wait --timeout 10m

# ── 8. Alloy ──────────────────────────────────────────────────────────────────
echo "[8/11] Installing/upgrading Alloy..."
helm upgrade --install alloy grafana/alloy \
  --namespace "$NS" \
  --version 1.8.2 \
  --values "$SCRIPT_DIR/values/alloy-values.yaml" \
  --wait --timeout 5m

# ── 9. k8s manifests (ingress + loki datasource) ──────────────────────────────
echo "[9/11] Applying k8s manifests..."
K8S_DIR="$SCRIPT_DIR/k8s"
for f in grafana-loki-datasource.yaml grafana-ingress.yaml; do
  echo "  → $f"
  envsubst < "$K8S_DIR/$f" | kubectl apply -f -
done
# NOTE: servicemonitor-template.yaml is NOT applied here — it is a reference
# template for app-side use. Copy it into the app's repo and apply it there.

# ── 10. Alerting stack (WhatsApp adapter + Arrstack VPN PrometheusRule) ───────
echo "[10/11] Applying alerting manifests..."
for f in alertmanager-whatsapp-adapter.yaml arrstack-vpn-alert.yaml; do
  echo "  → $f"
  kubectl apply -f "$K8S_DIR/$f"
done

# ── 11. Rollout status ────────────────────────────────────────────────────────
echo "[11/11] Waiting for Grafana rollout..."
kubectl -n "$NS" rollout status deployment/grafana --timeout=5m

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "Monitoring stack deployed successfully."
echo ""
echo "  Grafana URL:  https://${GRAFANA_INGRESS_HOST}.${TAILNET_DOMAIN}"
echo "  Admin user:   ${GRAFANA_ADMIN_USERNAME}"
echo "  Admin pass:   (see .env — GRAFANA_ADMIN_PASSWORD)"
echo ""
echo "  The Tailscale operator provisions the HTTPS proxy within ~30s of first"
echo "  install. If https://... is not reachable immediately, wait a moment."
echo ""
echo "  Other endpoints (debug port-forwards):"
echo "    kubectl -n $NS port-forward svc/grafana 3000:80          → http://localhost:3000"
echo "    kubectl -n $NS port-forward svc/kps-prometheus 9090:9090 → http://localhost:9090"
echo "    kubectl -n $NS port-forward svc/loki 3100:3100           → http://localhost:3100"
echo ""
echo "  Alert delivery:"
echo "    Telegram:  channel ${ALERTMANAGER_TELEGRAM_CHAT_ID} (warning-severity alerts)"
echo "    WhatsApp:  ${ALERTMANAGER_WHATSAPP_TARGET} via reminders sidecar"
