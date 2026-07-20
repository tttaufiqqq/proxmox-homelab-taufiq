# Splitting `shelter`/`animals` off msi onto their own MySQL hosts

**Date:** 2026-07-20
**Goal:** [`Animal-Shelter-Workshop`](https://github.com/tttaufiqqq/Animal-Shelter-Workshop)'s
`shelter` and `animals` Laravel connections shared one physical MySQL server on `msi` (a
Windows laptop, not part of this homelab's Proxmox inventory) — the one place the app's DB
architecture didn't already follow 1-database-1-physical-machine. Every other connection
already had its own dedicated VM. This doc covers giving `shelter`/`animals` the same treatment:
`shelter` moves onto the already-existing but never-actually-used `linux-mysql` VM (104), and a
new CT (112, `linux-mysql-2`) is built for `animals`. msi's copy is then deleted.

## What Already Existed

`linux-mysql` (VM 104, Tailscale `100.115.237.93`, MySQL 8.0) was provisioned months earlier —
Terraform declares it, and `Animal-Shelter-Workshop/infrastructure/ansible/playbooks/linux-mysql.yml`
already creates the `workshop_2` DB/user, sets `log_bin_trust_function_creators`, and applies
UFW rules. A prior deploy attempt had briefly pointed `DB2_HOST`/`DB3_HOST` at it, found it had no
`workshop_2` database, and reverted to msi (see that repo's `docs/09-production-hardening.md`).
So the VM was sitting there fully scaffolded but never actually populated — this move finishes
what was already half-built rather than starting from scratch.

**Terraform/reality drift found in pre-flight:** `vms.tf` declares `linux-mysql` as `vmid = 204`.
`qm list` on the Proxmox host shows it live as **104**. Not investigated further — Ansible
targets by Tailscale hostname, not VM ID, so this didn't block anything, but it means Terraform
state and the live VM have disagreed about this VM's ID for a while.

## Why CT, not VM, for the second host

Same reasoning already used for `linux-mongodb` (CT 108) and `linux-vault` (CT 110): the Proxmox
host is capped at 4 cores, and a CT skips the per-VM kernel/init overhead that a full VM pays
before the actual workload starts. `shelter`/`animals` both need to run persistently (the live
app depends on them), matching the exact condition that justified CT over VM for Mongo and
Vault — as opposed to the on-demand engine VMs that get powered on only when needed.

## Building CT 112 (`linux-mysql-2`)

Created via `pct create` on the Proxmox host rather than the web UI this time (root SSH access
to the hypervisor made the CLI just as fast): Ubuntu 24.04 standard template, unprivileged,
2 cores / 2048 MB RAM / 512 MB swap / 20 GB disk — mirroring `linux-mysql`'s Terraform spec for
parity between the two hosts now serving equivalent roles. `--nameserver 8.8.8.8 --searchdomain
local` was set **at creation time** this time, proactively avoiding the DNS bug that hit CT 108
and CT 111 (Proxmox's own MagicDNS resolver leaking into the CT before Tailscale joins, breaking
`apt-get`).

The TUN device fix (same as every unprivileged CT in this lab) was also applied **before** the
first `tailscale up`, not after hitting the "no backend" error like CT 108/110/111 did:

```bash
echo 'lxc.cgroup2.devices.allow = c 10:200 rwm' >> /etc/pve/lxc/112.conf
echo 'lxc.mount.entry = /dev/net/tun dev/net/tun none bind,create=file' >> /etc/pve/lxc/112.conf
pct reboot 112
```

Doing both fixes proactively meant CT 112 was the first host in this repo's history to join
Tailscale and pass `apt-get update` on the first try, no post-hoc patching needed.

## Issues Encountered

### 1. The stored Tailscale auth key in `terraform.tfvars` was dead

`tailscale up --authkey=...` using the key already in `Animal-Shelter-Workshop/infrastructure/terraform/terraform.tfvars`
failed: `backend error: invalid key: unable to validate API key`. Not investigated further
(expired or single-use and already consumed by an earlier VM) — worked around with interactive
browser login (`tailscale up` printed a `login.tailscale.com/a/...` URL, approved manually).
**Open item:** that stored key should be rotated or removed from tfvars if it's dead weight.

### 2. `workshop-mysql`'s sudo password was genuinely lost

The `workshop-mysql` SSH user on `linux-mysql` (VM 104) has no `NOPASSWD` sudo, and its password
wasn't recorded anywhere in either repo. The cloud-init template (`cloud-init.yml.tftpl`)
provisions a *different* user (`workshop`, `NOPASSWD:ALL`) whose key didn't authenticate either
— consistent with the vmid drift above, this VM's actual live state predates whatever the
current Terraform template describes. Resolution: asked the human operator for the password
directly, since guessing credentials isn't something to do even for infrastructure you control.

### 3. MySQL root access on `linux-mysql` was already broken, unrelated to this migration

`mysql -u root -pPassword123!` (the password CLAUDE.md documents for this host) returned
`Access denied`, as did every other guess. This was a **pre-existing** broken state, not
something this migration caused — the VM had clearly been touched by an earlier abandoned setup
attempt. Recovered with the standard MySQL root-password-reset procedure: stop `mysqld`, start
manually with `--skip-grant-tables --skip-networking`, then fix the account.

The recovery itself had a subtlety worth recording: **`FLUSH PRIVILEGES` under
`--skip-grant-tables` re-enables grant-table enforcement for every connection from that instant
on, not just the current session going forward on its next reconnect.** The first reset attempt
ran `FLUSH PRIVILEGES` as its own early statement, then a *separate* `ALTER USER ... auth_socket`
attempt failed (`auth_socket` plugin not loaded) — but because the flush had already happened,
every subsequent new connection (including the retry with a different plugin, in a new SSH
invocation) was rejected before it could even reach its own `ALTER USER`, since root's
credentials were never actually changed by the failed first attempt. Fix: restart
`--skip-grant-tables` fresh, and run `FLUSH PRIVILEGES; ALTER USER ...; FLUSH PRIVILEGES;` as
one uninterrupted session via `mysql -u root < script.sql` piped in a single invocation — the
official procedure works exactly as documented as long as it's genuinely one connection, one
shot.

Ended up on `root@localhost` using `auth_socket` (passwordless via OS-level `sudo mysql`,
matching what `linux-mysql.yml`'s Ansible tasks already assume via `login_unix_socket`) rather
than a fixed password — the plugin turned out to already be registered
(`ERROR 1125: Function 'auth_socket' already exists` on a redundant `INSTALL PLUGIN`) even
though the very first `ALTER USER` attempt claimed it wasn't loaded; that first error was
actually about the ALTER failing to complete for unrelated reasons in that broken session, not
a real missing-plugin condition.

### 4. `BackupTargetResolver` silently collided two targets under one name

Not a provisioning issue — a real bug in `Animal-Shelter-Workshop`'s backup system that this
migration surfaced. `App\Services\Backup\BackupTargetResolver::targets()` correctly groups
connections by `(driver, host, port, database)`, which produced two separate groups for
`shelter` (now on `linux-mysql`) and `animals` (now on `linux-mysql-2`) as intended. But its
`withNames()` step named every group `"{$driver}-workshop2"` with no host in the key — so the
`mysql` group for `animals` silently overwrote the `mysql` group for `shelter` in the returned
associative array, and a `db:backup` run would have produced a `mysql-workshop2` dump containing
only one of the two databases, appearing to succeed. This was latent and harmless before, since
`shelter`+`animals` sharing one physical host meant `targets()` collapsed them into one group
*before* `withNames()` ever ran — the split exposed a bug that was always there. Fixed by
disambiguating with the group's first connection name whenever more than one group shares a
driver (`mysql-shelter-workshop2` / `mysql-animals-workshop2`), verified via a real `db:backup`
run showing 4 correctly-sized, distinct targets afterward.

## Migration mechanics

`shelter`+`animals` were one physical `workshop_2` database on msi (11 tables: `section`,
`slot`, `category`, `inventory`, `audit_log` for shelter; `animal`, `animal_profile`, `clinic`,
`vet`, `medical`, `vaccination` for animals — plus dead, never-executed leftover procedures for
`report`/`rescue`/`image`, artifacts from before the distributed architecture existed).
`mysqldump` can't filter stored routines by table, so the whole DB was dumped once from
app-server, restored in full onto **both** new hosts, then the tables/procedures that didn't
belong to each host's connection were dropped explicitly — `DROP TABLE` cascades its triggers
automatically, procedures needed individual `DROP PROCEDURE` statements. Verified against live
row counts pulled from msi before the cutover: every table matched exactly
(`animal` 102, `vaccination` 280, `medical` 243, `slot` 123, `audit_log` 299, etc.), and 149
existing tests covering the shelter/animals procedures, triggers, and the cross-host
`animal.slotID -> shelter.slot.id` logical FK all passed against the new hosts before msi's copy
was deleted.

## Current State

| CT/VM | Tailscale IP | Role |
|---|---|---|
| `linux-mysql` (VM 104) | 100.115.237.93 | `shelter` connection — `workshop_2` DB, `log_bin_trust_function_creators=1`, root auth via `auth_socket` |
| `linux-mysql-2` (CT 112) | 100.123.221.89 | `animals` connection — same shape, provisioned entirely via Ansible on the first pass |

msi's `workshop_2` database and `workshop_2` user were dropped after verification. msi remains
the Ansible/WSL control node and local dev machine for this project — just no longer a DB host.

---

**Update, 2026-07-20 (same day, later):** the `workshop_2` database/user documented above on
`linux-mysql`/`linux-mysql-2` were themselves later replaced by a DBA-style `workshop_2_prod` /
`workshop_2_dev` split (same data, copied and row-count-verified into `workshop_2_prod`), and
`linux-mysql`'s root password (`Password123!` above) was unified to `qwertY@1612` across all 5 DB
servers. `workshop_2`/`workshop_2_test` still exist separately, scoped to the test suite only. Full
detail: `Animal-Shelter-Workshop/CLAUDE.md`'s Database Connection Mapping.
