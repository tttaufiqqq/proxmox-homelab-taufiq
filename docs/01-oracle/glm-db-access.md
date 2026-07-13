# GLM Project — Database Access & DBA Notes

Quick-reference for connecting to and administering the `GLM_APP` schema
(Green Lifestyle Market backend, `FREEPDB1` on `linux-oracle-db`). Full
Oracle connectivity background lives in
[`docs/03-dbeaver/dbeaver-connectivity.md`](../03-dbeaver/dbeaver-connectivity.md) —
this doc only covers what's specific to this one project.

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

| User | Role | Password | Use |
|---|---|---|---|
| `glm_app` | Schema owner | rotated, not recorded here | App runtime only (Spring Boot's `DB_USER`/`DB_PASSWORD`) |
| `glm_dev` | Interactive/DBA | `GlmDev_Ora26Q3` | Personal DBeaver login for browsing/admin work — added 2026-07-14 |

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
