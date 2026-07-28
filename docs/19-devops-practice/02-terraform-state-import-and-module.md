<!-- Not yet sequenced into a numbered docs/ folder, lives here in
     docs/19-devops-practice/ until the full devops-practice-plan.md is complete.
     Date below is provisional (the date this actually happened); revisit
     once final sequencing/dating is decided. -->

# Terraform: State Backend, Adopting Production Containers, and a Real Module

**Date:** 2026-07-26
**Repo the actual code/infra changes live in:** `Animal-Shelter-Workshop`
(this write-up lives in the homelab meta-repo instead, alongside the devops
practice plan it's a stage of, see `devops-practice-plan.md`, Stage 1's
"harder exercises")

## Why I built this

- `01-terraform-first-real-loop.md` proved the base VM loop worked, but
  Stage 1's own checklist explicitly deferred three exercises until that
  base was solid:
  - move state off a local `.tfstate` file onto real infrastructure
  - decide whether `linux-mysql-2`/`linux-mariadb-2` (hand-provisioned LXC
    containers, still outside Terraform) get brought in too
  - stop hand-duplicating the same VM resource block four times
- All three were still open.

## Flow

```
┌────────────────────────────────────┐
│  STAGE 1, PART 2, STATE, IMPORT, MODULE │▏
└────────────────────────────────────┘▔▔

┌────────────────────────────────┐     done, self-hosted MinIO, bucket-
│ 1. Move state to MinIO backend   │▏    scoped credential (not root);
└────────────────────────────────┘▔▔    linux-mini-io set onboot:1
              │
              ▼
┌────────────────────────────────┐     done, 4 real schema gotchas found
│ 2. Prove zero drift on a         │▏    and fixed on a disposable scratch
│    disposable scratch container  │▏    container first, never on
└────────────────────────────────┘▔▔    production
              │
              ▼
┌────────────────────────────────┐     done, same zero-drift result;
│ 3. Import the real CTs           │▏    pct config byte-identical
│    (linux-mysql-2/mariadb-2)     │▏    before/after on both real,
└────────────────────────────────┘▔▔    live-data containers
              │
              ▼
┌────────────────────────────────┐     done, locals+for_each extracted
│ 4. Extract a reusable module     │▏    into modules/proxmox-vm/, same
└────────────────────────────────┘▔▔    8-resource plan, zero drift
```

## What I built

### 1. MinIO state backend

- State now lives on `linux-mini-io`'s self-hosted MinIO instead of a
  local file.
- A standard `backend "s3"` block works against it once pointed at
  MinIO's endpoint with `use_path_style = true` (MinIO doesn't do
  virtual-hosted-style bucket addressing).
- Same "scope the credential, not just the network" reasoning as the
  Azure backup SAS token: a dedicated `terraform-asw` MinIO user,
  policy-restricted to only the `animal-shelter-workshop-tfstate` bucket,
  not the MinIO root account.
- `linux-mini-io` turned out to be **stopped** when I went to use it, it's
  not part of the always-on core fleet.
- Had to `qm start 109` first, which is now called out explicitly in
  `docs/07-terraform.md` so it's not a surprise next time.
- Since Terraform now depends on it for every `plan`/`apply`, set
  `onboot: 1` (`qm set 109 --onboot 1`) so it survives a Proxmox host
  reboot without a manual restart.
- Migration itself was uneventful: the local state was already empty (the
  Stage 1 test VMs had been torn down), so there was nothing at risk.
- Verified with `terraform plan` reading cleanly from the new backend
  before deleting the local `.tfstate`/`.tfstate.backup` files.

### 2. Adopting `linux-mysql-2`/`linux-mariadb-2` into Terraform

