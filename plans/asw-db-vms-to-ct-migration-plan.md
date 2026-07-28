# Animal-Shelter-Workshop DB VMs → CTs Migration Plan

A staged plan to convert three Proxmox VMs backing
[`Animal-Shelter-Workshop`](https://github.com/tttaufiqqq/Animal-Shelter-Workshop)
into LXC containers, to reclaim real RAM on a single-node, RAM-bound
Proxmox host — motivated by wanting room to self-host Jenkins as a future
experiment, but scoped down to just the RAM-reclaiming migration itself.

---

## Context

The motivating idea was self-hosting Jenkins as an experiment, but the
homelab's single Proxmox host (`taufiq` — 4 cores, 15.51 GiB RAM, no
cluster) is RAM-bound, not CPU-bound. Live numbers pulled while planning
this (`ssh proxmox "free -h"`, `qm list`, `pct list`):

```
Mem:  15Gi total, 6.5Gi used, 5.3Gi free, 4.1Gi buff/cache, 9.1Gi available
Swap: 7.6Gi total, 2.0Gi used, 5.6Gi free
```

...with only `linux-mini-io` (VM), `opnsense` (VM), `linux-vault` (CT,
512MB) and `linux-observability` (CT, 1536MB) actually running at that
moment — everything else (all 3 original DB VMs, app-server, k3s,
mongodb, gh-runner, the `-2` DB CTs) was powered off. This repo's own
`plans/devops-practice-plan.md` already measured this same ceiling on
2026-07-26 and named the fix: **converting `linux-mysql`/`linux-mariadb`
from VMs to CTs is "the biggest single lever" for reclaiming RAM**, because
Proxmox VMs here have no balloon device — their declared memory is
pinned/reserved by KVM regardless of actual use, while CTs share the host
kernel and are only cgroup-limited, so idle daemons actually give RAM back.

Scope, decided while planning this:
- **`app-server` (VM 101) is explicitly out of scope** — stays a VM.
- **Scope is the three DB VMs that back Animal-Shelter-Workshop**:
  `linux-mysql` (VM 104), `linux-mariadb` (VM 105), and `linux-postgres`
  (VM 106) — all three confirmed convertible (pure userspace daemons, no
  special kernel features, same class as `linux-mongodb` CT 108, which
  already proves a real DB engine runs fine as an unprivileged CT here).
  Postgres has no CT precedent in this fleet yet (mysql/mariadb both have
  proven `-2` siblings), so it gets extra validation care below, but
  nothing in its Ansible role depends on VM-only features.
- **Old VMs**: power off and keep on disk as a rollback safety net once
  each new CT is validated — do not destroy immediately.
- **Jenkins itself**: not stood up in this pass. This plan ends with the
  RAM freed and a ready-to-apply Jenkins CT sketch (see end), left for
  a separate, later `terraform apply` whenever the experiment is actually
  wanted — mirrors how `linux-gh-runner` here is only powered on when
  actually needed.

This migration touches the **sibling repo**
`Animal-Shelter-Workshop` (local path
`C:\Users\taufi\Documents\Dev\Animal-Shelter-Workshop`), not this one —
that repo owns `app-server`/DB VM Terraform and Ansible per the split
documented in this repo's
[`docs/20-homelab-terraform/homelab-terraform-split.md`](../docs/20-homelab-terraform/homelab-terraform-split.md).
The Jenkins CT (follow-up, not applied now) belongs in *this* repo's
`infrastructure/terraform/homelab-infra.tf` instead, since it's
homelab-shared, not ASW-specific — same ownership logic as that split doc.

---

## What's already proven (de-risks this)

- **Terraform CT shape**: `containers.tf`'s `linux_mysql_2`/`linux_mariadb_2`
  blocks are the exact template to copy — unprivileged, Ubuntu 24.04
  standard template, `vlan_id = 20` (**same VLAN as the VMs today** — no
  network/firewall change needed), `features.nesting = true`,
  `lifecycle { ignore_changes = [operating_system] }` (mandatory —
  `template_file_id` isn't persisted by Proxmox, so every plan would
  otherwise show a forced replace). Tailscale's TUN device needs two raw
  lines appended directly to `/etc/pve/lxc/<id>.conf` (not via bpg's
  `device_passthrough`, which is a different, newer mechanism):
  ```
  lxc.cgroup2.devices.allow: c 10:200 rwm
  lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
  ```
