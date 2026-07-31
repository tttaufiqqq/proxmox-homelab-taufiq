# Giving Shared Homelab Infrastructure Its Own Terraform

**Date:** 2026-07-28

## Why I built this

- The devops practice series (`docs/19-devops-practice/`) proved and then extended Terraform inside `Animal-Shelter-Workshop`'s own repo.
- Its plan states outright — **"Scope: Animal Shelter Workshop only"** — every stage targets that one project and the infrastructure that serves it.
- Importing the *entire* live Proxmox fleet into that same Terraform (see `docs/19-devops-practice/11`) quietly broke that boundary:
  - `linux-mini-io`, `linux-k3s`, `linux-mongodb`, and `linux-observability` aren't ASW-specific at all.
  - `linux-observability` monitors all 12 live hosts fleet-wide, not just ASW's.
  - `linux-mini-io` is general-purpose S3 storage that also backs `Library-System-EDP` (per this repo's own `README.md`), and now hosts Terraform's own state backend on top of that.
  - `linux-mongodb` isn't part of ASW's DB architecture at all — it's a separate, general-purpose document store.
  - `linux-k3s` is homelab-level compute, not tied to one app.
- Managing genuinely shared infrastructure from inside one coursework project's repo was the wrong home for it — this splits it out.

## What moved where

- **Stayed in `Animal-Shelter-Workshop`** — exactly what that project needs, nothing more:
  - Its 5 DB connections (`linux-mysql`, `linux-mysql-2`, `linux-mariadb`, `linux-mariadb-2`, `linux-postgres`), `app-server`, `linux-vault` (this app's secrets), and `linux-gh-runner` (this app's CI/CD).
  - 8 resources.
- **Moved here**, into this repo's own `infrastructure/terraform/`:
  - `linux-mini-io` (VM 109), `linux-k3s` (CT 100), `linux-mongodb` (CT 108), and `linux-observability` (CT 114).
  - 4 resources.
- **Deliberately outside Terraform everywhere:**
  - `opnsense` (the network's actual gateway) and the stopped legacy VMs (102/103/107, template 9000) — unchanged from `docs/19-devops-practice/11`'s original exclusions.

## How the move actually worked

- This repo had **no infrastructure code at all** before this — it's documented in its own `README.md` as "the running log of a personal homelab," docs and plans only.
- First time real (gitignored) credentials and live `.tf` resource management moved into it, worth naming rather than doing silently.
- `terraform state rm` and `terraform import` are pure bookkeeping — neither touches the real VM/CT — so the actual migration mechanics were low-risk, but still done in the safest order: import into the **new** location first, verify zero drift there, and only remove each resource from ASW's state once its replacement was already proven clean.

1. New MinIO bucket (`homelab-infra-tfstate`) and a separately-scoped
   credential (`terraform-homelab`, policy-restricted to only that
   bucket) on the same `linux-mini-io` MinIO instance ASW's Terraform
   already uses — same "scope the credential, not just the network"
   principle used for `terraform-asw`. A problem in one Terraform config's
   state can never touch the other's.
2. Scaffolded `infrastructure/terraform/` here: `main.tf` (same
   `bpg/proxmox` provider + SSH-node-override pattern as ASW's, pointed at
   the new bucket), `variables.tf`, `homelab-infra.tf` (the 4 resource
   blocks, copied verbatim from their already-proven-zero-drift form in
   ASW — same `cpu.type`, `cdrom.interface = "ide2"`,
   `on_boot`/`started`/`scsi_hardware` values; nothing about the real
   hosts changed, only which config tracks them).
3. Reused the same Proxmox API token and SSH credentials ASW's Terraform
   already uses — same automation identity, same homelab, no reason to
   mint a second Proxmox-side token for this.
4. Imported all 4 into the **new** state first. Same one-time residuals
   already known from `12` reappeared exactly as expected (CT computed
   defaults; the VM `cdrom` block always shows as an add once, since
   Proxmox doesn't persist it in a form the provider reads back) —
   applied those, confirmed `qm config`/`pct config` byte-identical
   before/after, same as last time.
5. Only once the new state showed `0 to change` on all 4: `terraform
   state rm` those 4 addresses out of ASW's old state, deleted the
   corresponding resource blocks from ASW's `containers.tf` and
   `production-vms.tf`, and confirmed ASW's own `terraform plan` still
   showed zero drift on its remaining 8 resources.

**One thing caught mid-task, not planned for upfront:**
- The original scope only named `linux-mini-io`/`linux-k3s`/`linux-observability`.
- Re-checking ASW's actual `terraform state list` before touching anything surfaced `linux-mongodb` too — never part of ASW's DB architecture, just imported into the same batch as everything else last time.
- Caught before any state was removed, added to the move.

## Verification

- `qm config 109` (`linux-mini-io`) and `pct config 100`/`108`/`114`
  (`linux-k3s`/`linux-mongodb`/`linux-observability`) byte-identical
  before vs. after the move, same discipline as `docs/19-devops-practice/11`.
- New repo's `terraform state list`: exactly 4 resources.
- ASW's `terraform state list`: exactly 8 resources — the 4 moved ones
  gone, nothing else touched.
- `terraform plan` clean on both sides (ASW shows only its disposable
  test loop's expected 8-resource create plan, unrelated to this move).
- `linux-mini-io`'s MinIO service, and both the old (`asw-tfstate`) and
  new (`homelab-infra-tfstate`) state buckets on it, confirmed reachable
  throughout — the VM itself was never touched, only Terraform's
  bookkeeping about who manages it.

## Where things live

| Piece | Path |
|---|---|
| New Terraform config | `proxmox-homelab-taufiq/infrastructure/terraform/` |
| The 4 moved resource blocks | `infrastructure/terraform/homelab-infra.tf` |
| New MinIO bucket + scoped user | `homelab-infra-tfstate` bucket, `terraform-homelab` user, both on `linux-mini-io` (not in git) |
| ASW's trimmed-down Terraform | `Animal-Shelter-Workshop/infrastructure/terraform/containers.tf` + `production-vms.tf` |
| ASW's updated docs | `Animal-Shelter-Workshop/docs/07-terraform.md`, `CLAUDE.md` (gitignored) |
| This write-up | `proxmox-homelab-taufiq/docs/20-homelab-terraform/homelab-terraform-split.md` |
