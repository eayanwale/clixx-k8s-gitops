# ArgoCD + GitOps rollout plan for clixx-gitops

Runbook, not implemented code — you run each phase yourself. Written 2026-07-24
against the current repo state (manifests-only, no `apps/` content — the earlier
ArgoCD/Jenkins bootstrap was built and then explicitly reverted; this plan
redoes it with one change: **image sync is decoupled from the image-build
pipeline**, per your call).

## Reference docs

Sources actually used while writing/debugging this plan — worth reading
directly rather than trusting my summary of them:

- Argo CD install manifests & operator manual: https://argo-cd.readthedocs.io/en/stable/
- Argo CD `Application` CRD reference (spec fields used in Phase 2): https://argo-cd.readthedocs.io/en/stable/operator-manual/application.yaml
- Argo CD Image Updater docs (annotations, update strategies, write-back methods used in Phase 3): https://argocd-image-updater.readthedocs.io/en/stable/
- Argo CD Image Updater install page specifically (correct `config/install.yaml` path, and why same-namespace-as-argocd is the recommended install target over a separate namespace): https://argocd-image-updater.readthedocs.io/en/stable/install/installation/
- Kubernetes Server-Side Apply concepts (why `--server-side --force-conflicts` is needed for the CRD install, Phase 1/3/4): https://kubernetes.io/docs/reference/using-api/server-side-apply/
- The specific `applicationsets.argoproj.io` annotation-size failure and its fix: https://devopscube.com/argocd-metadata-annotations-too-long/ and https://www.arthurkoziel.com/fixing-argocd-crd-too-long-error/
- Kustomize `images:` transformer (used in Phase 2 to decouple the image tag from the raw manifest): https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/images/
- Argo CD's native Git webhook endpoint (why we're deliberately *not* using
  it, since it'd require exposing `argocd-server`): https://argo-cd.readthedocs.io/en/stable/operator-manual/webhook/
- `argocd.argoproj.io/refresh: hard` annotation — community-documented
  kubectl-only way to force reconciliation without the ArgoCD CLI/API,
  used in Phase 2's Jenkins-relayed sync trigger: https://github.com/argoproj/argo-cd/discussions/7762
- `kubectl rollout restart` vs ArgoCD `selfHeal` conflict (why Phase 4's
  final step deletes pods directly instead): https://github.com/argoproj/argo-cd/issues/25836
- Argo CD private repository credentials (the `argocd.argoproj.io/secret-type: repository`
  labeled-Secret pattern used in Phase 2 for `clixx-gitops-repo-creds`): https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#repositories

## Current state (verified against the repo, not assumed)

- **Cluster**: self-managed kubeadm, 1 control-plane + 1 worker, both EC2,
  both currently **stopped**. Built by `scripts/control-setup-k8s.sh` /
  `scripts/worker-setup-k8s.sh`.
- **App manifests**: `manifests/` is a plain Kustomize tree (`namespace-clixx.yaml`,
  `storage-class.yaml` [EFS CSI], `pvc.yaml`, `clixx-deployment.yaml`,
  `clixx-lb-np.yaml`) with no ArgoCD `Application` CR yet.
- **Image**: `clixx-deployment.yaml` pins both the init container and main
  container to `111111111111.dkr.ecr.us-east-1.amazonaws.com/clixx-repository:clixx-image-latest`
  — a floating tag. `imagePullPolicy: Always` makes a manual `kubectl rollout
  restart` pick up a new digest, but a GitOps controller diffing the manifest
  text sees no change on its own.
- **Image-build pipeline**: `CliXX_Retail_Repository/Jenkinsfile-1`, a
  separate repo/pipeline you do not want this work coupled to. It pushes
  `clixx-image:<VERSION>` and `clixx-image:latest` (both tags, same repo) to
  ECR on every run. Confirmed: nothing here needs to change.
