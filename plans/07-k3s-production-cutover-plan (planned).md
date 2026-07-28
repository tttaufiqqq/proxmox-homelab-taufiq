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
┌────────────────────────────────┐     Cloudinary/mail/ToyyibPay/Azure
│ 1. Wire the REST of asw_secrets  │▏    backup creds — currently missing
│    into k3s, not just DB creds   │▏    from k8s/app-secret.yaml entirely
└────────────────────────────────┘▔▔
              │
              ▼
┌────────────────────────────────┐     hit the real public domain, confirm
│ 2. Verify the real thing          │▏    5/5 DBs online, uploads/mail/
│                                   │▏    payments all work for real
└────────────────────────────────┘▔▔
              │
              ▼
┌────────────────────────────────┐     let it run under real traffic for a
│ 3. Soak period                    │▏    while before touching app-server
│                                   │▏    at all — no fixed rollback deadline
└────────────────────────────────┘▔▔
              │
              ▼
┌────────────────────────────────┐     qm stop, NOT destroy — same
│ 4. Power off app-server            │▏    rollback-safety-net pattern as
│    (rollback safety net only)     │▏    plan 04's old DB VMs
└────────────────────────────────┘▔▔
```

---

## Why each stage is there

**Stage 1 — the DB creds aren't the only thing missing.** `k8s/app-secret.yaml`
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

**Stage 2 — verify the real thing, not just `/up`.** `/api/database-status`
showing `5/5 online` (from plan 05) is necessary but not sufficient here —
also manually check a real upload (Cloudinary), trigger a real password
reset email (mail), and confirm a ToyyibPay sandbox payment still redirects
correctly, since Stage 1 is what's supposed to make all of those work for
the first time inside k3s.

**Stage 3 — no fixed soak duration.** This homelab's own practice discipline
(`devops-practice-plan.md`) already favors proving things "for real" over
assuming — give it enough real usage to be confident before touching
`app-server`, rather than a calendar-driven cutoff.

**Stage 4 — power off, don't destroy.** Matches the decision made while
planning this and the exact precedent in `plans/04-asw-db-vms-to-ct-migration-plan.md`.
`qm stop` on `app-server` (VM 101), leave it on disk. A `terraform destroy`
decision, if ever wanted, is explicitly a separate, later, conscious step —
not part of this plan.

---

## Verification

- Stage 0: `kubectl get nodes` shows 2 `Ready` nodes (plan 06); a
  throwaway commit alone (no manual `docker`/`kubectl`) reaches a running
  pod via CI → ArgoCD.
- Stage 1: `kubectl exec deploy/asw-app -c app -- cat /vault/secrets/app.env`
  shows every `asw_secrets` field (not just DB passwords), real values.
- Stage 2: `curl https://animal-shelter-workshop.tttaufiqqq.com/api/database-status`
  → `5/5`; one real upload, one real password-reset email, one sandbox
  payment, all manually confirmed.
- Stage 4: `qm list` shows `app-server` (101) `stopped`, not destroyed;
  `curl` against the public domain still returns 200 with the VM off.
