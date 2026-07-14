# GLM Project — Database Access & DBA Notes

Quick-reference for connecting to and administering the `GLM_APP` schema
(Green Lifestyle Market backend, `FREEPDB1` on `linux-oracle-db`). Full
Oracle connectivity background lives in
[`docs/03-dbeaver/dbeaver-connectivity.md`](../03-dbeaver/dbeaver-connectivity.md) —
this doc only covers what's specific to this one project. For how GLM is hosted,
see [`docs/04-spring-boot/spring-boot-setup.md`](../04-spring-boot/spring-boot-setup.md).

> **Scope note:** GLM is a learning project with no real users — "prod" below just
> means "the schema the deployed copy uses," kept separate from "dev" for DBA practice
> (isolation, blast radius, credential hygiene), not because a real outage is at stake.

## Connecting in DBeaver

The existing homelab connection points at service **`FREE`** (the CDB root)
as `sys`. That can't see `GLM_APP` — in Oracle's multitenant architecture,
the CDB root and the `FREEPDB1` pluggable database are separate containers,
not just a filter. To browse this project's data:

1. New connection (or edit existing): **Service Name = `FREEPDB1`**, not `FREE`.
2. Connection settings → Oracle tab → enable **"Show all schemas"**
   (DBeaver defaults to showing only the connected user's own schema).
3. Navigate: `Database Navigator → connection → Schemas → GLM_APP → Tables`.

## Accounts

All Oracle credentials for this DB (`linux-oracle-db`, `FREEPDB1`), instance-wide and
GLM-specific. No `@` in Oracle passwords — see
[`docs/03-dbeaver/dbeaver-connectivity.md`](../03-dbeaver/dbeaver-connectivity.md#6-oracle-database-23ai-free-linux-oracle-db).

| User | Role | Password | Use |
|---|---|---|---|
| `sys` | Instance superuser (SYSDBA) | `qwertY1612` | Full-instance admin, `FREE` (CDB root) |
| `system` | DBA account | `qwertY1612` | Same as `sys`, admin on `FREE` |
| `glm_app` | **Prod** schema owner | `GlmApp_Ora26Q1Prod` — reset 2026-07-14 (previous value unknown/lost to rotation) | Deployed app only (`spring-boot-app` VM, port 8081) — 44 real tables, has `GLM_FDA` |
| `glm_app_dev` | **Dev** schema owner | `GlmAppDev_Ora26Q1` | Local dev/IT tests only, from the workstation — has `GLM_FDA_DEV` |
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
  doesn't break your DBeaver session, and vice versa.
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
