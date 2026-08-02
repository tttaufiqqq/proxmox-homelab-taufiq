# k3s Production Cutover Plan

A staged plan to make k3s (not `app-server`, VM 101) the real serving target
for `animal-shelter-workshop.tttaufiqqq.com` — the go-live moment, once
everything underneath it is already proven. **Hard dependencies, both must
be fully done first:**
- `plans/05-k3s-asw-db-connectivity-plan.md` — k3s has to reach the real 5
  DBs before any of this matters.
- `plans/06-k3s-multi-node-gitops-automation-plan.md` — the 2-node split,
  the fully-automated CI→ArgoCD pipeline, and `cloudflared` running inside
  the cluster are all built there, not here. This plan assumes they already
  exist and just uses them.

Cutting public traffic onto a cluster that can't reach its own databases,
or whose deploy pipeline still needs manual steps, would just move the
outage onto a different host instead of actually improving anything.

**Decision, made while planning this:** once k3s is proven under real
traffic, `app-server` gets powered off and kept as a rollback safety net —
**not destroyed** — same pattern already used in
`plans/04-asw-db-vms-to-ct-migration-plan.md` for the old DB VMs. If k3s
has a problem post-cutover, the fastest recovery is flipping the tunnel
origin back and powering the VM back on, not rebuilding it from scratch.

This plan touches the sibling repo `Animal-Shelter-Workshop` (`k8s/*.yaml`,
Vault Agent Injector templates) and this repo's Terraform
(`infrastructure/terraform/homelab-infra.tf`, for the eventual `app-server`
power-off step) — not this repo's code directly.

---

## Flow

```
┌────────────────────────────────────┐
│   K3S PRODUCTION CUTOVER           │▏
└────────────────────────────────────┘▔▔

┌────────────────────────────────┐     don't start until all 5 DBs show
│ 0. Confirm plans 05 & 06 done    │▏    connected:true AND a plain git
│                                   │▏    push alone reaches the cluster
└────────────────────────────────┘▔▔
              │
              ▼
┌────────────────────────────────┐     new CT 119, joins as a plain
│ 1. Add a 3rd node, dedicated to   │▏    k3s agent; ArgoCD's 7 pods
│    ArgoCD/observability           │▏    rescheduled onto it, off node 1
└────────────────────────────────┘▔▔
              │
              ▼
┌────────────────────────────────┐     Cloudinary/mail/ToyyibPay/Azure
│ 2. Wire the REST of asw_secrets  │▏    backup creds — currently missing
│    into k3s, not just DB creds   │▏    from k8s/app-secret.yaml entirely
└────────────────────────────────┘▔▔
              │
              ▼
┌────────────────────────────────┐     hit the real public domain, confirm
│ 3. Verify the real thing          │▏    5/5 DBs online, uploads/mail/
│                                   │▏    payments all work for real
└────────────────────────────────┘▔▔
              │
              ▼
┌────────────────────────────────┐     let it run under real traffic for a
│ 4. Soak period                    │▏    while before touching app-server
│                                   │▏    at all — no fixed rollback deadline
└────────────────────────────────┘▔▔
              │
              ▼
┌────────────────────────────────┐     qm stop, NOT destroy — same
│ 5. Power off app-server            │▏    rollback-safety-net pattern as
│    (rollback safety net only)     │▏    plan 04's old DB VMs
└────────────────────────────────┘▔▔
```

---

## What each node does (target state after Stage 1)

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     K3S CLUSTER — TARGET 3-NODE LAYOUT                   │▏
└─────────────────────────────────────────────────────────────────────────┘▔▔

┌───────────────────────────┐  ┌───────────────────────────┐  ┌───────────────────────────┐
│ NODE 1: linux-k3s (CT 100) │▏ │ NODE 2: linux-k3s-2 (CT118)│▏ │ NODE 3: linux-k3s-3 (CT119)│▏
│ control-plane               │▏ │ agent — public edge         │▏ │ agent — cluster tooling     │▏
├───────────────────────────┤▔▔ ├───────────────────────────┤▔▔ ├───────────────────────────┤▔▔
│ k3s server process          │▏ │ asw-nginx ×3                │▏ │ argocd (7 pods)             │▏
│ asw-app ×3 (backend)        │▏ │ cloudflared                 │▏ │  ← moved off node 1        │▏
│ vault-agent-injector        │▏ │  (public ingress)           │▏ │                              │▏
│ kube-system core             │▏ │                              │▏ │ observability, once built:  │▏
│  (coredns, traefik,          │▏ │                              │▏ │ Prometheus/Grafana/Loki/    │▏
│   metrics-server,             │▏ │                              │▏ │ Alertmanager                │▏
│   local-path-provisioner)    │▏ │                              │▏ │                              │▏
└───────────────────────────┘▔▔ └───────────────────────────┘▔▔ └───────────────────────────┘▔▔

  Split rationale: node 1 = control-plane + the app it runs, node 2 = the
  public-facing edge, node 3 = the tooling that watches/deploys the other
  two — none of them competes with either of the others for CPU anymore.
