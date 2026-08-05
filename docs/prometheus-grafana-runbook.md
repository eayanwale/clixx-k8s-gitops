# Runbook: Prometheus + Grafana (https://k8s.clixx.example.com/grafana)

Runbook, not implemented code — you run each phase yourself. Written
2026-08-04, updated 2026-08-05 after the first real run surfaced three
things this plan didn't originally cover (Phases D, F, G below).

## Context

No monitoring exists on the cluster today (confirmed — no
ServiceMonitor/Prometheus/Grafana manifests anywhere in this repo).

**Why Helm here, when the rest of the repo avoids it:**
`docs/custom-domain-ingress-runbook.md` deliberately skipped Helm for
ingress-nginx ("No Helm required — using the controller's static manifests,
same plain-`kubectl` style as the rest of this repo"). Prometheus/Grafana is
the exception to that: `kube-prometheus-stack` ships ~50 CRDs (`Prometheus`,
`Alertmanager`, `ServiceMonitor`, `PrometheusRule`, …) plus the Operator,
Grafana, node-exporter and kube-state-metrics — hand-writing that isn't
practical. To keep it GitOps (not an imperative `helm install` from a
laptop), it's deployed as its own **ArgoCD Application with a Helm source**,
same `automated`/`selfHeal`/`prune` pattern as `apps/clixx-app.yaml`, just
pointed at a Helm repo instead of this repo's `manifests/` path.

**Namespace:** new `monitoring` namespace, separate from `clixx-prod` — keeps
blast radius (and the CRD-heavy install) away from the app.

**TLS/ingress:** per `docs/custom-domain-ingress-runbook.md`, the ALB in
front of the cluster terminates HTTPS for `k8s.clixx.example.com` via ACM
and is *supposed to* forward plain HTTP to ingress-nginx's fixed NodePort
`30080`. In practice the ALB's target group was still pointed at
`clixx-service`'s original NodePort `30000` from before ingress-nginx
existed — see Phase F, this bit Grafana specifically because `/grafana`
only exists as an ingress-nginx rule, not on `clixx-service` itself. No new
ALB listener, ACM cert, or DNS record was needed for Grafana itself — same
host, just a new path. Grafana's Ingress has to be its **own** object in the
`monitoring` namespace (an Ingress backend must live in the same namespace as
the Ingress itself, and `clixx-ingress.yaml` lives in `clixx-prod`) —
ingress-nginx merges rules for the same host across separate Ingress objects
and matches the most specific path, so adding `/grafana` this way is safe and
doesn't touch `clixx-ingress.yaml`.

**Subpath serving:** Grafana defaults to assuming it's served from `/`.
Serving it from `/grafana` needs `root_url` + `serve_from_sub_path: true` set
in its config — otherwise its own JS/CSS asset links break. Done in
`apps/monitoring-app.yaml` (Phase C).

**Secrets:** the Grafana admin password stays out of git, same pattern as
`clixx-secrets` in `docs/k8s-secrets-runbook.md` — created by hand as a
Secret, referenced by name in the Helm values, never committed. See Phase G
for a gotcha this ran into.

## Phase A — Confirm prerequisites

ingress-nginx should already be running per
`docs/custom-domain-ingress-runbook.md` Phase A:
```bash
kubectl -n ingress-nginx get pods
kubectl -n ingress-nginx get svc ingress-nginx-controller
```
If it's not there, do that runbook's Phase A first — this one assumes it.

## Phase B — Namespace + Grafana admin Secret (created by hand, outside git)

```bash
kubectl create namespace monitoring
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='<generate a strong password>'
```
Keys `admin-user`/`admin-password` match the chart's default
`grafana.admin.userKey`/`passwordKey`, referenced via `existingSecret` in
`apps/monitoring-app.yaml` — no need to override those key names.

## Phase C — ArgoCD Application (Helm source)

Done in **`apps/monitoring-app.yaml`** — an `Application` pointed at the
`kube-prometheus-stack` chart (source `repoURL:
https://prometheus-community.github.io/helm-charts`), destination namespace
`monitoring`. That file is the source of truth for the actual Helm values
(Grafana's `existingSecret`, ingress host/path, `serve_from_sub_path`,
disabled Prometheus/Alertmanager persistence) — read it directly rather than
trusting a copy pasted here, since it can drift from this doc.

Two non-obvious things it's relying on:
- `syncOptions: [ServerSideApply=true]` — not optional. This chart's CRDs are
  large enough that plain `kubectl apply` (client-side, ArgoCD's default)
  hits Kubernetes' ~256KB `last-applied-configuration` annotation limit and
  fails — a known `kube-prometheus-stack` gotcha, not specific to this
  cluster.
- No `rewrite-target` annotation on the Grafana ingress block:
  `serve_from_sub_path` means Grafana itself understands it's mounted at
  `/grafana`, so the path should reach it unmodified.

Bootstrap it once by hand, same as `apps/clixx-app.yaml`:
```bash
kubectl apply -f apps/monitoring-app.yaml
```

## Phase D — Pin the chart version (don't skip this)

`targetRevision` needs a real chart version, not a placeholder — leaving it
unset/invalid produces `Unknown` sync status and zero pods, no clearer error
than that. Current pin: **`86.1.0`**. Check
https://artifacthub.io/packages/helm/prometheus-community/kube-prometheus-stack
for whatever's actually current before reusing this value later — chart
releases move fast enough that this number will be stale by the time anyone
re-reads this doc.

## Phase E — Commit, push, verify

```bash
git add apps/monitoring-app.yaml
git commit -m "Add kube-prometheus-stack monitoring Application"
git push origin development
```
Then:
```bash
kubectl -n argocd get application kube-prometheus-stack   # Synced / Healthy
kubectl -n monitoring get pods
```
Sanity-check routing directly against ingress-nginx before trusting the real
domain (bypasses DNS/ALB entirely, isolates whether ingress-nginx itself is
configured right):
```bash
curl -v -H "Host: k8s.clixx.example.com" http://localhost:30080/grafana/
```
Should 302 to `/grafana/login`. If that works but the real domain doesn't,
the problem is upstream of ingress-nginx — see Phase F.

Log in with the `grafana-admin` Secret's credentials (Phase G), confirm
dashboards render and Status → Data sources → Prometheus is green.
Optionally check scrape targets directly — the port-forward runs on the
control-plane node, so reaching it locally needs the same two-hop tunnel as
ArgoCD's UI (`docs/argocd-gitops-plan.md` Phase 1, including that phase's
note on what to do if the tunnel refuses connections):
```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# separately, from your local machine:
ssh -L 9090:localhost:9090 ubuntu@<control-plane-ip>
# then open http://localhost:9090/targets
```

## Phase F — ALB target group has to point at ingress-nginx, not clixx-service

Not a Prometheus/Grafana-specific step, but this is what actually blocked
reaching `/grafana` through the real domain, so it belongs here: this
cluster's ALB pre-dates ingress-nginx (`docs/custom-domain-ingress-runbook.md`
Phase B), and its target group was still pointed at `clixx-service`'s
original NodePort `30000`, never repointed to ingress-nginx's `30080`. That
means all traffic through the real domain was hitting `clixx-service`
directly, bypassing ingress-nginx entirely — `/` "worked" only because
that's WordPress's own home page; any other path (including `/grafana`)
404'd straight out of Apache.

