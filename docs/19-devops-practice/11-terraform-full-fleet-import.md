<!-- Not yet sequenced into a numbered docs/ folder, lives here in
     docs/19-devops-practice/ until the full devops-practice-plan.md is complete.
     Date below is provisional (the date this actually happened); revisit
     once final sequencing/dating is decided. -->

# Terraform: Bringing the Rest of the Fleet In

**Date:** 2026-07-28
**Repo the actual code/infra changes live in:** `Animal-Shelter-Workshop`
(this write-up lives in the homelab meta-repo instead, alongside the devops
practice plan it's a stage of, see `devops-practice-plan.md`, Stage 1)

## Why I built this

- Doc `01` (this series' consolidated overview doc) covers proving the
  Terraform loop once (a disposable test set, VMs 201/204/205/206, torn
  down right after) and adopting two hand-built LXCs
  (`linux-mysql-2`/`linux-mariadb-2`) into state.
- Everything else the homelab actually runs in production was still
  hand-configured outside Terraform — `app-server` and the other three
  original DB VMs, plus every CT built by hand since (`linux-k3s`,
  `linux-mongodb`, `linux-vault`, `linux-gh-runner`, `linux-observability`).
- A claim written up for a public post — "no more manually clicking through
  GUI buttons for every machine, the .tf files handle it for me" — turned out
  to only be true for new VMs and those two CTs.
- This closes that gap for real: importing the rest of the live fleet, one
  host at a time, proving zero drift on each before trusting it.

## Where I started

```
┌─────────────────────────────────────────────────────────────────────┐
│           STAGE 1 (AGAIN): IMPORT THE WHOLE REST OF THE FLEET        │
│      "Can every real host, not just 2 CTs, be Terraform-managed?"    │
└─────────────────────────────────────────────────────────────────────┘

  ┌──────────────────────┐     confirmed empty of the old test-loop
  │ 0. terraform state    │▏    keys — renaming them later is a free
  │    list first          │▏    relabel, not a `state mv`
  └──────┬────────────────┘▔▔
         │
         ▼
  ┌──────────────────────┐     pct create 199, prove a STOPPED
  │ 1. scratch CT dry run  │▏    container imports with zero drift
  └──────┬────────────────┘▔▔    and Terraform doesn't boot it
         │
         ▼
  ┌──────────────────────┐     k3s (100) → mongodb (108) → gh-runner
  │ 2. import 5 real CTs   │▏    (111) → observability (114) → vault
  └──────┬────────────────┘▔▔    (110, most critical, last)
         │
         ▼
  ┌──────────────────────┐     qm create 198, prove cpu type / cdrom /
  │ 3. scratch VM dry run  │▏    network firewall / on_boot / started /
  └──────┬────────────────┘▔▔    scsi_hardware gotchas before touching prod
         │
         ▼
  ┌──────────────────────┐     mysql (104) → mariadb (105) → postgres
  │ 4. import 5 real VMs   │▏    (106) → app-server (101) → mini-io (109,
  └──────┬────────────────┘▔▔    hosts Terraform's own state backend, last)
         │
         ▼
  ┌──────────────────────┐     locals.vms keys → test- prefix, now that
  │ 5. rename test loop    │▏    real production resources share the
  └──────┬────────────────┘▔▔    same roles
         │
         ▼
  ┌──────────────────────┐     terraform plan: 0 to change on all 10
  │ 6. fleet-wide re-check │▏    real hosts (only the disposable test
  └────────────────────────┘▔▔   loop's 8-resource create plan remains)
```

## What I found

**Real spec drift, worse than the known vmid confusion.**
- `qm config`/`pct config` on every target host showed real drift from what a
  naive copy of the existing module/`containers.tf` pattern would assume:
  cores (1 for the 3 DB VMs, 2 for `app-server`/`linux-mini-io`, not a flat
  2), disk sizes (28G/22G/22G/22G/18G+32G, not a flat 20), and
  `cpu: x86-64-v2-AES` on every VM (not the module's hardcoded
  `type = "host"`).
- Every production VM still had its original install ISO attached on `ide2`.
- `linux-mini-io` turned out to have a **second real disk** (`scsi1`, 32G —
  the actual MinIO data volume) that needed its own `disk` block.

**Two containers were genuinely powered off.**
- `linux-k3s` (100) and `linux-mongodb` (108) were stopped at import time —
  not part of the always-on core fleet.
- Unlike the CT import in `01` (both hosts there were running),
  `started = false` had to be declared explicitly for these two so `apply`
  wouldn't boot them as a side effect of being adopted.

**`onboot` is inconsistent across the fleet, and I mis-transcribed it once.**
- `linux-vault` and `linux-gh-runner` have no `onboot` flag set at all in
  real life — a genuine, pre-existing gap (neither survives a host reboot
  today), left alone rather than silently "fixed" as part of this import.
- I initially copied `linux-mongodb` into that same bucket from memory, then
  caught it re-checking the live `pct config` right before import:
  `linux-mongodb` actually has `onboot: 1`.
- Fixed before importing, not after — exactly the kind of mistake this
  host-by-host verify-before-import discipline exists to catch.

**`linux-vault`'s raw LXC lines are duplicated.**
- `pct config 110` lists the two TUN-device lines twice.
- Harmless — Proxmox just accumulated a duplicate append at some point — left
  alone, noted here rather than silently ignored.

**Three VM-resource attributes default away from reality if undeclared.**
- Found building the scratch VM dry run, before touching any real host.
- `on_boot` and `started` both default to `true` on the
  `proxmox_virtual_environment_vm` resource when left undeclared — none of
  the 4 production DB/app VMs have `onboot` set in real life, so leaving
  these out would have had Terraform try to enable auto-start on the very
  first `apply`.
- `scsi_hardware` defaults to `"virtio-scsi-pci"`; every real host here uses
  `"virtio-scsi-single"`.

**`cdrom` can never be read back on import.**
- Same category as `01`'s `operating_system.template_file_id` lesson for
  CTs — Proxmox doesn't persist it in a form the provider's read populates
  into state, so it shows as an "add" on the very first `plan` after import,
  regardless of whether it matches reality.
- The provider's own default `interface` for an undeclared cdrom is
  `"ide3"`, which doesn't match any of these hosts' real `"ide2"` —
  declaring `interface = "ide2"` explicitly made the one-time apply a
  genuine no-op against the Proxmox API rather than adding a second,
  unrelated cdrom device.
- Confirmed via `qm config` byte-identical before/after on every host.

**The "vmid drift" flagged in `docs/12-mysql-shelter-animals-split` wasn't a
bug.**
- `vms.tf` declaring the test loop's `linux-mysql` as vmid 204 while the real
  one is 104 was never a collision — the test loop and the real production
  VM are different Terraform resources entirely (module instance vs. root
  resource), so nothing was ever at risk.
- The actual fix was naming clarity, not a bug fix: the test loop's
  `locals.vms` keys are now `test-` prefixed, so `terraform state list`
  reads unambiguously now that real production resources exist alongside
  them.

**Deliberately excluded:**
- `opnsense` (200 — the network's actual gateway, a different risk class
  than everything else here).
- The stopped legacy VMs (102, 103, 107) plus template 9000 — not part of
  the live fleet.

## Verification

- `qm config`/`pct config` diffed byte-for-byte before vs. after, on all 10
  real hosts (5 CTs: `linux-k3s`, `linux-mongodb`, `linux-gh-runner`,
  `linux-observability`, `linux-vault`; 5 VMs: `linux-mysql`,
  `linux-mariadb`, `linux-postgres`, `app-server`, `linux-mini-io`) —
  identical in every case.
- `terraform plan` (full, unfiltered) shows `0 to change, 0 to destroy` on
  every one of those 10 hosts; the only remaining action is the disposable
  test loop's `8 to add` (4 VMs + 4 cloud-init snippets) — expected and
  inert, since that loop was never meant to persist in state (see `01`).
- `linux-vault`: confirmed `vault status` showed `Sealed: false` immediately
  before *and* immediately after its own import — the most critical host in
  this batch, imported last among the CTs deliberately.
- `app-server`: confirmed `curl http://localhost/` returned `HTTP 200`
  immediately before and after its import.
- `linux-mysql`: confirmed MySQL still responded (auth-rejected, not
  connection-refused) after its import.
- `linux-mini-io`: confirmed `terraform state list` still resolved cleanly
  immediately after importing the VM that hosts Terraform's own S3 state
  backend — imported dead last of all 10 hosts, specifically so a mistake
  there couldn't jeopardize state access for everything imported before it.

## Where things live

| Piece | Path (in `Animal-Shelter-Workshop` unless noted) |
|---|---|
| The 5 newly-adopted CTs | `infrastructure/terraform/containers.tf` |
| The 5 newly-adopted production VMs | `infrastructure/terraform/production-vms.tf` (new file) |
| Test-loop key rename (`test-` prefix) | `infrastructure/terraform/vms.tf` |
| Updated Terraform docs (full host table, new lessons learned) | `docs/07-terraform.md` |
| Stale "hand-configured box" line corrected | `docs/09-production-hardening.md` |
| Server Topology table, Terraform-managed column added | `CLAUDE.md` (gitignored) |
| This write-up | `proxmox-homelab-taufiq/docs/19-devops-practice/11-terraform-full-fleet-import.md` (homelab meta-repo) |

## What happened to the scratch resources

- One scratch CT (199) and one scratch VM (198), both built fresh (never
  cloned from a real host), used only to prove the schema-level gotchas
  above before touching anything real.
- Both destroyed (`pct destroy 199` / `qm destroy 198`) immediately after
  their dry runs confirmed zero drift — same "never experiment on
  production" discipline `01` established for the container import.
