<!-- Not yet sequenced into a numbered docs/ folder, lives here in
     docs/19-devops-practice/ until the full devops-practice-plan.md is complete.
     Date below is provisional (the date this actually happened); revisit
     once final sequencing/dating is decided. -->

# Terraform: Proving CT Creation, and the Full Loop End to End

**Date:** 2026-07-28
**Repo the actual code/infra changes live in:** `Animal-Shelter-Workshop`
(this write-up lives in the homelab meta-repo instead, alongside the devops
practice plan it's a stage of, see `devops-practice-plan.md`, Stage 1)

## Why I built this

`01-terraform-first-real-loop.md` proved Terraform could create a VM from
scratch. It never proved Terraform could create a **CT** from scratch —
every real CT this project manages (`linux-mysql-2`, `linux-mariadb-2`,
`linux-vault`, `linux-gh-runner`) was adopted via `terraform import`,
hand-built first. This closes that gap, and goes one step further than
`01` did: proving the *entire* pipeline lands a genuinely working app, not
just that machines boot. Terraform creates the machine, a manual bridge
handles the one thing Terraform's schema can't express (a CT's Tailscale
join), and Ansible configures real software on top — MySQL, MariaDB,
PostgreSQL, and as much of `app-server` as doesn't require a real public
domain.

To make room for this, the real production fleet (`app-server` and the 3
original DB VMs) was intentionally stopped first, freeing capacity for the
test loop to run without contending with live traffic. Once the loop was
proven end to end, every test machine was torn back down — this was never
meant to be a second permanent environment, same discipline as `01`.

## Where I started

```
┌─────────────────────────────────────────────────────────────────────┐
│         PROVE THE MISSING HALF: CT CREATION + THE FULL LOOP          │
│   "Can Terraform build a CT from scratch, and can the whole chain    │
│    actually configure a working app, not just boot machines?"        │
└─────────────────────────────────────────────────────────────────────┘

  ┌──────────────────────┐     stopped app-server + the 3 original DB
  │ 0. free up capacity    │▏    VMs, then linux-oracle-db too —
  └──────┬────────────────┘▔▔    6.7GB → 10GB available
         │
         ▼
  ┌──────────────────────┐     test-mysql-2 / test-mariadb-2, sized
  │ 1. add 2 CTs to the    │▏    small (512MB) since this only proves
  │    disposable test     │▏    creation works, not real load
  │    loop                │▔▔
  └──────┬────────────────┘
         │
         ▼
  ┌──────────────────────┐     4 VMs + 2 CTs, staged as TWO separate
  │ 2. terraform apply     │▏    applies after the first attempt hit a
  └──────┬────────────────┘▔▔    Proxmox lock timeout applying both at once
         │
         ▼
  ┌──────────────────────┐     TUN device workaround + reboot, then
  │ 3. CT-only bridge      │▏    install + join tailscale via `pct exec` —
  │    (manual, by hand)   │▏    no cloud-init equivalent exists for CTs
  └──────┬────────────────┘▔▔
         │
         ▼
  ┌──────────────────────┐     WSL can't trust ansible.cfg from /mnt/c,
  │ 4. ansible-playbook    │▏    can't resolve MagicDNS, and 3 real
  │    site.yml            │▏    playbook assumptions broke against a
  └──────┬────────────────┘▔▔    genuinely fresh host — all fixed, below
         │
         ▼
  ┌──────────────────────┐     all 5 DB hosts fully configured;
  │ 5. verify + collapse   │▏    app-server to the one real domain
  └────────────────────────┘▔▔   boundary; then destroyed everything
```

## What I found

**Capacity was tighter than expected, even with production stopped.**
Stopping `app-server` + the 3 original DB VMs only freed the host to
6.7GB available — `linux-oracle-db`, `opnsense`, `linux-mini-io`, and
`linux-observability` were all still running independently. Stopping
Oracle too got it to 10GB available, enough for the 4 VMs (8GB) plus 2
small CTs (1GB) with real margin. The 2 new CTs were deliberately sized at
512MB/1 core rather than matching their real counterparts — they only
needed to prove creation works, not carry load.

**A Proxmox lock timeout when VMs and CTs apply together.** The first
`terraform apply` (4 VMs + 2 CTs, one command) errored on both CT starts:
`can't lock file '/run/lock/lxc/pve-config-<id>.lock' - got timeout`. The
containers were actually created and running fine underneath — only the
API's status polling hit the lock contention, not the real operation.
Root cause: 4 concurrent VM clones are I/O-heavy enough on a 4-core host
to starve the CT start tasks' lock acquisition. Terraform marked both CTs
"tainted" as a result, which would have destroyed and recreated two
perfectly healthy containers for nothing — `terraform untaint` instead.
The real fix, proven on the second full run: **apply VMs and CTs as two
separate stages**, not by tuning `-parallelism` down (which would have
slowed the 4 VMs' own parallelism too, for no reason — they never
actually collided with each other).

**Cloned VM disks don't track `file_format`.** Every one of the 4 VMs
showed `file_format: "raw" -> "qcow2"` as a plan diff that persisted
identically even after applying it — Proxmox's clone operation doesn't
preserve that attribute the way a fresh disk creation does. Same category
as `02`'s `operating_system.template_file_id` lesson for CTs. Fixed
properly with `disk[0].file_format` added to `modules/proxmox-vm`'s
`ignore_changes`, not by repeatedly applying.

**Fresh CTs need three things Terraform's schema can't provide, done by
hand via `pct exec` straight from the Proxmox host** (no network path
into the CT needed yet, since it has none at this point):
1. The TUN device workaround (the two raw `lxc.*` config lines) + a
   `pct reboot` to apply it — same lesson as the adopted CTs.
2. `curl` isn't preinstalled on the vztmpl image at all — needed
   `apt-get install curl` before Tailscale's install script could even run.
3. Tailscale itself has no CT equivalent of cloud-init's first-boot
   script — install + `tailscale up --authkey=...` had to run as an
   explicit extra step, unlike the VMs, where cloud-init handles this
   automatically.

**`terraform destroy` doesn't deregister a machine from Tailscale.**
Recreating the 4 VMs (same hostnames) after destroying the first attempt
collided with their own stale "offline" Tailscale device entries —
MagicDNS appended `-1` to every one of them (`test-mysql-1`, etc.) to
disambiguate. The 2 CTs didn't hit this, since they were joining Tailscale
for the first time (their first attempt never got far enough to actually
join before being destroyed). Real, recurring gotcha for any future
destroy+recreate cycle: check `tailscale status` after, don't assume a
plain hostname still points at the current machine.

**Running Ansible from WSL against files on `/mnt/c` breaks more than
just role lookup.** `ansible-playbook` isn't installed on Windows at all,
so this had to run from WSL. First attempt failed with "role
'mysql_family' not found" — but the real cause, visible in Ansible's own
warning, was that it distrusts `ansible.cfg` entirely when the directory
looks "world writable" (a WSL/NTFS permission quirk on `/mnt/c` mounts,
not a real security issue). That silently drops `roles_path`, but also
`remote_user` and `private_key_file` — everything the config file sets.
Fixed by copying the `ansible/` directory to WSL's native filesystem and
running from there instead, which also happens to match how the real
pipeline actually works: production Ansible runs on `linux-gh-runner`, a
native Linux VM, never from a Windows/WSL hybrid mount.

**WSL can't resolve Tailscale MagicDNS hostnames.** Same class of problem
this repo already hit once (`.scratch-inventory-ip-override.yml` exists
for exactly this reason, for the real production hosts). The new
`.scratch-inventory-test-loop.yml` needed raw Tailscale IPs in
`ansible_host`, not hostnames.

**Fresh CTs only ever get a `root` account — never `workshop`.** The VMs'
cloud-init explicitly creates `workshop` (and `taufiq`, per `01`'s fix);
a CT's `initialization.user_account` block only sets up SSH keys for
`root`, with no equivalent mechanism to create additional users. Fixed by
overriding `ansible_user: root` for the two CT hosts in the inventory.

**A real playbook assumption broke against a genuinely fresh clone of an
existing role.** `mysql_family_bootstrap_root_auth` is hardcoded `false`
in `linux-mysql-2.yml`/`linux-mariadb-2.yml`, because the *real*
`linux-mysql-2`/`linux-mariadb-2` were already hand-configured with
password auth before this playbook ever touched them (see
`docs/12-mysql-shelter-animals-split`). That assumption is correct for
those specific real hosts, and wrong for a genuinely fresh MySQL install
under the same role — the test CTs still had root on socket auth,
untouched. Fixed for this run with
`-e '{"mysql_family_bootstrap_root_auth": true}'` (note: must be real
JSON, not a bare `-e var=true` string — this Ansible version rejects a
string result in a `when:` boolean context).

**The one deliberate stopping point, not a bug:** `app-server.yml` fails
at "Deploy .env from template" because `app_domain`/`certbot_email` are
undefined — correct behavior, since those variables gate a real certbot
TLS run against a real public DNS record (see
`docs/09-production-hardening.md`'s TLS section). Faking a domain for a
disposable test VM would mean pointing real DNS at a throwaway host for
nothing. 27 tasks succeeded before this point: PHP 8.3, Nginx, Composer,
Node.js installed, the real `Animal-Shelter-Workshop` repo cloned,
permissions set, Composer dependencies installed.

## Verification

- All 5 DB hosts (`linux-mysql`, `linux-mysql-2`, `linux-mariadb`,
  `linux-mariadb-2`, `linux-postgres`) completed with **zero real
  failures** — real MySQL/MariaDB/PostgreSQL installed, configured,
  database + user created, UFW firewall rules applied.
- Idempotency held even here: re-running against the already-configured
  `linux-mysql` on the second full pass showed `changed=0` across the
  board (bar the one already-known-ignored legacy-backup task), matching
  Stage 2's original idempotency proof.
- `app-server` reached 27 successful tasks before the deliberate
  `app_domain` boundary.
- `qm config`/`pct config` confirmed byte-identical on every host after
  the disk `file_format` and CT schema fixes were applied.
- Everything collapsed afterward: `linux-vault` stopped back down,
  all 6 test resources (`terraform destroy`, 10 resources including
  cloud-init files) destroyed, host back to baseline (8.1GB free / 10GB
  available, matching pre-exercise levels).

## Planned next step — not yet built

A bash/shell script to automate stages 2-4 above (staged `terraform
apply`, the CT TUN/Tailscale bridge, waiting for every host to actually
show *online* on Tailscale — not just present in `tailscale status`,
since offline hosts stay listed too — then handing off to
`ansible-playbook`) was designed but deliberately **not committed as code
yet**, per the call to document the plan first and build it later. Its
shape, once built:

1. `terraform apply -target=<the 4 VMs>` — separate from stage 2, since
   combining them is what caused the lock timeout.
2. `terraform apply -target=<the 2 CTs>`.
3. TUN device fix + reboot for each CT, idempotent (guarded with `grep -q`
   before appending, safe to re-run).
4. Install + join Tailscale on each CT via `pct exec` (no network path
   into the CT needed yet).
5. Poll `tailscale status`, excluding lines containing `offline`, until
   every host is confirmed actually online — not just listed.
6. Hand off to `ansible-playbook -i .scratch-inventory-test-loop.yml
   playbooks/site.yml`, run from WSL's native filesystem, not `/mnt/c`.

Building this for real should also account for the two overrides that
were manual this time (`ansible_user: root` for the CTs, already in the
inventory; `mysql_family_bootstrap_root_auth=true`, currently a manual
`-e` flag) — worth deciding whether the script hardcodes that extra-var
for every test-loop run, or whether it stays a manual reminder in the
script's own comments.

## Where things live

| Piece | Path (in `Animal-Shelter-Workshop` unless noted) |
|---|---|
| The 2 new test CTs | `infrastructure/terraform/vms.tf` |
| Cloned-disk `file_format` fix | `infrastructure/terraform/modules/proxmox-vm/main.tf` |
| Test-loop inventory (gitignored) | `infrastructure/ansible/.scratch-inventory-test-loop.yml` |
| This write-up | `proxmox-homelab-taufiq/docs/19-devops-practice/13-terraform-ct-creation-and-full-loop-proof.md` (homelab meta-repo) |
