# Runbook: Custom domain (k8s.clixx.example.com) via Ingress

Runbook, not implemented code — you run each phase yourself.

## Context

`clixx-service` (`manifests/clixx-lb-np.yaml`) is a plain `NodePort` Service
(port 30000). Per `docs/argocd-gitops-plan.md`: "No ingress/LB controller
exists on this cluster" — this is a self-managed kubeadm cluster, so nothing
auto-provisions an Ingress→LB path the way EKS/GKE would.

An **ALB already fronts the nodes** (provisioned outside this repo). That
changes the TLS story: an ALB terminates HTTPS itself via an ACM
certificate and forwards plain HTTP to targets — it does not do TCP
passthrough. So TLS is handled at the ALB, **not** by cert-manager/Let's
Encrypt on the cluster; ingress-nginx here only needs to do HTTP
host-based routing.

Goal: `https://k8s.clixx.example.com` → ALB (TLS termination, ACM cert)
→ ingress-nginx (HTTP, host routing) → `clixx-service`. No Helm required —
using the controller's static manifests, same plain-`kubectl` style as the
rest of this repo.

## Phase A — Install the Ingress Controller

Bare-metal clusters use ingress-nginx's `baremetal` provider manifest (it
creates its own `NodePort` Service, same shape as `clixx-lb-np.yaml`):

1. Check the latest stable release tag at
   https://github.com/kubernetes/ingress-nginx/releases (pin to a specific
   tag, don't track a moving `main`/`latest` link).
2. Apply it:
   ```bash
   kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/<tag>/deploy/static/provider/baremetal/deploy.yaml
   ```
3. Confirm it came up and note the assigned NodePorts:
   ```bash
   kubectl -n ingress-nginx get pods
   kubectl -n ingress-nginx get svc ingress-nginx-controller
   ```
   By default the ports are randomly assigned in the 30000-32767 range.
   Since the ALB only ever talks plain HTTP to targets, you only need a
   fixed **HTTP** port — patch just that one, e.g. `30080` (avoid clashing
   with `clixx-service`'s existing `30000`):
   ```bash
   kubectl -n ingress-nginx patch svc ingress-nginx-controller -p \
     '{"spec":{"ports":[{"name":"http","port":80,"targetPort":"http","nodePort":30080}]}}'
   ```
   No HTTPS nodePort needed — the ALB is where 443 terminates.

## Phase B — ALB: ACM cert, listeners, target group

1. **Request a cert in ACM** for `k8s.clixx.example.com` and DNS-validate
   it (adds a one-time CNAME record in `example.com`'s zone — separate
   from the domain's own record in Phase C).
2. **443 listener**, protocol HTTPS, attach that ACM cert. Forward to a
   target group that points at the node instances on port **30080** (plain
   HTTP — the ALB decrypts, the target group carries unencrypted traffic).
3. **80 listener** — repurpose as a redirect: default action = redirect to
   HTTPS, rather than forwarding anywhere.
4. **Security group** on the node instances: allow inbound `30080` from the
   ALB's security group. You don't need `30443`/`443` open on the nodes at
   all — the ALB never talks to them over HTTPS.

## Phase C — DNS

In `example.com`'s DNS zone, point `k8s.clixx.example.com` at the
ALB (an ALIAS/A-record-to-ALB in Route 53, or a CNAME to the ALB's DNS name
if hosted elsewhere).

## Phase D — Ingress resource for clixx

Done in `manifests/clixx-ingress.yaml` (already listed in
`manifests/kustomization.yaml`'s `resources`): plain HTTP, no
`cert-manager.io/cluster-issuer` annotation and no `tls:` block, since the
ALB (not this Ingress) owns HTTPS.

## Phase E — Verify

```bash
curl -v https://k8s.clixx.example.com
```
Confirm it resolves, the ALB presents the ACM cert (not self-signed), and
the response is the clixx site. Also worth confirming the plain-HTTP path
redirects:
```bash
curl -v http://k8s.clixx.example.com
```

## Phase F — GitOps wiring

`clixx-ingress.yaml` is already wired into `manifests/kustomization.yaml` —
just commit the Phase D edit and push as usual. The ALB itself (listeners,
target group, ACM cert) and the ingress-nginx controller install (Phase A)
are one-time infra-level setup outside this repo's kustomization, same way
the Secret in `docs/k8s-secrets-runbook.md` is intentionally kept outside
git.