- **Ansible roles already run unmodified against CT targets**:
  `linux-mysql-2.yml`/`linux-mariadb-2.yml` are literal copies of
  `linux-mysql.yml`/`linux-mariadb.yml` retargeted at CTs 112/113, and both
  provisioned clean on the first attempt using the same `mysql_family`/
  `db_firewall` roles. The only real diff is
  `mysql_family_bootstrap_root_auth` (`true` on the VMs, since they need the
  auth-socket→password recovery flow; a fresh CT will need `true` too, same
  as the VMs originally did) and `roles: [legacy_backup_cleanup]`, which only
  applies to the original VMs and should be **dropped** for the new CTs
  (same as the `-2` pair — backups are already centralized through the
  app's own `db:backup` Artisan command, not a per-host timer).
- **Postgres role** (`roles/postgres_db`) has no VM-only assumptions either
  — installs `postgresql`+`psycopg2`+`acl`, sets `listen_addresses`/
  `pg_hba.conf`, creates DB from `template0` (already dodges a
  locale/encoding issue seen in the role's own Molecule tests against
  minimal container images — a good sign for a fresh CT).

---

## The one real risk area: migrating live data, not just rebuilding the host

Unlike a from-scratch CT, these three already hold real (lab) data for the
`shelter`/`reporting`/`users` connections. Proxmox has no VM→CT conversion
path — this is rebuild + data migration + cutover, not an in-place import.

1. **Take a fresh dump from each VM right before migrating** — reuse the
   app's own dump tooling (`app/Services/Backup/DatabaseDumper.php`):
   `mysqldump --single-transaction --routines --triggers --events <db>` /
   `pg_dump --format=custom --clean --if-exists`. **Must be a dump taken
   now, not an old one** —
   [`docs/16-stored-routine-definer-privilege-split/`](../docs/16-stored-routine-definer-privilege-split/stored-routine-definer-privilege-split.md)
   documents a real production outage caused by restoring a *stale*
   pre-fix dump whose routines/triggers still carried the wrong
   `DEFINER=`. A fresh dump carries today's already-fixed
   `SQL SECURITY INVOKER` procedures/functions and correctly-defined
   triggers forward safely.
2. **Grant what the restore needs on the new CT before restoring**, per
   `docs/10-backups.md`'s restore-drill notes (in the sibling ASW repo):
   - MySQL 8: `GRANT SHOW_ROUTINE, SET_USER_ID ON *.* TO 'workshop_2_prod'@'%';`
   - MariaDB: `GRANT SELECT ON mysql.proc TO 'workshop_2_prod'@'%'; GRANT SUPER ON *.* TO 'workshop_2_prod'@'%';`
3. **Verify before touching the old VM** — restore onto the new CT, check
   row counts match the pre-migration source exactly, then run the app's
   real test suite (or at minimum a manual smoke test per connection)
   against the new host. Only *after* that passes, cut the app's config
   over. This mirrors the real incident already logged in
   [`docs/13-mariadb-reporting-booking-split/`](../docs/13-mariadb-reporting-booking-split/mariadb-reporting-booking-split.md):
   cutting a table-drop before the config pointed at the new host briefly
   served the live app against a broken database. Cutover before cleanup,
   always.
4. **Reuse the Tailscale hostname to avoid any config change at all.**
   Production's `.env` (rendered from
   `infrastructure/ansible/templates/env-app.j2`) points `DB2_HOST`/
   `DB1_HOST`/`DB5_HOST` at the **Tailscale MagicDNS hostnames**
   `linux-mysql`/`linux-mariadb`/`linux-postgres`, not raw IPs. If the old
   VM is logged out of the tailnet first and the new CT joins claiming the
   *same* hostname, `env-app.j2`/`config/database.php` need zero edits —
   the hostname just resolves to the new host once DNS/MagicDNS catches up.
   Confirm this resolves correctly before declaring cutover done.
5. **Update `inventory-ip.yml`'s `ansible_user`** for whichever host is
   converted — the existing VMs use bespoke legacy usernames
   (`workshop-mysql`, `workshop-2`, `workshop-postgres`) unrelated to their
   hostnames; the proven CT convention (112/113) uses a plain username
   matching the hostname (`linux-mysql-2`). Follow that convention for the
   new CTs. `inventory.yml` (hostname-based) needs no change — group
   membership and MagicDNS name are unchanged.

