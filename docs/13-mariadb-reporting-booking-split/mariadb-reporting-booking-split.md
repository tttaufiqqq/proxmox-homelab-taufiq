# Splitting `reporting`/`booking` off `linux-mariadb` onto their own hosts

**Date:** 2026-07-20
**Goal:** Following the `shelter`/`animals` split earlier the same day (see
[`docs/12-mysql-shelter-animals-split/`](../12-mysql-shelter-animals-split/mysql-shelter-animals-split.md)),
the same gap existed one connection pair over: `reporting` and `booking` shared one physical
MariaDB server (`linux-mariadb`, VM 105). This finishes the job — every one of
[`Animal-Shelter-Workshop`](https://github.com/tttaufiqqq/Animal-Shelter-Workshop)'s 5 Laravel
connections now has its own dedicated physical machine, no exceptions.

## Decision: CT, same reasoning as last time

New CT (113, `linux-mariadb-2`) rather than a VM, for the exact reasons already established for
`linux-mongodb`/`linux-vault`/`linux-mysql-2`: the Proxmox host is capped at 4 cores, a CT skips
the per-VM kernel/init overhead, and `reporting`/`booking` both need to run persistently for the
live app. `linux-mariadb` keeps `reporting`; `booking` moves to the new CT — arbitrary which pair
member stays vs. moves, mirroring how `shelter` stayed on `linux-mysql` and `animals` moved.

## What went smoothly this time

Applying every lesson from the MySQL split up front meant CT 113 was the cleanest build yet:

- `--nameserver`/`--searchdomain` set at `pct create` time — no DNS bug.
- TUN device fix applied before the first `tailscale up` — no "no backend" error.
- Skipped the dead auth-key entirely and went straight to interactive browser login (the
  `terraform.tfvars` key was already known-bad from the previous build).
- The Ansible playbook (`linux-mariadb-2.yml`, a straight copy of `linux-mariadb.yml` retargeted
  at the new host) ran clean on the first attempt — no lost root password, no stale sudo access,
  because this CT never had a prior abandoned setup attempt sitting on it the way `linux-mysql`
  (VM 104) did.

## The one real mistake: dropping live tables before cutover

Every previous host in this migration series was either brand new or already empty before any
`DROP TABLE` ran. `linux-mariadb` wasn't — it was, at the moment of cleanup, still the **live**
host actively serving the running app's `booking` connection. The cleanup step (drop `booking`'s
6 tables + its 24 procedures off the reporting-designated host, matching the same "restore full
dump to both hosts, then trim" pattern used for MySQL) was run *before* `DB4_HOST` was
repointed at the new CT — meaning for a brief window, the live app's `booking` connection was
pointed at a host whose `booking`/`transaction`/`adoption`/`visit_list`/`visit_list_animal`/
`animal_booking` tables had just been dropped.

Caught immediately (the very next step was verifying row counts, which is what surfaced it) and
fixed by cutting `DB4_HOST` over to `linux-mariadb-2` — which already had the full, correct,
already-cleaned data restored — right away. Total exposure window: under a minute, no data lost
(a full dump was already sitting on app-server as a safety net, and the new host's copy was
already verified-populated before the drop even ran). Confirmed both connections working
immediately after (`booking` table count 601, `reporting`'s `report` count 200 — both matching
pre-migration numbers exactly).

**The actual lesson, not just this one incident:** when a migration reuses an existing host that
is *currently serving live traffic* for one of the two things being split (as opposed to msi vs.
`linux-mysql`, where the new host was never live), the cutover must happen **before** any
destructive cleanup on the host that keeps serving one of the two connections — not after. The
correct order is: populate + verify the new host, cut the config over, *then* clean up the old
host's now-unneeded tables. Doing the cleanup first on a still-live host is backwards regardless
of how quickly a mistake like this gets caught.

## Migration mechanics

`reporting`+`booking` were one physical `workshop_2` database on `linux-mariadb` (9 tables: 3 for
reporting — `report`, `rescue`, `image`; 6 for booking — `booking`, `transaction`, `adoption`,
`visit_list`, `visit_list_animal`, `animal_booking`). Same approach as the MySQL split: dump the
whole database once, restore in full onto the new CT, then drop what didn't belong from each
side (`booking`'s objects off `linux-mariadb`, `reporting`'s objects off `linux-mariadb-2`) —
`DROP TABLE` cascades its triggers, procedures needed explicit `DROP PROCEDURE`. Verified against
live row counts before touching anything: `report` 200, `rescue` 158, `image` 612, `booking` 601,
`transaction` 47, `adoption` 51, `visit_list` 3, `visit_list_animal` 0, `animal_booking` 896 —
every count matched exactly on both final hosts. `App\Services\Backup\BackupTargetResolver`'s
naming fix (from the MySQL split) generalized correctly with no further code changes — a
`db:backup` run immediately produced 5 correctly-named, correctly-sized targets
(`mariadb-reporting-workshop2` / `mariadb-booking-workshop2` among them). 95 existing tests
covering the reporting/booking procedures, triggers, and fee calculations passed against the new
hosts.

## Current State

| CT/VM | Tailscale IP | Role |
|---|---|---|
| `linux-mariadb` (VM 105) | 100.78.124.25 | `reporting` connection only, as of this split |
| `linux-mariadb-2` (CT 113) | 100.97.35.29 | `booking` connection |

Every one of `Animal-Shelter-Workshop`'s 5 Laravel connections now has its own dedicated
physical host: `reporting` → `linux-mariadb`, `booking` → `linux-mariadb-2`, `shelter` →
`linux-mysql`, `animals` → `linux-mysql-2`, `users` → `linux-postgres`.
