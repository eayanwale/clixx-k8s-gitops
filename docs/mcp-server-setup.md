# Setting up a read-only MCP server for the Clixx cluster

Goal: let Claude introspect the kubeadm cluster (pods, nodes, deployments,
services, logs) through an MCP server, without ever touching Secrets or
running exec/delete/patch. The server runs on the control-plane node (it
already has `~/.kube/config` from `control-setup-k8s.sh`); Claude Code runs
on your local machine and reaches it over SSH.

## Reference docs

- MCP Python SDK, **v1.x branch specifically** (stable/production line; the
  `main` branch README documents an alpha v2 with a different API and
  should not be used here): https://github.com/modelcontextprotocol/python-sdk/tree/v1.x
  - Full v1.x README (has the "recommended for production" note plus the
    quickstart the `server.py` skeleton below is based on):
    https://github.com/modelcontextprotocol/python-sdk/blob/v1.x/README.md
  - The exact quickstart snippet itself:
    https://github.com/modelcontextprotocol/python-sdk/blob/v1.x/examples/snippets/servers/fastmcp_quickstart.py
- MCP protocol concepts (tools, transports): https://modelcontextprotocol.io/
- Kubernetes Python client (`CoreV1Api`, `AppsV1Api`, examples):
  https://github.com/kubernetes-client/python/tree/master/examples
  - Out-of-cluster config + listing pods (`load_kube_config`,
    `list_pod_for_all_namespaces`):
    https://github.com/kubernetes-client/python/blob/master/examples/out_of_cluster_config.py
  - Pod logs (`read_namespaced_pod_log`):
    https://github.com/kubernetes-client/python/blob/master/examples/pod_logs.py
  - Deployment read (`read_namespaced_deployment` — used by the
    `deployment_status` tool):
    https://github.com/kubernetes-client/python/blob/master/examples/annotate_deployment.py
  - Generated `AppsV1Api` reference (every method, incl.
    `read_namespaced_deployment`, `list_namespaced_deployment`):
    https://github.com/kubernetes-client/python/blob/master/kubernetes/docs/AppsV1Api.md
- Claude Code MCP docs (`.mcp.json`, `claude mcp add` syntax, the `--`
  separator rule): https://code.claude.com/docs/en/mcp

## 1. Install dependencies on the control-plane node

Ubuntu's system Python doesn't ship venv/pip support by default — install
those first, otherwise `python3 -m venv` can silently produce a broken
venv (missing `bin/activate`, `bin/pip`, or worse):

```bash
sudo apt update
sudo apt install -y python3-venv python3-pip
```

Then create the venv and install into it:

```bash
python3 -m venv mcp-venv
source mcp-venv/bin/activate
pip install "mcp[cli]<2.0" kubernetes
```

If `bin/activate` is still missing after this, or `ls mcp-venv/bin` shows
anything unexpected, don't debug it — `rm -rf mcp-venv` and recreate from
scratch rather than chasing a corrupted venv.

**The `<2.0` pin is required, not optional, as of 2026-08-05.** This doc
originally said a plain `pip install "mcp[cli]"` was enough, on the
assumption v2 was still an opt-in alpha (`mcp==2.0.0a1`). That assumption
broke on 2026-07-28: `mcp` shipped a real, stable `2.0.0` release that
renamed `FastMCP` → `MCPServer` and moved it from `mcp.server.fastmcp` to
`mcp.server.mcpserver` — a plain unpinned install now silently pulls 2.0.0,
and `server.py` below (written against the v1.x API) fails with
`ModuleNotFoundError: No module named 'mcp.server.fastmcp'`. Pin to `<2.0`
until `server.py` is deliberately ported to the new API.

## 2. Write `server.py`

Shape, per the v1.x SDK README's own quickstart example:

```python
from mcp.server.fastmcp import FastMCP
from kubernetes import client, config

config.load_kube_config()
v1 = client.CoreV1Api()
apps_v1 = client.AppsV1Api()
mcp = FastMCP("clixx-k8s")

@mcp.tool()
def list_pods(namespace: str) -> list:
    """List pods in a namespace."""
    return [p.metadata.name for p in v1.list_namespaced_pod(namespace).items]

@mcp.tool()
def deployment_status(name: str, namespace: str) -> dict:
    """Get replica counts for a deployment."""
    d = apps_v1.read_namespaced_deployment(name, namespace)
    return {
        "desired": d.spec.replicas,
        "ready": d.status.ready_replicas,
    }

@mcp.tool()
def describe_pod(name: str, namespace: str) -> dict:
    """Node placement, container status, and volume/mount info for a pod."""
    pod = v1.read_namespaced_pod(name, namespace)

    return {
        "name": pod.metadata.name,
        "node": pod.spec.node_name,
        "phase": pod.status.phase,
        "pod_ip": pod.status.pod_ip,
        "containers": [
            {
                "name": cs.name,
                "ready": cs.ready,
                "restart_count": cs.restart_count,
                "state": str(cs.state),
            }
            for cs in (pod.status.container_statuses or [])
        ],
        "volumes": [
            {
                "name": vol.name,
                "pvc_claim": vol.persistent_volume_claim.claim_name
                    if vol.persistent_volume_claim else None,
            }
            for vol in (pod.spec.volumes or [])
        ],
        "mount_paths": [
            {
                "container": c.name,
                "mounts": [
                    {"path": vm.mount_path, "volume": vm.name}
                    for vm in (c.volume_mounts or [])
                ],
            }
            for c in pod.spec.containers
        ],
    }


@mcp.tool()
def pod_logs(name: str, namespace: str, container: str = None, tail_lines: int = 200) -> str:
    """Recent logs from a pod. Pass container if the pod runs more than one."""
    return v1.read_namespaced_pod_log(
        name=name, namespace=namespace, container=container, tail_lines=tail_lines
    )


@mcp.tool()
def pvc_status(name: str, namespace: str) -> dict:
    """Status, capacity, and binding info for a PersistentVolumeClaim."""
    pvc = v1.read_namespaced_persistent_volume_claim(name, namespace)
    return {
        "name": pvc.metadata.name,
        "phase": pvc.status.phase,
        "capacity": pvc.status.capacity,
        "bound_volume": pvc.spec.volume_name,
        "storage_class": pvc.spec.storage_class_name,
    }


if __name__ == "__main__":
    mcp.run()
```