---

## Staged execution

**Stage 0 — capacity check.** `ssh proxmox "free -h"` fresh before starting
(numbers above will already be stale by the time this runs). Old VMs stay
running during their own migration (need live data to dump); don't power on
anything else non-essential during the transition.

**Stage 1 — one DB at a time (mysql → mariadb → postgres), not in parallel:**
- Terraform (`Animal-Shelter-Workshop/infrastructure/terraform/`): add a
  new `proxmox_virtual_environment_container` block to `containers.tf`
  (new CT ID — e.g. 115/116/117, since the old VM is being *kept*, not
  destroyed, so its ID stays taken), copying the `linux_mysql_2` shape
  exactly (1 core to match the source VM's real `cpu.cores = 1`,
  `memory.dedicated = 2048` + `swap = 512`, `disk.size = 22` to match the
  VM's real disk, `vlan_id = 20`). Apply this **as its own
  `terraform apply`**, not combined with any VM change — the fleet already
  hit a Proxmox lock-timeout bug (`/run/lock/lxc/pve-config-<id>.lock`)
  applying VMs and CTs together on this 4-core host.
- On the Proxmox host: append the two raw TUN lines to the new CT's conf
  file, `pct reboot`, then `tailscale up` (expect to need the interactive
  browser-login flow — the stored auth key in `terraform.tfvars` is already
  documented dead).
- Run the matching Ansible playbook (a copy of `linux-mysql.yml` etc.,
  retargeted, `legacy_backup_cleanup` role dropped) against the new CT.
- Dump the live VM, restore onto the new CT per the risk section above,
  verify row counts + a manual smoke test.
- Log the old VM out of Tailscale, let the new CT claim the same hostname,
  confirm `.env`'s `DB*_HOST` resolves correctly with no file edits needed.
- Update `inventory-ip.yml`'s `ansible_user` for this host.
- Power off the old VM (`qm stop`) — **do not destroy** — and re-run the
  app's smoke tests one more time against the now-CT-only setup before
  moving to the next database.

**Stage 2 — repeat for the next DB**, same sequence. Doing one at a time
keeps blast radius small and makes it obvious which host caused a problem
if something breaks.

**Stage 3 — cleanup decision (later, not part of this pass):** once all
three CTs have run stable for a while, decide whether to actually
`terraform destroy` the three old VM resources in `production-vms.tf` (they
currently carry an explicit "do not destroy" comment — that comment will
need a deliberate, conscious edit once you're ready) or keep them powered
off indefinitely as insurance.

---

## Follow-up (not applied in this pass): Jenkins CT sketch

Once real RAM is reclaimed above, a Jenkins CT is homelab-shared
infrastructure (not ASW-specific), so it belongs in **this** repo's
`infrastructure/terraform/homelab-infra.tf`, alongside `linux-k3s`/
`linux-observability`, on VLAN 30 (compute, same as `linux-gh-runner`):
unprivileged, Ubuntu 24.04 template, start small (1 core / 1.5–2 GB,
matching this homelab's established "start small, `pct set` to grow later"
convention for k3s/observability), `features.nesting`/`keyctl = true` if
Docker-based build agents are wanted later, `start_on_boot = false` since
this is an on-demand experiment, not a permanent fixture — same reasoning
already applied to `linux-gh-runner`. Apply this in its own
`terraform apply`, separately, whenever you're actually ready to try it.

---

## Verification

- Per DB: row counts on new CT match the pre-migration dump; app's test
  suite (or manual smoke test) passes against the new host; `curl`/app
  UI paths touching that connection work end-to-end through the live app.
- `ssh proxmox "free -h"` before/after each conversion to see the actual
  RAM delta — confirms the "CTs give RAM back" premise for real rather
  than assuming it.
- `qm list` / `pct list` to confirm the old VM is `stopped` (not destroyed)
  and the new CT is `running` after each stage.
- Only after all three are converted and stable: revisit whether there's
  now enough headroom to comfortably run a Jenkins CT alongside the normal
  fleet without swapping — re-run the same `free -h` capacity check the
  existing `devops-practice-plan.md` already uses as its working rule.
