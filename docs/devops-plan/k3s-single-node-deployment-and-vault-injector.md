<!-- Not yet sequenced into a numbered docs/ folder — lives here in
     docs/devops-plan/ until the full devops-practice-plan.md is complete.
     Date below is provisional (the date this actually happened); revisit
     once final sequencing/dating is decided. -->

# Stage 5 — Kubernetes (k3s)

**Date:** 2026-07-26
**Repo the actual code/infra changes live in:** `Animal-Shelter-Workshop`
(k8s manifests) — this write-up lives in the homelab meta-repo instead,
alongside the devops practice plan it's a stage of (`devops-practice-plan.md`,
Stage 5's checklist, all 10 items).

## Why I built this

Stage 4 packaged the app into a portable image but proved it could only
ever run one Pod's worth of it — no self-healing, no rolling deploys, no
way to scale past "one container, one host." Stage 5's job is to hand that
same image to something that actually manages it: kill a container and
have it come back on its own, without a human running `docker compose up`
again. k3s is the smallest real Kubernetes distribution that fits this
host's RAM budget, and it's a hard prerequisite for Stage 7 (ArgoCD runs
*inside* a k3s cluster, not next to it).

## Concept: what changes vs. Stage 4

```
STAGE 4 (docker-compose, one host)         STAGE 5 (k3s, one CT so far)
┌─────────────────────────┐                ┌─────────────────────────┐
│  docker compose up       │                │   kubectl apply -f k8s/  │
│  you restart it by hand  │      ──▶       │   the Deployment          │
│  if a container dies     │                │   restarts it for you    │
└─────────────────────────┘                └─────────────────────────┘
   1 app container                            2 app Pod replicas,
   1 nginx container                           each still app+nginx,
   1 local mysql (throwaway)                   no DB container at all —
                                                 DB wiring stays deferred
```

The real 5-database fleet is untouched either way — same as Stage 4, this
stage doesn't containerize any database. What's new is *who* watches the
app container and restarts it when it dies.

## Flow

```
┌────────────────────────────────────┐
│      STAGE 5 — k3s (single node)   │▏
└────────────────────────────────────┘▔▔

┌────────────────────────────────┐     done — new LXC CT 100, 1 core /
│ 1. k3s in an LXC CT, start small │▏    1.5GB, checked free -h + swap
│    (capacity check first)        │▏    on proxmox before creating it
└────────────────────────────────┘▔▔
              │
              ▼
┌────────────────────────────────┐     done — v1.36.2+k3s1, single
│ 2. Single-node cluster           │▏    control-plane node, Ready
└────────────────────────────────┘▔▔
              │
              ▼
┌────────────────────────────────┐     done — kubectl run, exec'd in
│ 3. kubectl run: one ad-hoc Pod   │▏    to confirm php-fpm actually
└────────────────────────────────┘▔▔    running
              │
              ▼
┌────────────────────────────────┐     done — 2-replica Deployment +
│ 4. Deployment + Service YAML     │▏    NodePort Service, app+nginx
└────────────────────────────────┘▔▔    sidecar per Pod, HTTP 200 through it
              │
              ▼
┌────────────────────────────────┐     done — deleted one replica,
│ 5. Kill a Pod, confirm self-heal │▏    ReplicaSet replaced it inside
└────────────────────────────────┘▔▔    seconds, Service never dropped
              │
              ▼
┌────────────────────────────────┐     done — non-DB env vars split
│ 6. ConfigMap + Secret             │▏    into ConfigMap/Secret, rollout
└────────────────────────────────┘▔▔    clean, verified via kubectl exec
              │
              ▼
┌────────────────────────────────┐     done — injector installed
│ 7. Vault Agent Injector           │▏    pointed at the existing
└────────────────────────────────┘▔▔    linux-vault, demo secret injected
              │
              ▼
┌────────────────────────────────┐     deferred, documented — no
│ 8. Expand to 2+ nodes             │▏    second physical Proxmox node
└────────────────────────────────┘▔▔    exists; RAM already tight on this one
              │
              ▼
┌────────────────────────────────┐     done — taint/toleration and
│ 9. Scheduling, taints, draining  │▏    cordon/drain/uncordon all
└────────────────────────────────┘▔▔    proven on the single node
```

