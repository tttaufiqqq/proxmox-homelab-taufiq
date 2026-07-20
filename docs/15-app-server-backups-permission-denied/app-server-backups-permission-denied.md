# `app-server`: `/admin/backups` 500s — a security setting fighting a documented feature

**Date:** 2026-07-20
**Goal:** Right after fixing the
[log permission bug](../14-laravel-log-permission-denied/laravel-log-permission-denied.md), the
admin backups panel 500'd too. Same server, same afternoon, but this one turned out to be a
different shape of problem — not accidental drift, a setting that was *intentionally* locked down
now directly blocking a feature that's supposed to read from the same place.

## Symptom

`/admin/backups` (PATCH... no, GET, straightforward page load) 500'd with:

```
ErrorException
scandir(/home/taufiq/Animal-Shelter-Workshop/storage/app/backups): Failed to open directory: Permission denied
```

Trace pointed straight at `App\Services\Backup\BackupManifest::all()`, line 42 — the `scandir()`
call that lists every backup run directory to build the admin panel's history table.

## Diagnosis

```bash
ssh taufiq@100.100.123.90
sudo ls -la /home/taufiq/Animal-Shelter-Workshop/storage/app/backups/
```

```
drwx--S--- 6 taufiq taufiq 4096 Jul 20 01:41 .
drwx--S--- 2 taufiq taufiq 4096 Jul 19 18:07 20260719_180705
drwx--S--- 2 taufiq taufiq 4096 Jul 20 01:12 20260720_011211
...
```

`taufiq:taufiq`, mode `0700` — `rwx------`. No access at all for group or other. `php-fpm` runs as
`www-data` (confirmed the same way as the log bug — `ps aux | grep php-fpm`, `id www-data`), which
isn't `taufiq` and isn't in `taufiq`'s group, so it falls into "other" — zero permissions.

This wasn't drift. `infrastructure/ansible/playbooks/app-server.yml` sets this directory
deliberately:

```yaml
# php artisan db:backup writes nightly dumps here — the whole reason for
# centralizing on app-server, since dumps then survive losing any single
# DB VM. Mode 0700: these files contain full database contents.
- name: Create the centralized database backups directory
  file:
    path: /home/taufiq/Animal-Shelter-Workshop/storage/app/backups
    state: directory
    owner: taufiq
    group: taufiq
    mode: "0700"
```

That comment is a real, considered decision — full database dumps are sensitive, keep them away
from the internet-facing process. Except `docs/10-backups.md` (written the same day, same
migration series) documents `/admin/backups` as an actual feature:

> **Admin UI**: `/admin/backups` ... reads `Cache::get('backup_last_status')` plus every
> `manifest.json` under `storage/app/backups/`

Two decisions, made close together, that directly contradict each other: one says "web server
process gets nothing here," the other says "the web server process reads this on every page load."
This isn't a bug that crept in from an unrelated change — it's two intentional choices that were
never checked against each other.

## Checking whether the `0700` was actually doing what the comment says

Before deciding how to fix it, worth checking what the mode was really protecting. Looked at a
run directory's contents, not just the directory itself:

```bash
sudo ls -la /home/taufiq/Animal-Shelter-Workshop/storage/app/backups/20260720_014101/
```

```
-rw-rw-r-- 1 taufiq taufiq   2039 Jul 20 01:41 manifest.json
-rw-rw-r-- 1 taufiq taufiq  25555 Jul 20 01:41 mariadb-booking-workshop2.sql.gz
-rw-rw-r-- 1 taufiq taufiq 141279 Jul 20 01:41 pgsql-workshop2.dump
```

Mode `664` — the trailing `r--` means *other* already had read access to every dump's actual
content. The `0700` on the parent directory was the only thing standing between `www-data` and the
raw dumps; the files themselves were never independently hardened. So "these files contain full
database contents" was true, but the protection was one directory-traversal check deep, not a
real access-control boundary on the content itself.

## Does the boundary actually buy anything here?

The app's own `.env` already hands `www-data` live, working credentials to all 5 production
databases — that's how the app serves every page. A process that can already run arbitrary queries
against the live databases doesn't gain anything by additionally reading a point-in-time `.sql.gz`
of the same data. Locking backups away from `www-data` specifically doesn't shrink what an attacker
who compromises the app can reach; the live databases are already reachable and are a superset of
what's in any single dump.

Given that, and that a real documented feature needs the access, decided to open the whole backups
tree to `www-data` rather than build something more surgical (e.g. code changes so `manifest.json`
is group-readable but the dump payloads stay owner-only) — the extra plumbing that would have
required doesn't buy meaningful security here.

## Fix

Immediate, on the existing tree:

```bash
BACKUPS=/home/taufiq/Animal-Shelter-Workshop/storage/app/backups
sudo chgrp -R www-data "$BACKUPS"
sudo find "$BACKUPS" -type d -exec chmod 0750 {} \;
sudo find "$BACKUPS" -type f -exec chmod 0640 {} \;
sudo chmod g+s "$BACKUPS"
sudo find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d -exec chmod g+s {} \;
```

`0750` on directories (`rwxr-x---`) gives `www-data` list+traverse via the group; `0640` on files
gives it read. Setgid on the root and every existing run directory so nightly runs created after
this keep landing in the `www-data` group automatically (Linux propagates the setgid bit itself to
new subdirectories created inside a setgid directory, not just the group — confirmed by the same
mechanism used for `storage/logs` in the log-permission fix).

Verified as `www-data` directly, the same way the log fix was verified:

```bash
sudo -u www-data bash -c 'ls /home/taufiq/Animal-Shelter-Workshop/storage/app/backups/ && cat /home/taufiq/Animal-Shelter-Workshop/storage/app/backups/20260720_014101/manifest.json | head -c 200'
```

Listed all 4 run directories and printed the manifest — both operations `BackupManifest::all()`
actually performs.

## Making it stick

`app-server.yml`'s directory-creation task now matches what's actually needed:

```yaml
- name: Create the centralized database backups directory
  file:
    path: /home/taufiq/Animal-Shelter-Workshop/storage/app/backups
    state: directory
    owner: taufiq
    group: www-data
    mode: "02750"
```

Only the root directory needed a task change — nightly run directories are created later by
`php artisan db:backup` itself, not by Ansible, and setgid on the root means they inherit the right
group and the setgid bit without any extra playbook logic.

## Current State

| Item | Before | After |
|---|---|---|
| `storage/app/backups` owner:group | `taufiq:taufiq` | `taufiq:www-data` |
| `storage/app/backups` mode | `0700` | `02750` (setgid) |
| Run subdirectories / files | `0700` / `0664`, group `taufiq` | `0750` / `0640`, group `www-data` |
| `app-server.yml` | `group: taufiq`, `mode: "0700"` | `group: www-data`, `mode: "02750"` |

`/admin/backups` reads manifests as `www-data` correctly now. The original "full database
contents" concern is still worth remembering if this project ever handles real data — at that
point, the right fix is the more surgical one considered and set aside here: keep `manifest.json`
group-readable, chmod the dump payloads owner-only at creation time in `DatabaseDumper`, so the
admin UI works without ever giving the web process read access to a full raw dump.