Fix (in the AWS console or CLI, outside this repo — check
`aws elbv2 describe-target-groups` for the current port first):
1. Create a new target group, port `30080`, same health-check path as the
   existing one.
2. Register the node instance(s) at port `30080`, wait for `healthy`. If it
   won't go healthy, check the target group's health-check port (must also
   be `30080` or "traffic port", not a stale `30000` override) and the node
   instances' security group (must allow inbound `30080` from the ALB's
   security group — `docs/custom-domain-ingress-runbook.md` Phase B, item 4).
3. Edit the 443 listener's default action to forward to the new target
   group instead of the old one.
4. Verify both `/` and `/grafana` work through the real domain, then
   delete/leave the old `:30000` target group.

Deliberately not done as a delete-then-recreate on the existing target
group — that leaves a window with nothing registered at all mid-change.

## Phase G — Grafana admin password: how to actually change it

Retrieve the current credentials from the Secret (never logged/committed
anywhere):
```bash
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-user}' | base64 -d; echo
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

**Changing it only sticks one way, because of the Phase H persistence
decision below.** Grafana has no PVC here, so it rebuilds its DB from
scratch — including the admin password, sourced fresh from
`GF_SECURITY_ADMIN_PASSWORD` (which comes from this Secret) — on every pod
restart. A password changed through Grafana's own UI (Profile → Change
password) works until the next restart (ArgoCD `selfHeal`, node reschedule,
manual rollout), then reverts. The durable way is to update the Secret and
restart the pod so it re-inits with the new value:
```bash
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='<new strong password>' \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring rollout restart deployment kube-prometheus-stack-grafana
kubectl -n monitoring rollout status deployment kube-prometheus-stack-grafana
```

## Phase H — Optional follow-ups (not required to close this out)

- **Persistent storage:** `wp-config-efs` (EFS/NFS) is bound to a specific
  filesystem/basePath for the WordPress use case and NFS-backed volumes are
  not recommended for Prometheus's WAL. If dashboards/alert history/admin
  password changes need to survive pod restarts (see Phase G), that means
  standing up the EBS CSI driver and a new block-storage `StorageClass`,
  then setting `prometheusSpec.storageSpec` (and `grafana.persistence`) —
  separate piece of work, out of scope here.
- **Scraping clixx itself:** `clixx-service`/the app currently expose no
  `/metrics` endpoint, so there's nothing app-level to scrape yet beyond
  cluster/node metrics the chart collects by default (kube-state-metrics,
  node-exporter, kubelet/cAdvisor). Add a `ServiceMonitor` once the app
  exposes metrics.
- **Alertmanager routing:** ships with default config only — no
  Slack/email/PagerDuty receiver configured. Add one in the `alertmanager`
  values block when there's somewhere for alerts to actually go.
- **ArgoCD UI over the same ingress:** considered exposing ArgoCD at
  `/argocd` the same way, decided against it (2026-08-05) — see
  `docs/argocd-gitops-plan.md` Phase 1, still SSH-tunnel-only on purpose.
