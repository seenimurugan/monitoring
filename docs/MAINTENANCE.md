# Monitoring — maintenance

Operational cheat sheet for Prometheus + Grafana + Loki. For an intro to what's installed, see [README](README.md).

---

## Restart everything

```bash
kubectl rollout restart -n monitoring deployment/grafana
kubectl rollout restart -n monitoring statefulset/prometheus-kps-prometheus
kubectl rollout restart -n monitoring statefulset/loki
kubectl rollout restart -n monitoring daemonset/alloy
```

## Re-apply config changes

After editing any values file in `values/`:

```bash
./deploy.sh
```

The script is idempotent — `helm upgrade --install` for each chart.

## Drop and reinstall (data loss)

```bash
helm uninstall kps loki alloy -n monitoring
kubectl delete pvc -n monitoring --all
kubectl delete ns monitoring
./deploy.sh
```

---

## Bump retention

Edit `values/loki-values.yaml`:
```yaml
loki:
  limits_config:
    retention_period: 720h   # 30 days
```

Edit `values/kube-prometheus-stack-values.yaml`:
```yaml
prometheus:
  prometheusSpec:
    retention: 30d
    retentionSize: "60GB"
```

Then bump the PVC sizes too (`storageSpec` and `singleBinary.persistence.size`) and re-run `./deploy.sh`. PVC expansion happens online for `local-path`.

---

## Rotate admin password

UI: top-right user icon → **Change password**. Then update `GRAFANA_ADMIN_PASSWORD` in `.env` and re-run `./deploy.sh` to rotate the `grafana-admin-secret` in Kubernetes. The values files do not contain the password — it is always sourced from `.env` at deploy time.

---

## A pod's logs aren't showing up in Grafana

Checklist:

1. Pod is running and emitting logs (`kubectl logs -n <ns> <pod>`).
2. Pod has at least one of these labels: `app=<name>` or `app.kubernetes.io/instance=<name>`.
3. Alloy is running on the node: `kubectl get ds -n monitoring alloy`.
4. Alloy is healthy:
   ```bash
   kubectl logs -n monitoring -l app.kubernetes.io/name=alloy --tail=50 | grep -iE "error|drop"
   ```
5. Loki is up: `kubectl get pod -n monitoring loki-0`.
6. Direct query at the Loki API to bypass Grafana caching:
   ```bash
   kubectl port-forward -n monitoring svc/loki 3100:3100 &
   curl -s "http://localhost:3100/loki/api/v1/label/app/values" | jq .
   ```

If Alloy says `429 Too Many Requests` from Loki, the ingestion-rate limit is being hit — bump `loki.limits_config.ingestion_rate_mb` (default 4MB/s).

---

## A custom-metrics target isn't being scraped

1. Confirm the ServiceMonitor exists and matches your Service labels:
   ```bash
   kubectl get servicemonitor -A
   kubectl describe servicemonitor -n homelab <name>
   ```
2. Confirm the Service has a named port matching `spec.endpoints[].port`:
   ```bash
   kubectl get svc -n homelab <svc> -o yaml | grep -A3 ports
   ```
3. Check Prometheus targets:
   ```bash
   kubectl port-forward -n monitoring svc/kps-prometheus 9090:9090 &
   open http://localhost:9090/targets
   ```
   Filter for the ServiceMonitor name — common failures: `connection refused` (wrong port), `404` (wrong path), or `down: no such target` (label-selector mismatch).
4. Hit the app's metrics endpoint manually to confirm the format:
   ```bash
   kubectl port-forward -n homelab svc/<app> <port>:<port> &
   curl -s http://localhost:<port>/<path> | head -20
   # Should look like:  myapp_requests_total{...} 42
   ```

---

## Reload a Grafana dashboard from JSON

```bash
# Drop a dashboard JSON into a ConfigMap with the right label —
# the Grafana sidecar auto-imports it within ~60s.
kubectl create configmap mydash -n monitoring \
  --from-file=mydash.json \
  --dry-run=client -o yaml \
| kubectl label --local -f - grafana_dashboard=1 -o yaml --dry-run=client \
| kubectl apply -f -
```

---

## Quick health one-liner

```bash
kubectl get pods,pvc -n monitoring
```

All pods should be `Running` with READY equal across the column. Loki and Grafana have multiple containers (the canary / sidecars).

---

## OrbStack k3s per-container metrics limitation

**Symptom:** Built-in Kubernetes dashboards ("Compute Resources / Pod", "Compute Resources / Namespace (Pods)") show "No data" for the live CPU-Usage and Memory-Usage time-series panels. The CPU/Memory **Quota** tables at the bottom still work.

**Cause:** OrbStack's k3s exposes only machine-level metrics through the kubelet's `/metrics/cadvisor` endpoint — no per-container series. A standalone cAdvisor DaemonSet sees cgroups but can't read OrbStack's Docker image-layer metadata (`/var/lib/docker/image/overlayfs/layerdb/mounts/<id>/mount-id` doesn't exist in OrbStack's storage layout), so it can't enrich cgroup IDs with namespace/pod/container labels. Verified May 2026 on OrbStack 1.10 + k3s v1.33.9.

**What still works** — and covers ~90% of "is my cluster OK?" questions:

| Question | Works via |
|---|---|
| Is a pod restarting? OOMKilled? Running? | kube-state-metrics → `kube_pod_status_phase`, `kube_pod_container_status_restarts_total` |
| What's the host CPU / memory / disk pressure? | node-exporter — see "Node Exporter Full" dashboard |
| What CPU/memory has each pod **requested/limited**? | kube-state-metrics — see "Compute Resources / Namespace (Pods)" → CPU Quota table |
| What are my apps logging? | Loki (the headline feature — fully working) |
| Custom app metrics (HTTP latency, queue depth, JVM heap…) | App exposes `/metrics`, you add a ServiceMonitor — see [README §Adding metrics for a new app](README.md#adding-metrics-for-a-new-app) |

**Workarounds, in order of practicality:**

1. **Live with it.** For a homelab the gap doesn't matter much — kube-state-metrics + node-exporter + your own app metrics cover the real signals.
2. **Use `kubectl top pods -n homelab`** for ad-hoc real-time pod CPU/memory. (Requires `metrics-server` — see below.)
3. **Install `metrics-server` Helm chart** if you want `kubectl top` to work — it queries the kubelet's `/metrics/resource` endpoint which *does* expose per-pod CPU/memory on OrbStack, just not in the format Prometheus dashboards expect.
4. **Move to a real Linux box** running upstream k3s — cAdvisor works correctly there.

> **Do not** try installing a standalone cAdvisor DaemonSet without verifying it stays narrow — we found that an unrestricted privileged + hostPID + rootfs-mounted cAdvisor briefly took down the OrbStack k3s API server. Even with a constrained config, cAdvisor cannot map cgroup IDs to pod metadata on OrbStack.