This isn't from a single upstream example — no doc shows "MCP wrapping the
Kubernetes client" together, since that combination is specific to this
task. It's assembled from verified, independent sources: the
`FastMCP`/`@mcp.tool()`/`mcp.run()` shape is the SDK's own quickstart
snippet linked above; `config.load_kube_config()` / `client.CoreV1Api()` /
`list_namespaced_pod(...)` are from the kubernetes-client/python examples
linked above; `client.AppsV1Api()` / `read_namespaced_deployment(...)` are
from the `annotate_deployment.py` example and the generated `AppsV1Api`
reference, both linked above.

Each `@mcp.tool()` function becomes something Claude can call. Add more
using `CoreV1Api`/`AppsV1Api` read methods:

| Tool idea | Client call |
|---|---|
| describe pod | `read_namespaced_pod` |
| pod logs | `read_namespaced_pod_log` |
| list nodes | `list_node` |
| cluster version | `VersionApi().get_code()` |
| list/describe deployments | `list_namespaced_deployment`, `read_namespaced_deployment` |
| list/describe services | `list_namespaced_service`, `read_namespaced_service` |

**Keep it read-only:** only use `list_*`/`read_*`/`get_*` methods. Do not
add anything from the Secrets API, and do not add `create_*`/`patch_*`/
`delete_*`/exec calls — secrets and mutations stay manual, by design.

## 3. Test the server standalone

`mcp dev` shells out to `npx` under the hood (the MCP Inspector is a
Node/npm package), so Node.js needs to be on the control-plane node first
— confirmed by running it without Node installed:

```
ERROR    npx not found. Please ensure Node.js and npm are properly installed and added to your system PATH.
```

Install Node (Ubuntu's stock `apt install nodejs` is often too old for
current npm tooling, so use NodeSource for a current LTS):

```bash
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt install -y nodejs
node -v
npm -v
```

Then confirm the server works using the SDK's built-in dev command
(bundled with the `[cli]` extra installed above), which opens your server
in the MCP Inspector:

```bash
mcp dev server.py
```

(If you installed with `uv`, run `uv run mcp dev server.py` instead.) This
prints a Inspector URL bound to `localhost` on the control-plane node
(e.g. `http://localhost:6274/?MCP_PROXY_AUTH_TOKEN=...`) and tries to open
it in a browser — which fails with "no browser open" since `k8control` is
headless. Reaching it from your own machine requires tunneling both ports
the Inspector printed (6274 for the UI, 6277 for its proxy) back to you.
**From a separate local terminal** (leave the `mcp dev` session running):

```bash
ssh -L 6274:localhost:6274 -L 6277:localhost:6277 ubuntu@<control-plane-IP>
```

Keep that SSH session open, then open the printed URL (with its
`MCP_PROXY_AUTH_TOKEN`) in your local browser — it now resolves through
the tunnel. This opens a web UI where you can call your tools directly
and inspect the JSON responses.

## 4. Register it in Claude Code (over SSH)

The server has no exposed port, so Claude Code launches it *through* SSH
and speaks MCP over that connection's stdio:

```bash
claude mcp add --transport stdio clixx-k8s -- ssh -o BatchMode=yes <user>@<control-plane-IP> /path/to/mcp-venv/bin/python /path/to/server.py
```

(Per Claude Code's docs: everything after the bare `--` is passed to the
server untouched — that's what lets `ssh`'s own `-o` flag through without
Claude Code trying to parse it as one of its own options.)

`-o BatchMode=yes` makes the connection fail fast instead of hanging on a
password prompt — passwordless key-based SSH from your machine to that
host needs to already work before this step.

## 5. Verify

```bash
claude mcp list
```

should show `clixx-k8s` connected. Then, in a Claude Code session, ask
something like "list pods in clixx-prod" — Claude will call the tool.

## Not persistent, and why that matters after a stop/start

There is no long-running MCP server process on `k8control` — the `claude mcp
add` command above spawns `server.py` fresh over SSH *per connection*, and it
exits when that connection closes. Nothing needs to be "started" after the
instance reboots; the venv and `server.py` just sit on disk (survive
stop/start fine, same EBS root volume).

What **does** break on a stop/start cycle: `k8control` has no Elastic IP, so
its public IP changes every time it's restarted, and that IP is baked
directly into the `claude mcp add` command above. After any restart, the
previously-registered connection points at a now-wrong IP. Re-run the
registration with the current IP to fix it:

```bash
claude mcp remove clixx-k8s
claude mcp add --transport stdio clixx-k8s -- ssh -o BatchMode=yes <user>@<new-control-plane-IP> /path/to/mcp-venv/bin/python /path/to/server.py
```

The `clixx-gitops` Jenkins pipeline prints this exact command (with the
current run's IP already filled in) at the end of every successful run, in
its `post { success }` block — copy it from there instead of looking up the
IP by hand.
