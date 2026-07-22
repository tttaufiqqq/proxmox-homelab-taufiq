# Library Management System — Downstream Client Project

**Repo:** [`tttaufiqqq/Library-System-EDP`](https://github.com/tttaufiqqq/Library-System-EDP)
**Type:** Windows desktop app (.NET Framework 4.7.2, WinForms, C#), distributed as a
per-user installer — not a service hosted on any VM/CT in this homelab.

> **Scope note:** unlike [`green-lifestyle-market`](../04-spring-boot/spring-boot-setup.md),
> which runs *on* a homelab VM (`spring-boot-app`), this project runs on end users'
> Windows machines and only reaches *into* the homelab over the network for its database
> and object storage. This doc exists to record that dependency from the infrastructure
> side — the app-side details (architecture, features, build/run instructions) live in
> the project's own [`README.md`](https://github.com/tttaufiqqq/Library-System-EDP/blob/main/README.md).

## Why This Doc Exists

This homelab hosts two pieces of shared infrastructure that a second, independent
project now depends on. When infra here changes (credentials rotated, a VM moved,
firewall rules tightened), this doc is the pointer that says "check whether the
Library Management System still works" — the same reason
[`docs/01-oracle/glm-db-access.md`](../01-oracle/glm-db-access.md) exists for GLM.

## What It Uses From This Homelab

| Service | VM | Purpose |
|---|---|---|
| SQL Server 2022 | `linux-sql-server` (VM 102, `linux-sql-server.taufiq.lab`) | Backend for the `Library` database (`Users`, `Books`, `IssuesBooks` tables), accessed via LINQ-to-SQL over `System.Data.SqlClient` |
| MinIO | `linux-mini-io` (VM 109, see [`docs/05-minio/minio-setup.md`](../05-minio/minio-setup.md)) | Object storage for book cover images, via the official `Minio` .NET SDK (pinned to `6.0.4` — later versions have a known `PutObjectAsync` bug on .NET Framework) |

Both are shared, multi-tenant instances, not infrastructure stood up specifically for
this project:

- The SQL Server host previously also served `booking` and `workshop_2` databases for
  Animal-Shelter-Workshop — stale as of 2026-07-20: `booking` was rewritten off SQL
  Server onto MariaDB entirely (see `Animal-Shelter-Workshop/docs/01-architecture-migration.md`),
  and that project no longer uses this host at all. Whether the old `booking`/`workshop_2`
  schemas still physically exist on this SQL Server instance as unused leftovers wasn't
  checked as part of that other work — not verified either way here. Library Management
  System connects through a login (`library_app`) scoped to `db_datareader`/`db_datawriter`
  on the `Library` database only — it cannot see or touch whatever else is on that instance.
- The MinIO instance also serves GLM's `glm-product-images` bucket (see the
  [2026-07-17 GLM entry](../05-minio/minio-setup.md#2026-07-17--glm-project-bucket)
  in the MinIO doc). Library Management System has its own bucket
  (`library-book-covers`) and its own least-privilege access key
  (`libraryapp-9bf57f53a1bf`, scoped to `GetObject`/`PutObject`/`DeleteObject`/
  `ListBucket` on that one bucket only) — verified it cannot list or read
  `glm-product-images`.

Real connection strings and access keys live only in that project's gitignored
`App.config.local`, never in its public repo or in this one.

## Tech Stack

- **Framework:** .NET Framework 4.7.2
- **Language:** C#
- **UI:** Windows Forms
- **ORM:** LINQ to SQL
- **Database:** SQL Server 2022 (self-hosted, this homelab)
- **Object storage:** MinIO (self-hosted, this homelab), `Minio` NuGet 6.0.4
- **Installer:** Inno Setup 6, per-user install (no admin/UAC prompt)
- **Auth:** PBKDF2 (SHA-256, 100k iterations) password hashing

## Reachability

The Windows client machines running this app are not on this homelab's Tailscale
tailnet — deliberately, to avoid exposing every other homelab host/service to a
wider set of people than necessary. The original plan for reaching a small set of
non-tailnet recipients (Cloudflare Tunnel + Cloudflare Access, gating direct access
to `linux-sql-server:1433` by allow-listed email) has been **superseded** — see the
2026-07-22 entry below. Current plan: an API layer in front of SQL Server/MinIO,
fronted by the same Cloudflare Tunnel + Access pattern, instead of exposing the raw
database port. Not yet implemented; tracked in `edp-library`'s own repo.

## 2026-07-22 — Reachability plan changed: API layer instead of direct DB/MinIO exposure

Evaluated two options for letting friends' Windows machines (running the distributed
`.exe`) reach `linux-sql-server:1433` and MinIO directly: **Twingate** and
**Cloudflare Access in TCP mode** (`cloudflared access tcp`). Both work, but both
require installing and running a client-side tool on every friend's laptop before
the app will connect — a Twingate client sign-in, or a `cloudflared access tcp`
command kept running as a local proxy. Neither gets to "just install the `.exe` and
run it," which was the actual bar for a small, non-technical friend group.

Decided instead to add a thin API layer (ASP.NET Core) hosted in this homelab, in
front of SQL Server and MinIO, and expose *that* over the same Cloudflare Tunnel +
Cloudflare Access pattern already proven out for Animal-Shelter-Workshop (see
[`docs/10-cloudflare-tunnel/cloudflare-tunnel-setup.md`](../10-cloudflare-tunnel/cloudflare-tunnel-setup.md)).
The WinForms client calls the API over HTTPS instead of opening a direct SQL Server
connection or using the MinIO SDK against the homelab.

Two reasons this won over the client-based options:

1. **Zero setup for friends.** They only ever install the `.exe` — no VPN/zero-trust
   client, no CLI command to remember to run first. Plain HTTPS from the client's
   perspective, same shape as any other cloud app.
2. **Better security posture, not just less friction.** Today the SQL Server
   connection string and MinIO access key live inside the distributed client, which
   means every recipient's laptop holds real database/object-storage credentials.
   With an API in between, those credentials never leave the homelab — the client
   only ever holds an API-issued token scoped to whatever the API chooses to expose.

This does **not** remove LINQ-to-SQL from the project — it relocates. The existing
LINQ-to-SQL data-access code moves from the WinForms client into the new API
project unchanged; the client swaps its direct `SqlClient`/`Minio` SDK calls for
HTTP calls to the API instead.

**Not yet implemented.** The API design, hosting choice, auth scheme, and the
WinForms-side rewrite all live in `edp-library`'s own repo — matching this doc's
existing scope note that app-side work is tracked there, not here.

> **Reminder for the next Claude Code session working in `edp-library`:** before
> starting the API/client rewrite, read this entry (and the linked Cloudflare
> Tunnel doc) for why this architecture was chosen over Twingate/direct DB exposure,
> and update this doc once the API is actually live so the "Reachability" status
> above stops saying "not yet implemented."

## Related Docs

- [`docs/05-minio/minio-setup.md`](../05-minio/minio-setup.md) — the MinIO instance this project stores book covers in
- [`docs/01-oracle/glm-db-access.md`](../01-oracle/glm-db-access.md) — the equivalent doc for GLM, this homelab's other downstream project
