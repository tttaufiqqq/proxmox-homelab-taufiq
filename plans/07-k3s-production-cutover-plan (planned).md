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
┌────────────────────────────────┐     pin ArgoCD + Prometheus/Grafana/
│ 1. Pin ArgoCD/observability       │▏    Loki/Alertmanager to node 1,
│    to a node                      │▏    decision deferred from plan 06
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

## Why each stage is there

**Stage 1 — the ArgoCD/observability placement call, deferred from plan 06.**
Plan 06 deliberately left this undecided, made only once `asw-app`'s own
2-node split (its Stage 2) was proven and real production-cutover context
existed. `ArgoCD` and Prometheus/Grafana/Loki/Alertmanager are
cluster-management tooling, not serving workloads — pin them to node 1
with a `nodeSelector` so a crash-looping or CPU-heavy pod on node 2 (where
`asw-nginx` and `cloudflared` live per plan 06) can never starve the
tools that tell you what's wrong of the resources they need. This isn't a
networking requirement (`ClusterIP` Services are reachable from any node
via `kube-proxy` regardless of pod placement) — it's resource isolation,
decided now because now is when it actually matters (real traffic about
to land), not guessed at during plan 06's node-join work.

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

**Stage 4 — no fixed soak duration.** This homelab's own practice discipline
(`devops-practice-plan.md`) already favors proving things "for real" over
assuming — give it enough real usage to be confident before touching
`app-server`, rather than a calendar-driven cutoff.

**Stage 5 — power off, don't destroy.** Matches the decision made while
planning this and the exact precedent in `plans/04-asw-db-vms-to-ct-migration-plan.md`.
`qm stop` on `app-server` (VM 101), leave it on disk. A `terraform destroy`
decision, if ever wanted, is explicitly a separate, later, conscious step —
not part of this plan.

---

## Verification

- Stage 0: `kubectl get nodes` shows 2 `Ready` nodes (plan 06); a
  throwaway commit alone (no manual `docker`/`kubectl`) reaches a running
  pod via CI → ArgoCD.
- Stage 1: `kubectl get pods -A -o wide` shows ArgoCD and the
  observability stack's pods on node 1 only.
- Stage 2: `kubectl exec deploy/asw-app -c app -- cat /vault/secrets/app.env`
  shows every `asw_secrets` field (not just DB passwords), real values.
- Stage 3: `curl https://animal-shelter-workshop.tttaufiqqq.com/api/database-status`
  → `5/5`; one real upload, one real password-reset email, one sandbox
  payment, all manually confirmed.
- Stage 5: `qm list` shows `app-server` (101) `stopped`, not destroyed;
  `curl` against the public domain still returns 200 with the VM off.
