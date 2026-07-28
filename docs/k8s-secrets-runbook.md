# Runbook: K8s Secrets for clixx (SSM → Secret sync script)

Runbook, not implemented code — you run each phase yourself. Written
2026-07-28 against the current repo state (branch `development`). This is
the deferred "SSM → K8s Secret" item noted as out-of-scope in
`docs/argocd-gitops-plan.md`'s original rollout plan, now being done.

## Context

`wp-config.php` (`manifests/wp-config.php`) currently hardcodes the DB
password, RDS host, and 8 WordPress auth salts (the salts are still the
literal placeholder `'put your unique phrase here'` — never populated).
`kustomization.yaml`'s `configMapGenerator` bakes this file verbatim into a
ConfigMap, which an initContainer copies onto a PVC-backed file the first
time a pod starts. Real DB values are patched in afterward by hand via
`scripts/kube-init.sh`/`kube-init.py`, which pull `/stack/clixx/{dbname,
db_user, db_password, db_host}` from SSM and `sed`/rewrite the file *inside
the running pod* — imperative, and it never touches the salts at all.

Goal: a Kubernetes Secret (`clixx-secrets`, namespace `clixx-prod`) consumed
as env vars by the Deployment, with `wp-config.php` reading `getenv()`
instead of literals. Rather than a new in-cluster Job/RBAC/PreSync-hook
system, this keeps the same shape as `kube-init.sh` today: **one bash script
that reads SSM and writes the result somewhere** — just writing a
`kubectl apply`-able Secret instead of `sed`-patching a file inside a pod.
Run it by hand or on a cron schedule on the control-plane node (same place
`kube-init.sh` already runs from, with working AWS creds and `~/.kube/config`
already in place).

Bonus over today's script: it also generates the 8 WP auth salts once (if
missing from SSM) and persists them back, so they get real values instead of
the placeholder string — something `kube-init.sh` never did.

## Phase A — AWS prerequisites

1. Confirm the 4 existing SSM params still exist (they must, since
   `kube-init.sh` already reads them today): `/stack/clixx/{dbname, db_user,
   db_password, db_host}`, `SecureString`, `us-east-1`.
2. No new IAM/instance-profile work needed for reads — whatever identity
   `kube-init.sh`/`kube-init.py` already runs as on the control-plane node
   (instance profile, or the `stackprog-dev` named profile `kube-init.py`
   uses) already has `ssm:GetParameter` there.
3. If you want the script to auto-generate+persist the 8 salts (recommended,
   see script below), that identity also needs `ssm:PutParameter` on
   `/stack/clixx/wp_*`. Otherwise, pre-create those 8 params by hand once and
   skip the generate-if-missing branch in the script.

## Phase B — New sync script

Implemented as **`scripts/sync_secrets.sh`** (committed), same style/location
as `kube-init.sh`, run on the control-plane node. Currently covers the 4 DB
values only — the salt-generation piece described above (generate-if-missing,
persist back to SSM) is not yet in that script; add it there if/when needed
rather than duplicating logic here.

Uses bash associative arrays + an args array (not string concatenation), so
values with special characters can't break the `kubectl` invocation — the
same class of bug `kube-init.sh`'s `sed` approach was already exposed to.

Make it executable: `chmod +x scripts/sync_secrets.sh`.

## Phase C — Schedule it

On the control-plane node, add a cron entry (adjust interval to taste — this
just needs to run before a pod that needs a fresh Secret restarts):
```bash
crontab -e
# add:
*/15 * * * * /home/ubuntu/clixx-gitops/scripts/sync_secrets.sh >> /var/log/clixx-secrets-sync.log 2>&1
```
Run it once by hand first to confirm it works and to seed the Secret before
the next pod restart:
```bash
./scripts/sync_secrets.sh
kubectl -n clixx-prod get secret clixx-secrets -o jsonpath='{.data}'
```

## Phase D — Point wp-config.php at env vars

Done in **`manifests/wp-config.php`**: the 4 `define()` calls under "MySQL
settings" now read `getenv()` instead of literals. The 8 salt `define()`
calls are untouched for now (still the placeholder string) since the salt
side of Phase B/A isn't implemented yet. `DB_CHARSET`, `DB_COLLATE`,
`$table_prefix`, `WP_DEBUG` are left as-is — not secrets.

## Phase E — Wire the Deployment to the Secret

Done in **`manifests/clixx-deployment.yaml`**: `envFrom`/`secretRef` against
`clixx-secrets` added to the **main** container (`clixx-web-app`) only — not
the `seed-wp-config` initContainer, which only copies the file and never
executes PHP.

## Phase F — One-time cleanup on the existing PVC

The initContainer only copies the template when the target file is
*absent* (`test -f ... || cp ...`). A real `wp-config.php` (old hardcoded
values, previously `sed`-patched by `kube-init.sh`) almost certainly already
exists on the `clixx-config-claim` PVC, so the new `getenv()`-based template
won't get copied over automatically. Delete the stale file once so the
initContainer re-seeds it on next pod start:
```bash
kubectl exec -n clixx-prod deploy/clixx-web-deployment -- rm -f /var/www/html/wp-config.php
kubectl delete pods -n clixx-prod -l app=clixx-web-app
```
Run this *after* Phase C has synced the Secret at least once, so the new
pods come up with env vars already available.

## Phase G — Commit, push, verify

1. `git add scripts/sync_secrets.sh manifests/wp-config.php manifests/clixx-deployment.yaml`
   and commit/push to `development` (ArgoCD `selfHeal` picks up the
   Deployment/ConfigMap change; the Secret itself is intentionally outside
   git, synced by the script instead).
2. `kubectl -n clixx-prod exec deploy/clixx-web-deployment -- env | grep -E 'DB_|AUTH_|SALT|NONCE'`
   — confirm all 12 vars are present.
3. Load the site via the existing NodePort/LB and confirm it resolves the DB
   correctly (login works, no "Error establishing a database connection").
4. `kubectl -n argocd get application clixx` → should be `Synced`/`Healthy`.

## Phase H — Optional follow-ups (not required to close this out)

- `scripts/kube-init.sh`/`kube-init.py` are now fully superseded (the new
  script covers the same 4 DB values plus the 8 salts they never touched).
  Consider deleting them once this is verified working, in a separate
  commit.
- `docs/argocd-gitops-plan.md`'s "Not in scope this round" section lists
  "PreSync Job replacing `kube-init.sh` (SSM → K8s Secret for DB creds)" —
  update that bullet to point at this runbook/script instead, so the doc
  stays accurate (the actual mechanism ended up being a cron script, not a
  PreSync Job).
