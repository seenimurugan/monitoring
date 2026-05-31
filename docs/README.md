# Monitoring — Prometheus + Grafana + Loki

Cluster observability stack. One Grafana UI for both metrics (Prometheus) and logs (Loki). New apps are picked up automatically.

Source: [`github.com/seenimurugan/monitoring`](https://github.com/seenimurugan/monitoring). Values files + deploy script live at the root of that repo.

**On this page:** [Access](#access) · [Initial credentials](#initial-credentials) · [What it does](#what-it-does) · [Logs by app — the "$app dropdown" workflow](#logs-by-app--the-$app-dropdown-workflow) · [Adding metrics for a new app](#adding-metrics-for-a-new-app) · [Stack & framework](#stack--framework) · [Storage](#storage) · [See also](#see-also) · [File reference](#file-reference)

---

## Access

| Where | URL |
|---|---|
| **Phone / any tailnet device** | https://grafana.stoat-perch.ts.net |
| **Ad-hoc debug port-forward (Grafana)** | `kubectl -n monitoring port-forward svc/grafana 3000:80` → http://localhost:3000 |
| **Ad-hoc port-forward (Prometheus UI)** | `kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090` → http://localhost:9090 |
| **Ad-hoc port-forward (Loki API)** | `kubectl -n monitoring port-forward svc/loki 3100:3100` → http://localhost:3100 |
| **Cluster DNS — Grafana** | http://grafana.monitoring.svc.cluster.local |
| **Cluster DNS — Prometheus** | http://kps-prometheus.monitoring.svc.cluster.local:9090 |
| **Cluster DNS — Loki push** | http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push |

Grafana is the only UI you ever need. Prometheus/Loki direct UIs are for debugging.

## Initial credentials

| | |
|---|---|
| User | `admin` |
| Password | `homelab-admin` |

**Change immediately** in Grafana → top-right user icon → Change password. Then update `GRAFANA_ADMIN_PASSWORD` in `.env` and re-run `./deploy.sh` to rotate the `grafana-admin-secret` in Kubernetes.

---

## What it does

- 📊 **Cluster metrics** — Prometheus scrapes kubelet/kube-state-metrics/node-exporter every 30s. Pod inventory + state + declared CPU/memory, host CPU/memory/disk/network usage. *(Per-container live CPU/memory time-series are degraded on OrbStack k3s — see [Maintenance → OrbStack pod-metrics limitation](MAINTENANCE.md#orbstack-k3s-per-container-metrics-limitation).)*
- 📜 **Pod logs** — Grafana Alloy runs as a DaemonSet, tails every pod's log on every node, ships to Loki with labels `namespace / app / pod / container / node`.
- 🚨 **Alertmanager** — installed, no notification channels wired (intentional v1).
- 📈 **20+ K8s dashboards pre-imported** under "Dashboards → Browse" (Kubernetes / Compute Resources / *, Node Exporter Full, Logs / Pod, …).

---

## Logs by app — the "$app dropdown" workflow

The whole reason this exists: pick an app, see logs from all its pods.

1. Open Grafana → **Explore** (left sidebar compass icon).
2. Top-left datasource picker → **Loki**.
3. In the query bar, choose **Label browser** (or type directly):
   - Label `namespace` = `homelab`
   - Label `app` = `<pick from dropdown>`
4. Hit **Run query**. Logs from every pod with that app label appear, oldest at top.

Aggregated apps available in the `app` dropdown right now:

```
bazarr, chores-backend, chores-frontend, docs, emailmatrix, filebrowser,
grocy, immich, immich-postgres, jellyfin, moviesda, prowlarr, qbittorrent,
radarr, reminders-backend, reminders-frontend, reminders-ocr,
reminders-whatsapp, shared-postgres
```

Any new app deployed with an `app: <name>` *or* `app.kubernetes.io/instance: <name>` pod label shows up automatically within a minute of the first log line — no config change.

### Useful LogQL snippets

```logql
# Everything from one app
{namespace="homelab", app="chores-backend"}

# Errors only, one app
{namespace="homelab", app="reminders-whatsapp"} |= "ERROR"

# All pods of one app, JSON-extracted fields
{namespace="homelab", app="moviesda"} | json | level="ERROR"

# Log rate per app over the homelab namespace (sparkline)
sum by (app) (rate({namespace="homelab"}[5m]))
```

---

## Adding metrics for a new app

The Loki side is automatic. Metrics from a custom app's `/metrics` or `/actuator/prometheus` endpoint require a small one-time opt-in:

1. Copy `k8s/servicemonitor-template.yaml` from this repo into the app's own manifests directory.
2. Replace `<app>`, `<app-namespace>`, `<port-name>` (must match a named port on the Service), `<path>` (e.g. `/actuator/prometheus`).
3. `kubectl apply -f <app>-servicemonitor.yaml`.
4. Within ~1 min Prometheus picks it up. Verify in the Prometheus UI → Status → Targets.

Example for `chores-backend` (Spring Boot Actuator):

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: chores-backend
  namespace: homelab
spec:
  selector:
    matchLabels:
      app: chores-backend
  endpoints:
    - port: http
      path: /actuator/prometheus
      interval: 30s
```

(Don't forget to add the Spring Boot dependency `micrometer-registry-prometheus` and enable `management.endpoints.web.exposure.include=prometheus,health,info` in `application.yml`.)

---

## Stack & framework

| Layer | Tech | Chart version |
|---|---|---|
| Metrics scrape + TSDB | **Prometheus** (Operator-managed) | `kube-prometheus-stack` 86.1.0 |
| Visualization | **Grafana** 11.x | (bundled in kube-prometheus-stack) |
| Alerting (no channels) | **Alertmanager** | (bundled) |
| Cluster inventory metrics | **kube-state-metrics** | (bundled) |
| Host metrics | **node-exporter** (DaemonSet) | (bundled) |
| Log aggregation | **Loki** 3.6.7 SingleBinary mode | `grafana/loki` 7.0.0 |
| Log shipper | **Grafana Alloy** (DaemonSet) | `grafana/alloy` 1.8.2 |
| Ingress | Tailscale operator (HTTPS) | shared |

---

## Storage

All on `local-path` (OrbStack VM-internal SSD) — never on HFS+ HDD (see `learnings.md` re. exFAT/HFS file-descriptor exhaustion):

| PVC | Size | Purpose |
|---|---|---|
| `prometheus-kps-prometheus-db-prometheus-kps-prometheus-0` | 20Gi | TSDB blocks, 7-day retention |
| `storage-loki-0` | 20Gi | Loki chunks + index, 7-day retention |
| `grafana` | 5Gi | Dashboards, plugins, sqlite |
| `alertmanager-kps-alertmanager-db-…` | 1Gi | Alertmanager state |

Retention: **7 days** for both metrics and logs (configured in values files). Bump in `loki-values.yaml` (`loki.limits_config.retention_period`) and `kube-prometheus-stack-values.yaml` (`prometheus.prometheusSpec.retention`) if you want longer.

Stateless: Alloy DaemonSet, kube-state-metrics, node-exporter, operators.

---

## See also

- [Maintenance](MAINTENANCE.md) — restart, scale, rotate password, retention bump, drop a stuck CRD

## File reference

| File | Purpose |
|---|---|
| `deploy.sh` | Idempotent installer (re-run to apply value changes) |
| `undeploy.sh` | Tear down Helm releases + manifests (PVCs preserved) |
| `values/kube-prometheus-stack-values.yaml` | Prometheus + Grafana + Alertmanager + exporter knobs |
| `values/loki-values.yaml` | Loki SingleBinary config |
| `values/alloy-values.yaml` | Log-shipper config (relabels pod labels → Loki streams) |
| `k8s/grafana-loki-datasource.yaml` | ConfigMap discovered by Grafana sidecar |
| `k8s/grafana-ingress.yaml` | Tailscale Ingress for `${GRAFANA_INGRESS_HOST}.${TAILNET_DOMAIN}` |
| `k8s/servicemonitor-template.yaml` | Template for opting an app into custom-metrics scraping (NOT applied by deploy.sh) |