```

## Why each stage is there

**Stage 1 — a dedicated 3rd node for ArgoCD/observability, not just a pin.**
Plan 06 deliberately left ArgoCD's placement undecided, to be made only
once `asw-app`'s own 2-node split (its Stage 2) was proven and real
production-cutover context existed. The original idea here was just a
`nodeSelector` pinning ArgoCD to node 1 — but node 1 already runs the k3s
control-plane process *and* `asw-app`'s 3 backend replicas, so pinning
ArgoCD there would still leave it competing for that node's CPU, just a
different competitor than node 2's workloads. A 3rd node (`linux-k3s-3`,
CT 119, same "start small" sizing as CT 118 — 1 core/2GB/8GB disk, plain
`k3s agent` role, same `KubeletInUserNamespace` feature-gate fix nodes 1
and 2 both needed) removes the contention instead of just relocating it,
and gives Prometheus/Grafana/Loki/Alertmanager (whenever built) a home
that's isolated from both the app backend and the public-facing edge.
ArgoCD itself was installed imperatively (`kubectl apply` of upstream
`install.yaml`, per `docs/19-devops-practice/07-gitops-argocd-auto-sync-and-drift-revert.md`),
not through the GitOps loop it manages — so pinning it is a `kubectl
patch`/`edit` adding `nodeSelector: kubernetes.io/hostname: linux-k3s-3`
to each of its 7 Deployments/StatefulSet directly, the same imperative
channel it was installed through. This isn't a networking requirement
(`ClusterIP` Services are reachable from any node via `kube-proxy`
regardless of pod placement) — it's resource isolation, decided now
because now is when it actually matters (real traffic about to land), not
guessed at during plan 06's node-join work.

**Stage 2 — the DB creds aren't the only thing missing.** `k8s/app-secret.yaml`
today only holds a dummy `APP_KEY`; `k8s/app-configmap.yaml` has no
Cloudinary/mail/ToyyibPay/Azure-backup config at all. Those aren't optional
for *real* production: without Cloudinary, file uploads break; without SMTP,
password reset silently falls back to the `log` mailer (writes to
`storage/logs` instead of sending, exactly the bug `env-app.j2`'s own
comments already flag from the VM's history); without the Azure Blob SAS
token, offsite backup sync (Stage 8) silently stops. Extend the Vault Agent
Injector template from plan 05's `db.env` into one `app.env` covering the
**entire** `asw_secrets` KV path (`secret/animal-shelter-workshop`), not
just `db_password` — one Vault read already returns every field, so this is
a template change, not a new Vault policy.

**Stage 3 — verify the real thing, not just `/up`.** `/api/database-status`
showing `5/5 online` (from plan 05) is necessary but not sufficient here —
also manually check a real upload (Cloudinary), trigger a real password
reset email (mail), and confirm a ToyyibPay sandbox payment still redirects
correctly, since Stage 2 is what's supposed to make all of those work for
the first time inside k3s.

**What Stage 3 actually caught, 2026-08-02:** doing the real check (not
just trusting Stage 2's config wiring) found a genuine bug unrelated to
Stage 2's own scope — `asw-app` runs 3 stateless replicas with
`SESSION_DRIVER=file` and `sessionAffinity: None` on the Service in front
of them, so a user's GET (writes the CSRF token to one pod's local disk)
and their following POST (validated against a different pod's disk) could
land on different pods. Confirmed live against the production domain: 5
real password-reset submissions, 2 succeeded (302)/3 failed (419 Page
Expired) — a ~2/3 real-world failure rate on every form submission, not
just password reset. Fixed by adding Redis as a shared session/cache
store (`k8s/redis-deployment.yaml`, a new in-cluster pod, no new LXC/VM)
and switching `SESSION_DRIVER`/`CACHE_STORE` to `redis`. That surfaced a
second bug once Redis was live: `config/session.php` defaults
`SESSION_CONNECTION` to `'users'` (a leftover default meant for the
database session driver, matching `DB_CONNECTION`'s name) instead of
`'default'`, so the redis driver looked for a nonexistent `users` Redis
connection and every request 500'd until `SESSION_CONNECTION: "default"`
was pinned explicitly in `k8s/app-configmap.yaml`. After both fixes: 8/8
repeated password-reset submissions succeeded, `storage/logs/laravel.log`
stayed empty across all 3 pods (no SMTP auth failure — `MAIL_PASSWORD`
from Vault genuinely works), and `config("filesystems.disks.cloudinary.url")`/
`config("toyyibpay.key")` both resolve to real Vault-sourced values inside
the running pod (only when checked *after* sourcing `/vault/secrets/db.env`
the same way PID 1 does — a fresh `kubectl exec` process doesn't inherit
that on its own, `/proc/1/environ` is similarly unreliable since php-fpm
overwrites that memory region with its process title). A real Cloudinary
upload and a real ToyyibPay sandbox payment through the actual UI were
**not** scripted end-to-end (would need a real login session and browser
interaction) — config resolution is confirmed correct, but a manual
click-through of those two specific flows in a browser is still worth
doing before calling Stage 3 fully closed.

**Stage 4 — no fixed soak duration.** This homelab's own practice discipline
(`devops-practice-plan.md`) already favors proving things "for real" over
assuming — give it enough real usage to be confident before touching
`app-server`, rather than a calendar-driven cutoff.

**Stage 5 — power off, don't destroy.** Matches the decision made while
planning this and the exact precedent in `plans/04-asw-db-vms-to-ct-migration-plan.md`.
`qm stop` on `app-server` (VM 101), leave it on disk. A `terraform destroy`
decision, if ever wanted, is explicitly a separate, later, conscious step —
not part of this plan.

**Already done, retroactively.** This got pulled forward to the end of
plan 06 instead of staying its own final stage here — at the user's
explicit request, once plan 06's automation was proven, `app-server`'s
deploy jobs were removed from `deploy.yml` and the VM powered off then,
with the public domain re-confirmed still returning 200. By the time
this plan's own soak testing happened, Stage 5 was already true.

**Stage 4, executed 2026-08-02.** No real users exist yet to generate
organic traffic, so synthetic load was manufactured instead —
`infrastructure/loadtest/soak-test.js` (this repo), a `k6` script run
from a laptop against the real public domain: 3 virtual users ramping,
realistic think-time, weighted toward browsing over writes. A full
1-hour run: 1575/1575 checks passed (100%), `http_req_failed` 0.00%,
p95 latency 2.68s — clean. Two real bugs surfaced along the way (a
session/CSRF race across stateless replicas, and a Redis connection-name
default bug it exposed once fixed) — both fixed, see
`docs/19-devops-practice/13-k3s-production-cutover-and-soak-test.md` for
the full story. Full writeup + all supporting screenshots also live
there. Plan considered complete.

---

## Verification

- Stage 0: `kubectl get nodes` shows 2 `Ready` nodes (plan 06); a
  throwaway commit alone (no manual `docker`/`kubectl`) reaches a running
  pod via CI → ArgoCD.
- Stage 1: `kubectl get nodes` shows 3 `Ready` nodes; `kubectl get pods -A
  -o wide` shows ArgoCD's 7 pods (and the observability stack's, once
  built) on `linux-k3s-3` only — none on node 1 or node 2.
  **Executed 2026-08-02.** `linux-k3s-3` (CT 119) created via
  `infrastructure/terraform/homelab-infra.tf` (`terraform apply -target`,
  to avoid an unrelated pre-existing `started` drift on `linux_k3s`/
  `linux_observability` in the same plan getting applied by accident — that
  drift is still there, untouched, not part of this plan). TUN device
  passthrough (`lxc.mount.entry`/`lxc.cgroup2.devices.allow`) and
  `keyctl` added post-creation via `pct set`/direct `.conf` edit on the
  Proxmox host, same as CT 118 needed — not exposed through the Terraform
  provider. Tailscale joined interactively (browser auth), then `k3s
  agent` joined via `get.k3s.io` with the same
  `--kubelet-arg=feature-gates=KubeletInUserNamespace=true` flag as nodes
  1 and 2. All 7 ArgoCD Deployments/StatefulSet `kubectl patch`ed with
  `nodeSelector: kubernetes.io/hostname: linux-k3s-3` — confirmed fully
  rescheduled off node 1, all `Running` on node 3. Observability stack
  itself not built yet (still just ArgoCD on the new node) — whenever it's
  added, give it the same `nodeSelector`.
- Stage 2: `kubectl exec deploy/asw-app -c app -- cat /vault/secrets/app.env`
  shows every `asw_secrets` field (not just DB passwords), real values.
  **Executed 2026-08-02.** Confirmed via `.../db.env` (the file's actual
  name — never renamed to `app.env`, just extended) showing all 9 new
  `export` lines with real values, not just the original 6.
- Stage 3: `curl https://animal-shelter-workshop.tttaufiqqq.com/api/database-status`
  → `5/5`; one real upload, one real password-reset email, one sandbox
  payment, all manually confirmed.
  **Executed 2026-08-02, partially.** `5/5` confirmed
  (`"allOnline":true`). Password-reset email: 8/8 live submissions
  succeeded after the session/Redis fixes described above (`storage/logs/laravel.log`
  empty across all 3 pods afterward — no SMTP auth failure). Cloudinary/
  ToyyibPay: config resolves to real Vault-sourced values inside the
  running pod, but an actual upload through the UI and an actual sandbox
  payment redirect were not done — worth a manual browser click-through
  before treating Stage 3 as fully closed.
- Stage 5: `qm list` shows `app-server` (101) `stopped`, not destroyed;
  `curl` against the public domain still returns 200 with the VM off.