- **DB config**: still manual — `scripts/kube-init.sh`/`kube-init.py` pull
  4 SSM params and `kubectl exec` them into `wp-config.php` by hand. Out of
  scope for this plan (see "Not in scope" below), but the earlier PreSync-Job
  design still applies if you want it later.
- **RDS**: stopped.

## Architecture locked in for this round

- **ArgoCD**: installed in-cluster, watches `clixx-gitops` (this repo) via an
  `Application` CR pointed at `manifests/`.
- **Image sync**: **ArgoCD Image Updater**, running independently in-cluster.
  It polls ECR directly (not Jenkins, not a webhook from the build pipeline)
  and writes the new image reference back into this repo's git history via
  its own commit. ArgoCD then syncs off that commit like any other change.
  This is the piece that satisfies "get images from another pipeline" without
  creating any dependency on `Jenkinsfile-1`.
- **Jenkins' role here**: a bootstrap pipeline *in this repo* that installs/
  updates ArgoCD and the Image Updater on the cluster (idempotent, run
  on-demand — not triggered by image builds). This is the "within a Jenkins
  pipeline" part of your ask.
- **Tag tracking strategy**: track the **versioned tag** (`clixx-image-1.0.N`),
  not the `latest` alias. Confirmed from ECR: every push always produces both
  tags, `latest` always points at the newest one, and the version number is
  monotonically increasing (gaps like a missing `.36` are just skipped/failed
  builds, not reused numbers) — so Image Updater's `latest`-by-push-date
  strategy against the versioned tags is reliable, and gives readable
  rollback (`clixx-image-1.0.38` in a git diff means something; a bare
  `sha256:...` doesn't). Zero changes to `Jenkinsfile-1` either way, since
  it's already pushing this tag today.

## Not in scope this round (carried over from the earlier design, still sound, redo later if wanted)

- PreSync Job replacing `kube-init.sh` (SSM → K8s Secret for DB creds).
- PostSync Job updating `wp_options.siteurl`/`home` with the LB DNS.

## Phase 0 — Bring infra back up

Folded into Phase 4's "wake everything up" job below, since you want a
single button for this rather than doing it by hand each time. Kept here as
a standalone reference for the commands it wraps:

```bash
aws ec2 start-instances --instance-ids <control-plane-id> <worker-id>
aws rds start-db-instance --db-instance-identifier <your-db-id>
```

Both EC2 instances need to reach `running`/`2/2 checks passed`, and RDS
`available` (RDS restart is the slow one, budget 5-10 min), before the
cluster is usable:

```bash
ssh ubuntu@<control-plane-ip>
kubectl get nodes            # both nodes Ready
kubectl get pods -n clixx-prod
```

If the worker doesn't rejoin automatically after a stop/start cycle, rerun
the `kubeadm join` command from `worker-setup-k8s.sh` (token may have expired
— `kubeadm token create --print-join-command` on the control plane to mint a
new one).

## Phase 1 — Install ArgoCD

On the control-plane node (it already has `~/.kube/config`):

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server
```

`--server-side --force-conflicts` is required, not optional: plain
client-side `kubectl apply` stores the whole manifest in a
`kubectl.kubernetes.io/last-applied-configuration` annotation, and the
`applicationsets.argoproj.io` CRD schema is large enough to exceed etcd's
262144-byte annotation cap (`metadata.annotations: Too long`). Server-side
apply uses `managedFields` instead of that annotation, which has no such
limit. `--force-conflicts` covers the case where a failed client-side apply
already wrote partial field ownership. Same flags apply to the Image Updater
install in Phase 3 and both installs as they're re-applied in Phase 4.

No ingress/LB controller exists on this cluster (`clixx-lb-np.yaml` is a bare
NodePort Service), so expose the ArgoCD UI/API the same way you already reach
the cluster for the MCP server — SSH tunnel, not a public endpoint:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
# from your local machine, in a separate terminal:
ssh -L 8080:localhost:8080 ubuntu@<control-plane-ip>
```

Then `https://localhost:8080` locally. Initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

Rotate/delete `argocd-initial-admin-secret` after first login.

## Phase 2 — Point ArgoCD at this repo

Add an `Application` CR (new file, e.g. `apps/clixx-app.yaml` — this repo's
own `apps/` folder is currently empty):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: clixx
  namespace: argocd
spec:
  project: default
  source:
    repoURL: <clixx-gitops git remote URL>
    targetRevision: development
    path: manifests
  destination:
    server: https://kubernetes.default.svc
    namespace: clixx-prod
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Apply it once by hand (`kubectl apply -f apps/clixx-app.yaml`) to bootstrap —
after that ArgoCD manages itself off git.

**`clixx-gitops` is a private repo — ArgoCD's core controller needs its own
registered read credential to clone it at all.** Confirmed private (a plain
unauthenticated `GET /repos/eayanwale/clixx-gitops` against the GitHub API
returns 404, GitHub's standard behavior for private repos hidden from
unauthenticated callers). This is a separate concern from the `git-creds`
secret below, which is only for Image Updater's write-back commits — without
this one too, the very first sync attempt fails on a repo-not-found/auth
error even if everything else in Phase 4 succeeds. Standard ArgoCD
private-repo pattern: a Secret labeled `argocd.argoproj.io/secret-type:
repository` in the `argocd` namespace, same PAT:

```bash
kubectl create secret generic clixx-gitops-repo-creds -n argocd \
  --from-literal=type=git \
  --from-literal=url=https://github.com/eayanwale/clixx-gitops.git \
  --from-literal=username=x-access-token \
  --from-file=password=/dev/stdin   # PAT piped in, same stdin pattern as git-creds below
kubectl label secret clixx-gitops-repo-creds -n argocd argocd.argoproj.io/secret-type=repository --overwrite
```

Also added an explicit `argocd-image-updater.argoproj.io/git-credentials-secret:
argocd/git-creds` annotation on the `Application` (not shown in the snippet
above, see `apps/clixx-app.yaml`) rather than relying on Image Updater's
default credential-resolution behavior for write-back — wasn't confident
enough in the exact default lookup order to leave it implicit.

**Sync trigger — relay through Jenkins, don't expose ArgoCD's API publicly.**
ArgoCD has its own native `/api/webhook` endpoint for exactly this, but it'd
require exposing `argocd-server` outside the cluster, which this setup
deliberately avoids (Phase 1 keeps it SSH-tunnel-only). Jenkins, however,
already has a webhook receiver reachable from GitHub for the other repos in
this workspace — reuse that instead of standing up a new public endpoint:

**One pipeline, not two.** Originally planned as a separate lightweight job;
merged into the same `Jenkinsfile` as Phase 4 instead, since it needs the
exact same SSH/`kubectl` access either way:

1. Add a GitHub webhook on `clixx-gitops` (push to `development` — the
   branch actually in use, confirmed via `git branch`) pointed at this
   Jenkins job's URL, same mechanism already used for the other repos'
   pipelines.
2. The `Jenkinsfile` declares `triggers { githubPush() }`, so it runs
   automatically on every push — and stays manually runnable for the
   "wake everything up" case, same file either way.
3. Its `Force immediate Argo CD sync` stage forces an immediate
   reconciliation instead of waiting on ArgoCD's default 3-minute poll:
   ```bash
   kubectl -n argocd annotate application clixx argocd.argoproj.io/refresh=hard --overwrite
   ```
   `syncPolicy.automated` (already set above) then acts on the refreshed
   status within seconds — no `argocd` CLI login/token needed, just the
   `kubectl` access Jenkins already has over SSH.
4. This stage runs unconditionally on every trigger — both when the Image
   Updater's own commit lands *and* when you push a manifest change by
   hand — same trigger path either way. Every other stage in the same
   pipeline (infra start/wait, ArgoCD/Image Updater install, force-fresh-pods)
   is skip-checked so a webhook-triggered run where infra's already up does
   almost nothing beyond this sync trigger.

This keeps every network-facing surface as it already exists today (Jenkins
public, ArgoCD private) rather than adding a new one.

`kustomization.yaml` needs an `images:` block so both Kustomize and the Image
Updater have one place to override the tag/digest:

```yaml
images:
  - name: 111111111111.dkr.ecr.us-east-1.amazonaws.com/clixx-repository
    newTag: clixx-image-latest
```

`clixx-deployment.yaml`'s two image references do **not** need editing —
Kustomize's `images:` transformer matches containers by image name and
overrides the tag regardless of what tag is currently hardcoded in the raw
manifest, so the existing `:clixx-image-latest` suffixes are harmless and
get overridden at build time either way. (Confirmed against Kustomize's
`images` field docs, linked in Reference docs above — correcting an earlier,
wrong note in this doc that said this edit was needed.)

## Phase 3 — Install ArgoCD Image Updater (independent of Jenkinsfile-1)

Installs into the **same `argocd` namespace** as ArgoCD itself, not a
separate one — upstream docs call this the recommended path since it works
with default namespace-scoped RBAC out of the box. A separate namespace is
supported but needs four extra manual steps (env vars pointing at the ArgoCD
namespace, patching two hardcoded metrics ClusterRoleBindings, and a
hand-written Role/RoleBinding granting cross-namespace access to
`applications`/`imageupdaters`/`secrets`) — unnecessary complexity for a
single-tenant cluster like this one. Also note the manifest path is
`config/install.yaml`, not `manifests/install.yaml`:

```bash
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/config/install.yaml
```

**ECR read access**: the Image Updater pod needs `ecr:DescribeImages`,
`ecr:ListImages`, `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`. Your
nodes already authenticate to this same ECR repo for `docker login` in
`control-setup-k8s.sh`/`worker-setup-k8s.sh`, so there's almost certainly an
instance profile with ECR pull rights already attached — confirm it also
covers `Describe`/`List` (pull-only profiles sometimes only get
`GetAuthorizationToken` + `BatchGetImage`, not `DescribeImages`/`ListImages`,
which the Image Updater needs to enumerate tags/digests). Add an inline
policy statement if missing; no new IAM identity needed if the instance
profile already covers it.

**Git write-back credentials**: repo is on GitHub, HTTPS + PAT — same pattern
you already have wired into Jenkins for this repo
(`https://<pat>@<repo-url>`). Reuse that PAT rather than minting a separate
one; if it's already a Jenkins credential, pull it from there when the
bootstrap pipeline creates this secret (Phase 4) instead of pasting it in by
hand. GitHub's convention for PAT-over-HTTPS is username = `x-access-token`,
password = the PAT itself:

```bash
kubectl -n argocd create secret generic git-creds \
  --from-literal=username=x-access-token \
  --from-literal=password=<the same PAT Jenkins uses for this repo>
```

**Annotate the Application** (edit `apps/clixx-app.yaml` from Phase 2) to
tell Image Updater what to watch and how to write back:

```yaml
metadata:
  annotations:
    argocd-image-updater.argoproj.io/image-list: clixx=111111111111.dkr.ecr.us-east-1.amazonaws.com/clixx-repository
    argocd-image-updater.argoproj.io/clixx.update-strategy: latest
    argocd-image-updater.argoproj.io/clixx.allow-tags: regexp:^clixx-image-\d+\.\d+\.\d+$
    argocd-image-updater.argoproj.io/write-back-method: git
    argocd-image-updater.argoproj.io/git-branch: development
```

`allow-tags` excludes the literal `clixx-image-latest` alias on purpose —
without that, Image Updater could see both the alias and the versioned tag
as separate candidates pointing at the same digest and flip-flop between
them. Matching only `clixx-image-<major>.<minor>.<patch>` with
`update-strategy: latest` (newest push timestamp among matches) tracks
exactly what `Jenkinsfile-1` most recently built, without watching or
modifying that pipeline at all.

## Phase 4 — Jenkins pipeline (this repo, one file, two trigger paths)

Single `Jenkinsfile` in `clixx-gitops` root. Runs both manually (the "wake
everything up" case) and automatically via `triggers { githubPush() }` on
every push (the sync-trigger case from Phase 2) — same stages either way,
made cheap to run on every push by skip-checking almost everything.

Every kubectl/docker/ECR command below runs **over SSH on the control-plane
node**, not on the Jenkins agent itself — `~/.kube/config` and the
ECR-authenticated Docker only exist there, and Jenkins (automation account)
reaches it purely via an SSH keypair, independent of AWS accounts. The two
direct AWS CLI calls (describe/start-instances, describe/start-db-instance)
are the only steps that run on the Jenkins agent itself, authenticated via
the existing `stackprog-dev` chained-assume-role profile — no stored AWS
credential needed for those either.

The control-plane node has **no Elastic IP** — its public IP changes on
every stop/start — so it's looked up each run by its `Name=k8control` tag,
not a fixed parameter.

1. Checkout.
2. **Check infra state & start if needed**: `aws ec2 describe-instances` /
   `aws rds describe-db-instances` first; only calls `start-instances` /
   `start-db-instance` for whatever isn't already `running`/`available`.
   Sets `env.INFRA_WAS_STOPPED`, which gates steps 3 and 10 below.
3. **Wait for readiness** (skipped entirely if `INFRA_WAS_STOPPED` is
   false): `aws ec2 wait instance-status-ok` / `aws rds wait
   db-instance-available` (RDS is the long pole on a real cold start).
4. **Discover control-plane IP**: `aws ec2 describe-instances --filters
   Name=tag:Name,Values=k8control` → `env.CP_HOST`, used by every SSH stage
   after this one.
5. **Cluster health check**: SSH in, `kubectl wait --for=condition=Ready
   nodes --all --timeout=90s` — fail fast here rather than pushing ArgoCD
   manifests at a half-up cluster. Handle the worker-rejoin/expired-token
   case from Phase 0 if it comes up.
6. **Recreate `ecr-registry-key`** (image pull secret, `clixx-prod` ns) —
   unconditional, not skip-checked: delete-then-recreate via the same `aws
   ecr get-login-password | docker login` + `kubectl create secret ...
   --type=kubernetes.io/dockerconfigjson` sequence as `control-setup-k8s.sh`.
   The embedded ECR auth token expires (~12h) on its own clock, independent
   of whether infra was just restarted, so "it already exists" doesn't mean
   "it's still valid."
7. **Install ArgoCD, skip if present**: checks `kubectl get namespace
   argocd` first; only runs `kubectl apply -n argocd --server-side
   --force-conflicts -f <argocd install manifest>` (see Phase 1 for why
   those flags are required) if the namespace doesn't exist yet.
8. **Install Image Updater, skip if present**: checks `kubectl get
   deployment argocd-image-updater -n argocd` (shares the `argocd`
   namespace — see Phase 3 — so there's no separate namespace to check);
   only applies the install manifest if missing.
9. **`git-creds` secret, create if missing** (Phase 3): checks
   `kubectl get secret git-creds -n argocd` first; creates it from the same
   Jenkins-stored PAT credential only if missing, or if `RECREATE_GIT_CREDS`
   is explicitly set true (for rotating the PAT later). Unlike
   `ecr-registry-key`, this one doesn't expire on its own — GitHub PATs are
   long-lived — so it's create-once, not refreshed every run. Checked rather
   than flag-gated-only, since the pipeline fires from a webhook with no
   human available to set that flag on the very first run.
10. **`clixx-gitops-repo-creds` secret, create if missing** (Phase 2): same
    create-if-missing/PAT-rotation pattern as `git-creds`, but this is
    ArgoCD's own repository-read credential (labeled
    `argocd.argoproj.io/secret-type: repository`) — required because the
    repo is private, and separate from `git-creds`, which is only for
    write-back.
11. **Deploy the Application CR, skip if pods already running**: checks for
    `Running` pods matching `app=clixx-web-app` in `clixx-prod` first; only
    runs `kubectl apply -f apps/clixx-app.yaml` if none are found.
12. **Force immediate ArgoCD sync** (unconditional, every run): `kubectl -n
    argocd annotate application clixx argocd.argoproj.io/refresh=hard
    --overwrite` — this is the actual sync-trigger relay from Phase 2, now
    just another stage in this same pipeline.
13. **Force fresh pods** (only when `INFRA_WAS_STOPPED` is true):
    `kubectl delete pods -n clixx-prod -l app=clixx-web-app` then `kubectl
    rollout status deployment/clixx-web-deployment`. Needed because a
    stop/start cycle leaves already-running pods with two things broken
    that a plain re-apply won't fix on its own: stale DB connections to the
    now-restarted RDS instance, and (if pods get rescheduled) the
    now-expired ECR auth from before the restart. Skipped on a plain
    webhook-triggered sync where infra was already up — a real image-tag
    change already rolls pods via its own template-hash change. Deliberately
    **not** `kubectl rollout restart` — that stamps a
    `kubectl.kubernetes.io/restartedAt` annotation onto the pod template,
    which isn't in git, and with `selfHeal: true` ArgoCD treats it as drift
    and reverts it on the next reconcile, which can leave the app flapping
    instead of cleanly restarting ([argoproj/argo-cd#25836](https://github.com/argoproj/argo-cd/issues/25836)).
    Deleting the pods directly gets the same fresh-pod outcome — the
    ReplicaSet recreates them from the current template — without touching
    the Deployment spec, so there's nothing for ArgoCD to fight.

`post { success { ... } }` prints the ArgoCD UI access reminder
(`ssh -L 8080:localhost:8080` + `kubectl -n argocd port-forward
svc/argocd-server 8080:443`, filled in with that run's `CP_HOST`) at the end
of every run, since the control-plane's IP changes each time and Phase 1's
tunnel command needs it.

Idempotent end to end — safe to rerun if a step fails partway (e.g. infra
was already running, or ArgoCD was already installed), and cheap enough to
run on every push via the webhook trigger.

## Phase 5 — Verify end to end

1. `kubectl -n argocd get application clixx` → `Synced`/`Healthy`.
2. Trigger a build in `Jenkinsfile-1` (unrelated repo, untouched) to push a
   new `clixx-image-1.0.N` version tag (and `clixx-image-latest` alongside
   it, as always).
3. Watch the Image Updater log: `kubectl -n argocd logs deploy/argocd-image-updater -f`
   — should detect the new version tag and push a commit to `clixx-gitops`.
4. Confirm the commit landed (new tag in `kustomization.yaml`'s
   `images:` block).
5. Confirm the Jenkins webhook job (Phase 2) fired off that commit and ran
   the `argocd.argoproj.io/refresh=hard` annotate step — `Application`
   should flip `OutOfSync` → `Synced` within seconds, not the 3-minute
   default poll.
6. `kubectl -n clixx-prod rollout status deploy/clixx-web-deployment` shows
   the new pods, then confirm in-browser via the existing NodePort/LB.

## Decisions resolved this round (2026-07-24)

- **Tag strategy**: versioned tags (`clixx-image-1.0.N`) via `update-strategy:
  latest`, not digest-on-`latest`. Confirmed from ECR data that the versioned
  tag is always pushed alongside `latest` and sorts reliably by push date.
- **Git write-back auth**: GitHub, HTTPS + PAT, reusing the same PAT already
  wired into Jenkins for this repo (`https://<pat>@<repo-url>` pattern) —
  no separate credential to provision.
- **Infra wake-up**: folded into Phase 4 as one job (start EC2/RDS → wait →
  health-check → apply ArgoCD/Image Updater) rather than a manual Phase 0
  every time.

No open questions remain — next step is implementation whenever you're
ready to move off plan-only.
