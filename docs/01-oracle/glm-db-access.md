# GLM Project — Database Access & DBA Notes

Quick-reference for connecting to and administering the `GLM_APP` schema
(Green Lifestyle Market backend — [`green-lifestyle-market`](https://github.com/tttaufiqqq/green-lifestyle-market)
— `FREEPDB1` on `linux-oracle-db`). Full
Oracle connectivity background lives in
[`docs/03-datagrip/datagrip-connectivity.md`](../03-datagrip/datagrip-connectivity.md) —
this doc only covers what's specific to this one project. For how GLM is hosted,
see [`docs/04-spring-boot/spring-boot-setup.md`](../04-spring-boot/spring-boot-setup.md).

> **Scope note:** GLM is a learning project with no real users — "prod" below just
> means "the schema the deployed copy uses," kept separate from "dev" for DBA practice
> (isolation, blast radius, credential hygiene), not because a real outage is at stake.

## Connecting

The existing homelab connection points at service **`FREE`** (the CDB root)
as `sys`. That can't see `GLM_APP` — in Oracle's multitenant architecture,
the CDB root and the `FREEPDB1` pluggable database are separate containers,
not just a filter. To browse this project's data:

1. New connection (or edit existing): **Service Name = `FREEPDB1`**, not `FREE`.
2. Connection settings → Oracle tab → enable **"Show all schemas"**
   (defaults to showing only the connected user's own schema).
3. Navigate: `Database Navigator → connection → Schemas → GLM_APP → Tables`.

> Written while the GUI client in use was DBeaver, since replaced by DataGrip
> (see `docs/03-datagrip/datagrip-connectivity.md`); the "Show all schemas"
> toggle lives under the equivalent Oracle connection settings in DataGrip
> too, but hasn't been re-verified there since the switch.

## Accounts

All Oracle credentials for this DB (`linux-oracle-db`, `FREEPDB1`), instance-wide and
GLM-specific. No `@` in Oracle passwords — see
[`docs/03-datagrip/datagrip-connectivity.md`](../03-datagrip/datagrip-connectivity.md).

| User | Role | Password | Use |
|---|---|---|---|
| `sys` | Instance superuser (SYSDBA) | `qwertY1612` | Full-instance admin, `FREE` (CDB root) |
| `system` | DBA account | `qwertY1612` | Same as `sys`, admin on `FREE` |
| `glm_app` | **Prod** schema owner | `GlmApp_Ora26Q1Prod` — reset 2026-07-14 (previous value unknown/lost to rotation) | Deployed app only (`spring-boot-app` VM, port 8081) — 44 real tables, has `GLM_FDA` |
| `glm_app_dev` | **Dev** schema owner | `GlmAppDev_Ora26Q3` — reset 2026-07-17 (previous value `GlmAppDev_Ora26Q1` no longer authenticated; cause unknown, not a documented rotation) | Local dev/IT tests only, from the workstation — has `GLM_FDA_DEV` |
| `glm_dev` | Interactive/DBA (human) | `GlmDev_Ora26Q3` | Personal DBeaver login for browsing/admin work — added 2026-07-14 |

## Dev/prod split (2026-07-14)

`backend/src/test/java/.../MigrationIT.java` drops and recreates its target schema
on every run. It used to point at `glm_app` — the same schema the deployed app now
uses in prod, with real migrated data. Running the IT suite locally would have
wiped it. Fixed by giving dev its own schema, `glm_app_dev`, and repointing the test
and `backend/.env` at it instead.

This also surfaced a second problem: `V6__content_notify_audit.sql` hardcoded
`CREATE FLASHBACK ARCHIVE glm_fda` — but FDA names are unique per PDB, not
per-schema, so `glm_app_dev` running the same migration would collide with prod's
archive. Fixed by parameterizing the name via a Flyway placeholder
(`flashback-archive-name`): `glm_fda` for prod, `glm_fda_dev` for dev — set in
`application.yml` / `application-dev.yml` respectively.

Verified afterward: `mvn verify -Dtest=MigrationIT` passes against `glm_app_dev`,
and prod's `glm_app` (44 tables) and `GLM_FDA` were confirmed untouched.

**Why a separate `glm_dev` account instead of reusing `glm_app` or `sys`:**
- **Attribution** — `glm_app` covers both app traffic and human edits
  indistinguishably; a personal login makes interactive changes traceable
  against the audit log / Flashback Archive already in place on this schema.
- **Independent credential lifecycle** — rotating the app's DB password
  doesn't break your GUI client session, and vice versa.
- **Blast radius** — day-to-day browsing doesn't need `sys`'s full-instance
  DBA power; `glm_dev` only has grants on `GLM_APP`'s own tables.

`glm_dev` was granted `SELECT, INSERT, UPDATE, DELETE` on all 43 `GLM_APP`
tables (Flyway's own `flyway_schema_history` ledger excluded — not needed
for app data work) plus `SELECT_CATALOG_ROLE` for dictionary views. New
tables added by future Flyway migrations need the same grant re-run; there's
no native "auto-grant on future objects" short of Database Vault.

## Schema health (verified 2026-07-14)

- **Flashback Data Archive** `GLM_FDA` (2555-day retention) already tracks
  `PAYMENTS`, `ORDERS`, `PAYOUTS` — done, no action needed.
- **Oracle Text indexes** `PRODUCTS_SEARCH_CTX` / `ARTICLES_SEARCH_CTX` —
  both `VALID` — done, no action needed.
- **Storage** — 0.01 GB used of 6.69 GB tablespace, well under Oracle Free's
  12 GB cap — healthy.
- **Open gap:** `oracle-provision.sql`'s planned audit-log lockdown
  (`REVOKE UPDATE, DELETE ON glm_app.audit_logs FROM glm_app`) doesn't
  actually work — Oracle schema owners always retain full DML on their own
  objects regardless of explicit revokes. `audit_logs` is not yet genuinely
  append-only. Real fix is a `BEFORE UPDATE OR DELETE` trigger that
  unconditionally rejects, or Oracle 23ai's native immutable/blockchain
  table feature — not yet implemented.

## 2026-07-17: glm_app_dev locked, then found to have a stale password

Starting the backend (`mvn spring-boot:run -Dspring-boot.run.profiles=dev`) failed with
`ORA-01017`. Diagnosis via sysdba (`ALTER SESSION SET CONTAINER = FREEPDB1;` then
`dba_users`/`dba_profiles` — the CDB-root connection can't see PDB-local users, see
"Connecting" above) found two separate issues, in order:

1. **`GLM_APP_DEV` was `LOCKED(TIMED)`** — the `DEFAULT` profile's
   `FAILED_LOGIN_ATTEMPTS = 10` had been exceeded at some point before this session.
   Fixed with `ALTER USER GLM_APP_DEV ACCOUNT UNLOCK;`.
2. **After unlocking, the documented password (`GlmAppDev_Ora26Q1`) still failed** —
   confirmed independently of the Windows/JDBC client by running `sqlplus
   glm_app_dev/GlmAppDev_Ora26Q1@//localhost:1521/FREEPDB1` directly on `linux-oracle-db`,
   which also got `ORA-01017`. So the account's actual password no longer matched what was
   recorded here — cause unknown (no rotation is documented for this account, unlike
   `glm_app`'s prod reset on 2026-07-14). Fixed by resetting it: `ALTER USER GLM_APP_DEV
   IDENTIFIED BY GlmAppDev_Ora26Q3 ACCOUNT UNLOCK;`, verified with the same direct-sqlplus
   login check, then updated `backend/.env` to match.
