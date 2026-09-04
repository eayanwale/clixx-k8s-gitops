# clixx-gitops

GitOps deployment of the CliXX Retail app onto a self-managed Kubernetes cluster — no EKS. Argo CD reconciles the cluster from this repo; a small set of shell scripts and a Jenkins pipeline handle the parts Argo CD deliberately doesn't own (secrets, registry auth, waking stopped infra).

## Cluster

Manual `kubeadm` cluster — one control-plane node, one worker, both EC2, provisioned by `scripts/control-setup-k8s.sh` / `scripts/worker-setup-k8s.sh`. No managed control plane, no EKS add-ons; CNI, CSI drivers, and ingress are all installed by hand.

## What's in this repo

| Path | Purpose |
|---|---|
| `apps/` | Argo CD `Application` CRs — `clixx-app.yaml` (the app), `monitoring-app.yaml` (Prometheus/Grafana). |
| `manifests/` | Plain Kustomize tree Argo CD reconciles: namespace, EFS `StorageClass`/`PersistentVolumeClaim`, the app `Deployment`, an internal LB `NodePort` service, `Ingress`, `ClusterIssuer` for TLS. |
| `scripts/sync_secrets.sh` | Pulls DB credentials from SSM Parameter Store and syncs them into a `clixx-secrets` K8s Secret. Run on a cron, not by Argo CD — secrets stay out of git entirely. |
| `scripts/refresh_ecr_login.sh` | Refreshes the `ecr-registry-key` image-pull secret from a short-lived ECR token (`aws ecr get-login-password`), since ECR auth tokens expire every 12 hours. |
| `Jenkinsfile` | Wakes the dev-account EC2/RDS infra when stopped, installs Argo CD + Image Updater, provisions the image-pull/git-repo secrets, applies the `Application` CR, and forces a sync. Runs on-demand and via GitHub webhook. |
| `docs/` | Runbooks: the Argo CD/GitOps rollout plan, custom-domain ingress, K8s secrets sync, Prometheus/Grafana setup. |

## How secrets actually flow

Nothing sensitive is ever committed. `wp-config.php` reads its DB config via `getenv()`, backed by a Secret that `sync_secrets.sh` populates straight from SSM (`--with-decryption`) on a schedule — Argo CD never sees the values and doesn't reconcile the Secret object's contents. Same pattern for registry auth: `refresh_ecr_login.sh` re-derives the ECR pull token instead of storing one.

## Networking

`ingress-nginx` in front of the app, TLS via `ClusterIssuer` (Let's Encrypt), fronted by an ALB on a custom domain. EFS (via the `efs.csi.aws.com` CSI driver) backs `wp-config.php`'s persistent volume so config survives pod rescheduling.

## Known gaps

- Cluster is manually provisioned kubeadm, not EKS — a deliberate scope choice for this project, not an oversight, but it means no managed control-plane HA/patching.
- DB config injection (`scripts/kube-init.sh`/`kube-init.py`, pulling SSM params into `wp-config.php` via `kubectl exec`) is still a manual step; see `docs/argocd-gitops-plan.md` for the plan to bring it under GitOps.
- Argo CD's native Git webhook is deliberately not used — it would require exposing `argocd-server`. Jenkins relays sync triggers instead (`argocd.argoproj.io/refresh: hard` annotation).
