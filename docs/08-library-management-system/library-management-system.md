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

- The SQL Server host also serves `booking` and `workshop_2` databases for other,
  unrelated projects. Library Management System connects through a login (`library_app`)
  scoped to `db_datareader`/`db_datawriter` on the `Library` database only — it cannot
  see or touch the other databases on that instance.
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
wider set of people than necessary. Remote reachability for a small set of
non-tailnet recipients (Cloudflare Tunnel + Cloudflare Access, gating access to
`linux-sql-server:1433` by allow-listed email) is a planned, not-yet-implemented
piece of that project's own infrastructure work, tracked in its own repo rather than
here.

## Related Docs

- [`docs/05-minio/minio-setup.md`](../05-minio/minio-setup.md) — the MinIO instance this project stores book covers in
- [`docs/01-oracle/glm-db-access.md`](../01-oracle/glm-db-access.md) — the equivalent doc for GLM, this homelab's other downstream project