## What I built

### 1. New LXC CT for k3s, not a VM

Capacity check first, per the plan's own instruction: `free -h` on
`proxmox` showed only 744Mi free / 4.1Gi available, with 2.0Gi **already**
sitting in swap (up from 1.3Gi at the start of the previous session) —
confirms the plan's Host Capacity Reality Check wasn't exaggerating.
Created CT 100 (`linux-k3s`) anyway, deliberately small: **1 core, 1.5GB
RAM, 512MB swap**, unprivileged, VLAN tag 30 (matches `linux-vault`/
`linux-gh-runner` — general infra, not app-server's 40 or the DB roles'
20). `features: nesting=1,keyctl=1` for containerd, plus the same
`/dev/net/tun` passthrough lines every other Tailscale-joined CT in this
homelab already carries (had to append these to `/etc/pve/lxc/100.conf`
directly after a stop/start cycle — `pct set` has no CLI flag for raw
`lxc.*` config keys).

### 2. k3s, single node — one real bug fixed to get there

`curl -sfL https://get.k3s.io | sh -` installed cleanly, but the service
crash-looped:
```
Failed to create an oomWatcher (running in UserNS, Hint: enable
KubeletInUserNamespace feature flag to ignore the error)" err="open
/dev/kmsg: no such file or directory"
Error: failed to run Kubelet: failed to create kubelet: open /dev/kmsg:
no such file or directory
```
An unprivileged LXC container has no `/dev/kmsg` and kubelet insists on one
unless told otherwise — the log line names its own fix. Reinstalled with:
```
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_EXEC="server --kubelet-arg=feature-gates=KubeletInUserNamespace=true" \
  sh -
```
After that, `kubectl get nodes` showed `linux-k3s   Ready   control-plane`
within 20 seconds, and every system Pod (CoreDNS, metrics-server, Traefik,
local-path-provisioner) came up `Running` on its own. (Two harmless
warnings along the way, not fixed because they don't need fixing: modprobe
can't load `overlay`/`br_netfilter` inside the unprivileged container, but
both were already loaded on the host kernel, so k3s picked them up anyway;
and a sysctl write for `nf_conntrack_max` gets `permission denied`,
which is expected and doesn't block anything.)

### 3. `kubectl run` — one ad-hoc Pod, proven for real

```
kubectl run asw-app --image=docker.io/tttaufiqqq/animal-shelter-workshop:v1.0.0 --restart=Never
```
`Running`, `1/1`, in under 30 seconds (image pull included). Since this
image only runs `php-fpm` (no built-in HTTP listener — see Stage 4), the
honest verification isn't a curl, it's:
```
kubectl exec asw-app -- ps aux
# PID 1: php-fpm master process, PID 7-8: pool www workers
```
Confirmed and torn down — this was deliberately a throwaway step per the
plan, not the real deliverable.

### 4. Deployment + Service — app+nginx sidecar, not app alone

The real deliverable. Each Pod runs **two containers**, same shape as
Stage 4's `docker-compose.yml` (`app` + `webserver`), minus the local `db`
service:

```
k8s/
├── deployment.yaml       2 replicas, initContainer + app + nginx
├── service.yaml          NodePort 30080 → container port 80
├── nginx-configmap.yaml  same vhost as docker/nginx/default.conf,
│                         fastcgi_pass now 127.0.0.1:9000 (same Pod,
│                         not a Compose service name)
├── app-configmap.yaml    non-secret env (APP_NAME, DB_CONNECTION=sqlite, ...)
└── app-secret.yaml       APP_KEY only
```

One real gap Docker's own behavior papered over: `docker-compose.yml`
mounts an *empty* named volume over `/var/www/html/public`, and Docker
silently copies the image's existing content into an empty named volume
the first time it's used. **Kubernetes' `emptyDir` does not do this** — a
bare emptyDir mounted over that path would shadow the Vite build baked
into the image at build time, and nginx would 404 every asset. Fixed with
an `initContainer` (same app image) that runs once per Pod startup:
```yaml
command: ["sh", "-c", "cp -r /var/www/html/public/. /shared/"]
```
populating the shared `emptyDir` before either the `app` or `nginx`
container starts.

```
kubectl apply -f k8s/nginx-configmap.yaml -f k8s/deployment.yaml -f k8s/service.yaml
kubectl rollout status deployment/asw-app
# deployment "asw-app" successfully rolled out
curl http://localhost:30080/up   # -> 200
curl http://localhost:30080/     # -> 200 (homepage, not just the health route)
```

### 5. Killed a Pod on purpose

```
kubectl delete pod asw-app-794dcdd558-9flmq
```
Within 1 second the ReplicaSet had a replacement `PodInitializing`; within
16 seconds it was `2/2 Running`. `curl http://localhost:30080/up` returned
`200` the entire time — the surviving replica carried traffic while the
replacement came up. This is the actual point of moving to Kubernetes at
all: `docker compose` only restarts what you explicitly re-run; a
`Deployment` does this by itself, unprompted.

Reproduced live afterward with `kubectl get pods -l app=asw -w` running in
one terminal while a delete ran in another, to actually watch the
transition frame by frame instead of just the before/after snapshot:

![Terminal split showing `kubectl delete pod asw-app-c7857ccf8-lllwp` in the left pane, and the right pane's `kubectl get pods -l app=asw -w` stream catching the whole cycle live: the deleted pod going Terminating then Completed, followed by a new pod asw-app-c7857ccf8-569rj cycling Pending -> Init:0/1 -> PodInitializing -> 2/2 Running, the entire replacement taking about 5 seconds](images/stage5-self-heal-watch.png)

### 6. ConfigMap + Secret

Moved the Deployment's inline `env:` list into `envFrom`: everything
non-secret (`APP_NAME`, `APP_ENV`, `DB_CONNECTION=sqlite`, `SESSION_DRIVER`,
etc.) into `asw-app-config`, just `APP_KEY` into `asw-app-secret` (the
same local/dev-only value already sitting in plaintext in Stage 4's
committed `docker-compose.yml` — not a real secret, kept as plain
`stringData` for the same reason that file does). DB config stays exactly
where Stage 4 left it (sqlite, no real connections) — wiring the real
5-connection setup into k3s is explicitly a later, harder step per the
plan, not this one.
```
kubectl apply -f k8s/app-configmap.yaml -f k8s/app-secret.yaml -f k8s/deployment.yaml
kubectl rollout status deployment/asw-app   # successfully rolled out
kubectl exec deploy/asw-app -c app -- env | grep -E 'APP_NAME|APP_KEY|DB_CONNECTION'
# APP_KEY=base64:M0OU...   DB_CONNECTION=sqlite   APP_NAME=ASW
```

### 7. Vault Agent Injector — ties this cluster to the existing `linux-vault`

`linux-vault` already runs, live, unsealed, serving real secrets to the
rest of this homelab (Stage 2/3's AppRole-based reads) — this stage
doesn't stand up a *new* Vault, it points the injector at the one that
already exists (`injector.externalVaultAddr`, `server.enabled=false`):
```
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault \
  --set server.enabled=false \
  --set injector.enabled=true \
  --set injector.externalVaultAddr=http://100.112.41.113:8200 \
  --set injector.resources.requests.memory=64Mi \
  --set injector.resources.limits.memory=128Mi
```
Then, on `linux-vault` itself (an administrative, live-API operation —
same category as Stage 2's one-time `vault kv patch`, **not** a config
change that would reseal Vault):
```
vault auth enable kubernetes
vault write auth/kubernetes/config \
  kubernetes_host='https://100.109.241.125:6443' \
  kubernetes_ca_cert=@k3s-ca.crt \
  token_reviewer_jwt=@reviewer.jwt
vault policy write asw-k8s-demo asw-k8s-demo-policy.hcl
vault write auth/kubernetes/role/asw-k8s-demo \
  bound_service_account_names=vault-demo \
  bound_service_account_namespaces=default \
  policies=asw-k8s-demo ttl=1h
```
The reviewer JWT came from a long-lived `kubernetes.io/service-account-token`
Secret bound to the `vault` ServiceAccount the Helm chart itself creates
(already wired to `system:auth-delegator` via `vault-server-binding`); the
CA cert came from `/var/lib/rancher/k3s/server/tls/server-ca.crt`.

Proved it end to end with a demo Pod, annotated for injection:
```yaml
metadata:
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "asw-k8s-demo"
    vault.hashicorp.com/agent-inject-secret-hello.txt: "secret/data/k3s-demo"
```
```
kubectl exec vault-demo -c app -- cat /vault/secrets/hello.txt
vault-agent-injector-works
```

### 8. Expand to 2+ nodes — deferred, documented (not a gap)

The plan's own capacity note anticipates this: expanding k3s to multiple
nodes "pairs with adding a second physical Proxmox node rather than
squeezing a second k3s node onto the same box." Checked: `pvecm status`
confirms this homelab has exactly **one** standalone Proxmox host, no
cluster, and its RAM is already the tightest resource in the whole plan
(1.0Gi free, 2.2Gi in swap, even before this stage's own CT). Same shape
as Stage 4's Harbor deferral — a real, documented decision given current
hardware, not an oversight. Revisit once (if) a second physical node
exists.

### 9. Scheduling, taints/tolerations, draining — practiced on the single node

Multi-node expansion is deferred, but taints and draining are meaningful
on one node too — they answer "can I keep a workload off this node" and
"can I evacuate everything off this node for maintenance," neither of
which needs a second node to demonstrate.

**Taint / toleration:**
```
kubectl taint nodes linux-k3s demo=busy:NoSchedule
kubectl run taint-test --image=busybox --restart=Never --command -- sleep 3600
# stays Pending: "1 node(s) had untolerated taint(s)"
```
A second Pod with a matching `tolerations:` block scheduled immediately
and reached `Running` while `taint-test` stayed `Pending` — side by side,
same node, same taint.

**Cordon / drain / uncordon:**
```
kubectl taint nodes linux-k3s demo=busy-   # cleanup
kubectl cordon linux-k3s
kubectl drain linux-k3s --ignore-daemonsets --delete-emptydir-data --force
```
Evicted every non-DaemonSet Pod on the node — both `asw-app` replicas, the
Vault injector, CoreDNS, metrics-server, local-path-provisioner, Traefik —
cleanly, `node/linux-k3s drained`. With no second node, everything sat
`Pending` while cordoned (expected — this is exactly what a real drain
during maintenance looks like on a cluster this size). `kubectl uncordon
linux-k3s` brought every single one back to `Running` within 25 seconds,
`curl http://localhost:30080/up` confirmed `200` again immediately after.

## What I found

**Graceful degradation carries over into k3s, unchanged.** None of the 5
real database connections are wired up here at all (`DB_CONNECTION=sqlite`
is the only DB config in `asw-app-config` — deliberately, per this stage's
own scope). So the homepage shows `0/5 databases online`, not Stage 4's
`1/5` (that one had `shelter` wired to a local test MySQL container). The
same `HandleDatabaseFailures`/`InjectDatabaseStatus` middleware Stage 4
already proved still renders the page underneath instead of a 500, with a
"Continue Anyway" escape hatch — confirms this behavior isn't specific to
Docker Compose, it's the app itself, and it survives unchanged into a
Kubernetes Deployment with zero extra work.

![Animal Shelter Workshop homepage through the k3s NodePort Service, with the app's own "Database Connection Notice" modal open showing 0/5 databases online (Users, Reporting, Animals, Shelter, Booking all OFFLINE) — homepage still rendered blurred underneath, "Continue Anyway" button available](images/stage5-database-status-notice.png)

**The k3s API server's default TLS certificate doesn't cover the
Tailscale IP** — only the LAN IP, the cluster IP, and `localhost`. Vault's
Kubernetes auth login kept returning a bare `403 permission denied` with
zero detail (this is deliberate — Vault masks all kubernetes-auth login
failures behind this exact generic message as a security hardening
measure, so the client-facing error is genuinely uninformative by design).
The real cause only showed up after bumping Vault's own log level live
(`vault write sys/loggers level=debug` — a runtime API call, not a config
file edit, so it needs no restart and doesn't reseal Vault) and reading
`journalctl -u vault`:
```
tls: failed to verify certificate: x509: certificate is valid for
10.0.30.100, 10.43.0.1, 127.0.0.1, ::1, not 100.112.41.113
```
Fixed by adding the Tailscale IP as an extra SAN and restarting k3s
(affects only this CT, not Vault):
```yaml
# /etc/rancher/k3s/config.yaml
tls-san:
  - 100.109.241.125
```
Reverted Vault's log level back to `info` afterward. Worth remembering:
if a Vault Kubernetes-auth login ever returns a bare 403 with no further
detail again, the log-level-bump-then-check-journalctl move is the way to
actually see why.

## Bonus: hardening — proving the CT survives a real shutdown/reboot, not assuming it

Every fix made earlier in this stage happened to land in a persistent
place rather than a one-off runtime command, so in theory none of it
should need redoing after a CT stop/start or a Proxmox host reboot. Rather
than assume that, checked each piece explicitly and then actually
shut the CT down and brought it back cold:

- **`onboot: 1`** already set on CT 100 at creation time — survives a
  `proxmox` host reboot without a manual `pct start`.
- **`k3s` and `tailscaled` are both `systemctl enable`d**, not just
  `--now`-started — `systemctl is-enabled k3s tailscaled` returns
  `enabled` for both, so they start on their own after the CT boots, no
  human needed.
- **The `KubeletInUserNamespace` fix is baked directly into
  `/etc/systemd/system/k3s.service`'s own `ExecStart=` line** (a static
  file on the CT's disk), not something set only for the process that was
  running at install time — confirmed by reading the file back.
- **The `tls-san` fix lives in `/etc/rancher/k3s/config.yaml`**, a real
  file k3s reads on every startup, not a flag that only applied to one
  invocation.
- **The `/dev/net/tun` passthrough and cgroup device allow lines live in
  Proxmox's own `/etc/pve/lxc/100.conf`** (host-side), reapplied by
  Proxmox itself every time the CT starts, regardless of why it stopped.
- **`tun` turned out to be compiled directly into this host's kernel**
  (`CONFIG_TUN=y`), not a loadable module — so there's no
  module-not-loaded-yet race to worry about on a fresh host boot either.

Then did the actual test instead of trusting the above list on its own:
```
pct shutdown 100 --timeout 30    # clean stop
pct start 100                    # cold start, no manual fixes applied
```
25 seconds after `pct start`, with zero intervention:
```
kubectl get nodes
# linux-k3s   Ready   control-plane   ...

tailscale status --json | grep BackendState
# "BackendState": "Running"          <- reconnected, no re-auth needed

kubectl get pods -A
# every Pod back to Running (RESTARTS incremented by 1-2 — the
# containers inside each Pod restarted in place; the Pods themselves
# were never recreated, since the k3s datastore lives on the CT's own
# disk and survived the stop/start cycle unchanged)

curl http://localhost:30080/up
# HTTP 200
```
No fixes were needed to make this work — it already worked, because the
earlier fixes were written to disk instead of applied only in-memory.
This is the actual meaning of "hardened" here: not new configuration, but
confirmation that nothing in this stage is secretly depending on a
runtime state that a shutdown would wipe out.

## How to independently verify each item

**1-2. k3s CT + single-node cluster**
```bash
ssh proxmox "pct exec 100 -- kubectl get nodes -o wide"
# linux-k3s   Ready   control-plane   ...
```

**3. kubectl run**
```bash
kubectl run asw-app --image=docker.io/tttaufiqqq/animal-shelter-workshop:v1.0.0 --restart=Never
kubectl exec asw-app -- ps aux   # php-fpm master + pool processes
```

**4. Deployment + Service**
```bash
kubectl get deploy,pods,svc -l app=asw
curl -o /dev/null -w "%{http_code}\n" http://<node>:30080/up   # 200
```

**5. Self-heal**
```bash
kubectl delete pod <one-of-the-two-asw-app-pods>
kubectl get pods -l app=asw -w   # watch a replacement appear within seconds
```

**6. ConfigMap/Secret**
```bash
kubectl exec deploy/asw-app -c app -- env | grep APP_NAME
# comes from asw-app-config, not an inline Deployment value
```

**7. Vault Agent Injector**
```bash
kubectl exec vault-demo -c app -- cat /vault/secrets/hello.txt
# vault-agent-injector-works
```

**9. Taints / draining**
```bash
kubectl taint nodes linux-k3s demo=busy:NoSchedule
kubectl run t --image=busybox --restart=Never --command -- sleep 60
kubectl get pod t   # Pending
kubectl taint nodes linux-k3s demo=busy-
kubectl drain linux-k3s --ignore-daemonsets --delete-emptydir-data --force
kubectl uncordon linux-k3s
```

**Bonus: shutdown/reboot hardening**
```bash
ssh proxmox "pct shutdown 100 --timeout 30 && pct start 100"
# wait ~25s, then:
ssh proxmox "pct exec 100 -- kubectl get nodes"          # Ready
ssh proxmox "pct exec 100 -- tailscale status --json"    # BackendState: Running
ssh proxmox "pct exec 100 -- kubectl get pods -A"         # all Running
ssh proxmox "pct exec 100 -- curl -s -o /dev/null -w '%{http_code}\n' http://localhost:30080/up"  # 200
```

## What carries forward to Stage 6/7 — and what doesn't

- The `k8s/` manifests (`Animal-Shelter-Workshop` repo) are the real,
  durable deliverable — Stage 7 (GitOps) points ArgoCD at exactly this
  directory, per the plan's own instruction, rather than a separate repo.
- The Vault Kubernetes auth method, the `asw-k8s-demo` policy/role, and the
  injector installation are all real and will carry forward — but the
  demo secret path (`secret/k3s-demo`) and the `vault-demo` Pod/
  ServiceAccount were exploratory scaffolding for this stage only, not
  wired to the app's real config yet. Wiring the app's actual 5-connection
  DB credentials through the injector is future work, not done here.
- Multi-node expansion and its downstream scheduling practice
  (taints/tolerations/draining beyond what a single node can show) stay
  blocked on a second physical Proxmox host — tracked, not forgotten.

## Where things live

| Piece | Path |
|---|---|
| k8s manifests | `Animal-Shelter-Workshop/k8s/*.yaml` |
| k3s CT | Proxmox CT 100, `linux-k3s`, Tailscale `100.109.241.125` |
| k3s extra TLS SAN | `/etc/rancher/k3s/config.yaml` (inside CT 100) |
| Vault kubernetes auth config | `linux-vault`, `auth/kubernetes/*` (live Vault API, not in git) |
| This write-up | `proxmox-homelab-taufiq/docs/devops-plan/k3s-single-node-deployment-and-vault-injector.md` |

### Screenshots

- `images/stage5-database-status-notice.png` — added above (browser hit
  against the k3s NodePort Service directly, taken by the user).
- `images/stage5-self-heal-watch.png` — added above (live `kubectl delete`
  + `kubectl get ... -w` catching the whole self-heal cycle, taken by the
  user).

Still worth adding next session:
- The Vault UI's Access → Kubernetes auth method page, showing the
  `asw-k8s-demo` role.
Save to `docs/devops-plan/images/` if added.
