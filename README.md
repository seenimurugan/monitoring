# monitoring

Portable homelab monitoring stack — Prometheus + Grafana + Loki + Alloy on Kubernetes.

One Grafana UI for both metrics (Prometheus) and logs (Loki). Deployed via Helm on an OrbStack k3s cluster with Tailscale for remote access.

## Depends on

- **cluster-setup** — Tailscale ingress controller: [`github.com/seenimurugan/homelab-cluster-setup`](https://github.com/seenimurugan/homelab-cluster-setup)

## Quick start

```bash
git clone https://github.com/seenimurugan/monitoring
cd monitoring

# 1. Set up your env
cp .env.example .env
$EDITOR .env   # set GRAFANA_ADMIN_PASSWORD, TAILNET_DOMAIN

# 2. Deploy
./deploy.sh
```

`deploy.sh` is idempotent — safe to re-run. It adds Helm repos, creates the namespace, creates the Grafana admin secret from `.env`, installs/upgrades all three Helm charts, applies k8s manifests via `envsubst`, and waits for the Grafana rollout.

## Access

| | |
|---|---|
| **Tailnet URL** | `https://${GRAFANA_INGRESS_HOST}.${TAILNET_DOMAIN}` (default: https://grafana.stoat-perch.ts.net) |
| **Admin login** | `admin` / see `.env` (`GRAFANA_ADMIN_PASSWORD`) |
| **Debug port-forward (Grafana)** | `kubectl -n monitoring port-forward svc/grafana 3000:80` |
| **Debug port-forward (Prometheus)** | `kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090` |
| **Debug port-forward (Loki)** | `kubectl -n monitoring port-forward svc/loki 3100:3100` |

Change the admin password on first deploy.

## Tear down

```bash
./undeploy.sh   # removes Helm releases + manifests; preserves all PVCs
```

## Stack

| Layer | Tech | Chart version |
|---|---|---|
| Metrics scrape + TSDB | Prometheus (Operator-managed) | `kube-prometheus-stack` 86.1.0 |
| Visualization | Grafana 11.x | bundled in kube-prometheus-stack |
| Alerting | Alertmanager (no channels wired) | bundled |
| Cluster inventory metrics | kube-state-metrics | bundled |
| Host metrics | node-exporter (DaemonSet) | bundled |
| Log aggregation | Loki 3.6.7 SingleBinary | `grafana/loki` 7.0.0 |
| Log shipper | Grafana Alloy (DaemonSet) | `grafana/alloy` 1.8.2 |
| Ingress | Tailscale operator (HTTPS) | shared cluster dependency |

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `MONITORING_NAMESPACE` | `monitoring` | Kubernetes namespace to deploy into |
| `GRAFANA_ADMIN_USERNAME` | `admin` | Grafana admin username |
| `GRAFANA_ADMIN_PASSWORD` | _(required)_ | Grafana admin password — stored as a k8s Secret, never committed |
| `GRAFANA_INGRESS_HOST` | `grafana` | Tailscale ingress hostname prefix |
| `TAILNET_DOMAIN` | _(required)_ | Your Tailnet domain, e.g. `stoat-perch.ts.net` |

## Portability notes

### OrbStack k3s per-pod metrics gap

**Symptom:** "Compute Resources / Pod" dashboards show "No data" for live CPU/memory time-series.

**Cause:** OrbStack's k3s exposes only machine-level metrics through the kubelet's `/metrics/cadvisor` endpoint — no per-container series. A standalone cAdvisor DaemonSet cannot map cgroup IDs to pod metadata on OrbStack (the overlayfs layerdb path doesn't exist in OrbStack's storage layout) and an unrestricted cAdvisor can crash the k3s API server.

**What still works** (covers ~90% of real questions):

| Question | Works via |
|---|---|
| Is a pod restarting / OOMKilled / Running? | kube-state-metrics |
| Host CPU / memory / disk pressure? | node-exporter — "Node Exporter Full" dashboard |
| Pod CPU/memory requests + limits? | kube-state-metrics — CPU/Memory Quota tables |
| App logs? | Loki — fully working |
| Custom app metrics (latency, JVM heap, queues)? | App exposes `/metrics`, add a ServiceMonitor |

**Bottom line:** Accept the limitation. Use kube-state-metrics + node-exporter + Loki + per-app ServiceMonitors instead of per-container cAdvisor series. On a real Linux box running upstream k3s, cAdvisor works correctly.

### Other portability notes

- All storage uses `storageClassName: local-path` (OrbStack VM-internal SSD). Do **not** use HFS+ HDD-backed PVs — file-descriptor exhaustion (`ENFILE`) on first mount.
- Ingress class is `tailscale` — requires the Tailscale operator running in the cluster (from homelab-cluster-setup).
- OrbStack k3s consolidates controller-manager / scheduler / etcd / kube-proxy into a single binary — the corresponding scrape targets are disabled in `values/kube-prometheus-stack-values.yaml`.
- OrbStack k3s has an `init-chown-data` busybox issue with Grafana — disabled in values (`initChownData.enabled: false`).

## Docs

- [docs/README.md](docs/README.md) — full stack overview, access URLs, LogQL snippets, adding metrics for new apps
- [docs/MAINTENANCE.md](docs/MAINTENANCE.md) — restart, retention bump, password rotation, troubleshooting checklist

Also rendered live at https://docs.stoat-perch.ts.net (sidebar → Monitoring).