- These aren't disposable test resources, they're the live `animals` and
  `booking` database connections, real containers with real data (see
  `CLAUDE.md`'s Server Topology table).
- Bringing them under Terraform management the wrong way means writing a
  resource block that doesn't quite match reality and having `apply`
  decide the fix is to destroy and recreate a production database.
- So the entire exercise was: **write the config, then prove zero drift
  before ever running `apply` for real.**

**The dry run.**
- Rather than experiment on production, I built a disposable scratch
  container (`pct create` from the same Ubuntu 24.04 template, same
  shape, with the same two custom raw LXC config lines these hosts have,
  `lxc.cgroup2.devices.allow` and `lxc.mount.entry`, which is what lets
  Tailscale's TUN device work inside an *unprivileged* container) and
  iterated against that instead:

- `operating_system.template_file_id` is a **required** argument in the
  provider's schema, but Proxmox doesn't persist which template a
  container was created from.
  - So on an imported container it always reads back unset, and declaring
    it forces a destroy-and-recreate on every plan.
  - Fixed with `lifecycle { ignore_changes = [operating_system] }`,
    satisfies the schema, never diffed after import.
- Omitting `console`/`initialization` blocks doesn't mean "leave as-is,"
  it means "unset this".
  - The first attempt showed a real in-place update that would have
    stripped hostname/DHCP config.
  - Had to declare them explicitly, matching current values.
- `device_passthrough` looked like the obvious way to represent the TUN
  device passthrough, it isn't.
  - It maps to Proxmox's newer, structured `devN:` mechanism, a
    completely different key from the legacy raw `lxc.*` lines these
    containers actually use.
  - Declaring it would have added a second, redundant passthrough path
    instead of managing the real one.
  - The correct answer was to **not declare it at all**, the raw lines
    aren't represented in the schema, so Terraform never touches them.
- Applied the one remaining diff (`timeout_*`/`vm_id`, computed defaults
  Terraform backfills on the very first plan after any import, never
  actually sent to the Proxmox API) to the scratch container.
  - Confirmed via `pct config` that its real config was **byte-identical
    before and after**.

- Only after that came back clean did I `terraform import` the real
  `linux-mysql-2` (CT 112) and `linux-mariadb-2` (CT 113), run `plan`
  again, and confirm the exact same result, the exact same residual diff,
  nothing else.
- Applied it scoped narrowly with `-target` (a plain `apply` right then
  would have also tried to recreate the already-torn-down test VMs).
- Confirmed `pct config` byte-identical on both real containers before
  and after.

### 3. A real reusable module

- `vms.tf`'s `locals { vms = {...} }` + two `for_each` resource blocks
  became `modules/proxmox-vm/`, the cloud-init file upload and VM
  resource, parameterized by `name`/`vmid`/`cores`/`memory`/`disk`/`vlan`.
- Root `vms.tf` is now just the map and a `for_each` module call.
- Since no VMs from that map currently exist in real infrastructure (torn
  down at the end of the last stage), this carried no production risk.
- `terraform validate` + `terraform plan` was enough: same 8-resource
  create plan as before (4 VMs + 4 cloud-init snippets), just addressed
  via `module.vm["..."]` instead of the old flat resource addresses.
- The two newly-adopted containers still showed zero drift throughout.
- One gotcha: a child module doesn't inherit the root's provider source
  alias automatically.
  - Without its own `required_providers` block naming `bpg/proxmox`,
    Terraform assumed the default `hashicorp/proxmox` registry namespace
    and failed to find it.

## Verification

- MinIO backend:
  - `terraform plan` reads/writes state correctly against
    `http://<linux-mini-io>:9000`.
  - Local `.tfstate` removed.
- Container import:
  - `pct config 112`/`113` confirmed **byte-identical** before and after
    the only applied diff, on both the scratch dry-run container and the
    real ones.
  - `terraform plan` shows `0 to change` for both going forward.
- Module refactor:
  - `terraform validate` succeeds.
  - `terraform plan` produces the identical 8-resource create plan as the
    pre-refactor config, just under module-scoped addresses.
  - The two containers remain undisturbed throughout.
- CI/CD:
  - Pushing these changes (`bd6151e`, `c67d585`, `b5c0f35`) did not break
    the pipeline, `Tests #34` (`b5c0f35`) completed green and fed a
    successful `Deploy #12`, confirmed via the GitHub Actions tab.
  - Expected, since none of the three commits touch
    `infrastructure/ansible/**`, which is the only thing `deploy.yml`'s
    playbook-running jobs currently act on.

## Where things live

| Piece | Path (in `Animal-Shelter-Workshop` unless noted) |
|---|---|
| MinIO backend config | `infrastructure/terraform/main.tf` |
| MinIO backend + Terraform prerequisites | `docs/07-terraform.md` |
| MinIO credentials (not in git) | `CLAUDE.md` (gitignored) |
| Adopted container resources | `infrastructure/terraform/containers.tf` |
| Reusable VM module | `infrastructure/terraform/modules/proxmox-vm/` |
| Root VM map + module call | `infrastructure/terraform/vms.tf` |
| Proxmox-side MinIO setup (not in git) | bucket `animal-shelter-workshop-tfstate`, user `terraform-asw`, policy `terraform-asw-tfstate` on `linux-mini-io` |
| This write-up | `proxmox-homelab-taufiq/docs/19-devops-practice/02-terraform-state-import-and-module.md` (homelab meta-repo) |
