# All 4 MySQL/MariaDB DB servers: every stored procedure and trigger broken by the prod/dev split

**Date:** 2026-07-20
**Goal:** A user report of two failed actions in the live app
([`Animal-Shelter-Workshop`](https://github.com/tttaufiqqq/Animal-Shelter-Workshop)) —
"Failed to delete report" and "Failed to assign caretaker" — turned out to be one root cause
affecting the app's *entire* MySQL/MariaDB stored-procedure layer across all 4 hosts
(`reporting`, `booking`, `shelter`, `animals`), not just the two actions reported. `users`
(PostgreSQL) was unaffected.

## Symptom

```
Failed to delete report: SQLSTATE[42000]: Syntax error or access violation: 1370 execute command
denied to user 'workshop_2'@'%' for routine 'workshop_2_prod.sp_image_read_by_report'
(Connection: reporting, SQL: CALL sp_image_read_by_report(201))

Failed to assign caretaker: SQLSTATE[42000]: Syntax error or access violation: 1370 execute command
denied to user 'workshop_2'@'%' for routine 'workshop_2_prod.sp_rescue_assign_caretaker'
(Connection: reporting, SQL: CALL sp_rescue_assign_caretaker(...))
```

The confusing part: the app connects to `reporting` as `workshop_2_prod` (confirmed live —
`grep DB1_USERNAME` on `app-server`'s real `.env` showed `workshop_2_prod`, correctly, per the
2026-07-20 DBA-style prod/dev split — see `Animal-Shelter-Workshop/CLAUDE.md`'s Database
Connection Mapping). The error names `workshop_2`, an account the app was never configured to use
for this database. That mismatch is what made this look like a credential-configuration bug at
first, rather than a privilege bug on objects already sitting in the database.

## Diagnosis

Reproduced directly against `linux-mariadb` (100.78.124.25, the `reporting` host), bypassing the
app entirely:

```
$ mysql -u workshop_2_prod -p'workshop_2_prod' workshop_2_prod -e "CALL sp_report_read(1);"
ERROR 1370 (42000): execute command denied to user 'workshop_2'@'%' for routine 'workshop_2_prod.sp_report_read'
$ mysql -u root -p'...' workshop_2_prod -e "CALL sp_report_read(1);"
ERROR 1370 (42000): execute command denied to user 'workshop_2'@'%' for routine 'workshop_2_prod.sp_report_read'
```

**Even `root` — global `ALL PRIVILEGES` plus `SUPER` — got denied, with the same error naming
`workshop_2`.** That ruled out a caller-side privilege gap immediately: whatever was being
checked, it wasn't the connecting user's own grants.

`SHOW PROCEDURE STATUS` explained it:

```
Db               Name            Type       Definer       Security_type
workshop_2_prod  sp_report_read  PROCEDURE  workshop_2@%   DEFINER
```

Every routine's `DEFINER` was still `workshop_2@%` — the *old*, pre-split shared credential. Under
`SQL SECURITY DEFINER` (MariaDB/MySQL's default), a routine's privilege checks run against the
**definer's** account, not the caller's. `workshop_2`'s grants are deliberately scoped to only
`workshop_2_test`/`workshop_2_restore_test` (see `Animal-Shelter-Workshop/CLAUDE.md` — unrelated to
and untouched by the prod/dev split, by design). `workshop_2` has zero privileges on
`workshop_2_prod`, so **nobody** can successfully `CALL` a `workshop_2`-defined routine there —
not the app's real credential, not even `root`.

Root cause, upstream: `workshop_2_prod` was populated by dumping the old shared `workshop_2`
database and restoring it onto the new host (`docs/12-mysql-shelter-animals-split/`,
`docs/13-mariadb-reporting-booking-split/`) — `mysqldump`/restore preserves `DEFINER=` clauses
verbatim from the source. Confirmed this wasn't universal: `workshop_2_dev` (populated by each
developer running a clean `php artisan migrate` directly against the new credential, per
`Animal-Shelter-Workshop/CLAUDE.md`) already had the correct `DEFINER=workshop_2_dev@%` on every
routine — only the dump-restored `_prod` database carried the stale definer forward. `users`
(PostgreSQL) checked too — every function's owner was already `workshop_2_prod` and none use
`SECURITY DEFINER` at all, so this bug class doesn't apply there.

**Scope, once checked across all 4 MySQL-family hosts:** every single stored procedure and trigger
in `workshop_2_prod` on every host had `DEFINER=workshop_2@%`. This was a full production outage
of the entire stored-procedure layer, not a two-routine bug — the user's two reported failures
just happened to be the first two anyone hit.

| Host | Connection | Procedures affected | Triggers affected |
|---|---|---|---|
| `linux-mariadb` (100.78.124.25) | `reporting` | 15 | 5 |
| `linux-mariadb-2` (100.97.35.29) | `booking` | 23 | 11 |
| `linux-mysql` (100.115.237.93) | `shelter` | 16 | 16 |
| `linux-mysql-2` (100.123.221.89) | `animals` | 21 | 14 |

75 procedures, 46 triggers — 121 objects across 4 servers.

## Fix

Two mechanisms, chosen deliberately over re-pointing `DEFINER` at `workshop_2_prod`:

- **Procedures/functions:** `ALTER PROCEDURE <name> SQL SECURITY INVOKER;` — an in-place, no-body
  change. The routine now runs with the *calling* user's privileges instead of a fixed definer's.
  Since the app always connects as `workshop_2_prod`/`workshop_2_dev` (each already holding full
  privileges on its own database), this just works — and unlike re-pointing `DEFINER`, it's immune
  to this exact bug recurring on any future credential rename. Nothing in this app needs elevated
  cross-schema definer rights, so the security-model change is a no-op in practice.
- **Triggers:** MariaDB/MySQL triggers have no `SQL SECURITY INVOKER` option — they always execute
  as their `DEFINER`. Fixed with `DROP TRIGGER` + `CREATE DEFINER=workshop_2_prod@% TRIGGER ...`,
  body extracted verbatim from `information_schema.TRIGGERS.ACTION_STATEMENT` (needed
  `DELIMITER $$` wrapping — bodies use `BEGIN...END` blocks with internal semicolons) and generated
  per-host via `mysql --raw -N` (`--raw` matters: without it, the client escapes embedded newlines
  in query output as literal `\n`, breaking the generated script's `DELIMITER` line boundaries).
  Verified byte-identical trigger bodies via `SHOW CREATE TRIGGER` before/after, and matched
  `--default-character-set=utf8mb4` on the fix script's own connection — the first pass on
  `linux-mariadb` silently recreated a trigger under `utf8mb3`/`utf8mb3_general_ci` instead of the
  original `utf8mb4`/`utf8mb4_unicode_ci` (harmless here, every literal in these bodies is ASCII,
  but worth getting right rather than leaving a silent charset drift).

Applied to all 4 hosts directly over SSH/`mysql` (root credential, `qwertY@1612` — see
`Animal-Shelter-Workshop/CLAUDE.md`). Verified with:
1. `SELECT COUNT(*) ... WHERE definer='workshop_2@%' AND security_type='DEFINER'` → `0` on every
   host, for both procedures and triggers.
2. Reproduced the exact two originally-failing calls directly: `sp_image_read_by_report(201)`
   returns cleanly; `sp_rescue_assign_caretaker(999999, ...)` reaches its own "Report not found"
   validation instead of the privilege error (deliberately called with a nonexistent report ID so
   the safety check would catch it before any write, rather than risking a real data mutation from
   this SSH session).
3. `Animal-Shelter-Workshop`'s full `Procedures` test suite (112 tests) still passes — unaffected,
   since it runs against `workshop_2_test`, whose routines were always correctly defined by
   `workshop_2` (the account that actually owns that database).

No application code or Ansible playbook changes were needed — this was purely a state fix on
objects already sitting in the database. No app-server redeploy or restart needed either: the fix
takes effect on the very next query, since nothing about it is cached anywhere in the app (Laravel
doesn't cache stored-routine privilege state).

## Consequence worth stating plainly

Any *future* restore of `workshop_2_prod` from a dump taken **before** this fix (an old on-disk
backup, if one exists — see `Animal-Shelter-Workshop/docs/10-backups.md`) would reintroduce the
stale `DEFINER=workshop_2@%` on every object, and this whole class of failure would come back.
Dumps taken *after* this fix carry the corrected `SQL SECURITY INVOKER`/`DEFINER=workshop_2_prod@%`
state forward correctly, since `mysqldump` captures whatever the live objects currently are. Not
worth building an automated guard for in a homelab with no real data — noted here so a future
restore-from-old-backup drill isn't a surprise.
