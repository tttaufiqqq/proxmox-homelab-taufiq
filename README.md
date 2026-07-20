# Taufiq's Homelab

Six database engines. Thirteen machines. One guy, one Proxmox box, and a lot of
3am troubleshooting.

This repo is the running log of a personal homelab built to get real,
hands on DBA and infrastructure experience, the kind you normally only get
on the job. Every doc here was written while the problem was still open,
not cleaned up afterward. That means you'll find the wrong turns next to
the fixes: the typo'd package name, the silently truncated password, the
listener that looked broken but was actually a missing config file three
layers deep. If you want to see how someone actually thinks through
infrastructure problems, this is closer to the truth than a polished
tutorial would be.

---

## What This Demonstrates

| Area | What's in here |
|---|---|
| Database administration | Installing, securing, and troubleshooting Oracle, MySQL, MariaDB, PostgreSQL, SQL Server, and MongoDB, each with its own quirks (Oracle's illegal `@` in passwords, MySQL's bind address defaults, Postgres's `pg_hba.conf`, MongoDB's `bindIp` refusing to start on an unreachable address) |
| Linux systems administration | User and permission management, systemd services, firewalld and UFW, log rotation, service persistence across reboots |
| Virtualization | Provisioning and hardening both VMs and LXC containers on Proxmox VE, and choosing between them deliberately (a real CPU compatibility failure — glibc requiring a microarchitecture the VM's CPU type didn't support — alongside a CT-vs-VM tradeoff call for lightweight network/API services) |
| Networking | Designing a Tailscale mesh VPN across the lab, then building a self-hosted DNS layer (dnsmasq) with split horizon resolution on top of it |
| Application integration | A Spring Boot service talking to Oracle over JDBC, with separate dev and prod environments and a permanent Cloudflare Tunnel for public access |
| Infrastructure services | Self-hosted S3-compatible object storage (MinIO) and a centralized secrets manager (HashiCorp Vault) backing the rest of the lab, instead of credentials living in `.env` files or docs |
| Troubleshooting discipline | Every doc includes root cause, not just the fix. Symptom, diagnosis, resolution, in that order, every time |
| Technical writing | Long form documentation that another engineer (or future me) could actually follow and rebuild from |

---

## Environment Inventory

### Proxmox Host

| Component | Value |
|---|---|
| Hostname | taufiq |
| OS | Proxmox VE 9.1.1 |
| CPU | Intel Core i5-6600T @ 2.70GHz (4 cores) |
| RAM | 15.51 GiB (upgraded from 7.65 GiB, confirmed via SSH 2026-07-19) |
| Storage | 225.19 GiB |
| Kernel | Linux 6.17.2-1-pve |
| Local IP | 192.168.0.10 |
| Tailscale IP | 100.97.8.93 |

### Virtual Machines

| VM ID | Name | OS | Local IP | Tailscale IP | Engine |
|---|---|---|---|---|---|
| 101 | app-server | Ubuntu 24.04 | 192.168.0.102 | 100.100.123.90 | Hosts [`Animal-Shelter-Workshop`](https://github.com/tttaufiqqq/Animal-Shelter-Workshop) (sole purpose — corrected 2026-07-14, previously mislabeled "general purpose"; offline when not in use). Its distributed-DB setup — 5 named connections split across this VM, 104, 105, 106, and CTs 112/113 below — is documented from the app side in that repo's [`docs/03-db-architecture.md`](https://github.com/tttaufiqqq/Animal-Shelter-Workshop/blob/main/docs/03-db-architecture.md). Its CI runs on `linux-gh-runner` (CT 111 below), not a GitHub-hosted runner, since it needs to reach these Tailscale-only DB hosts — see [`docs/09-github-actions-runner/actions-runner-setup.md`](docs/09-github-actions-runner/actions-runner-setup.md). Public access is via Cloudflare Tunnel, not a forwarded port — `https://animal-shelter-workshop.tttaufiqqq.com`, see [`docs/10-cloudflare-tunnel/cloudflare-tunnel-setup.md`](docs/10-cloudflare-tunnel/cloudflare-tunnel-setup.md). Its deploy secrets (DB passwords, `APP_KEY`, Cloudinary/ToyyibPay/SMTP) come from a scoped Vault AppRole, not hardcoded `.env` values — see [`docs/11-vault-approle-app-integration/`](docs/11-vault-approle-app-integration/vault-approle-app-integration.md). |
| 102 | linux-sql-server | Ubuntu 22.04 | 192.168.0.104 | 100.117.38.113 | SQL Server 2022 — also backs [`Library-System-EDP`](https://github.com/tttaufiqqq/Library-System-EDP), a downstream Windows desktop project (see [`docs/08-library-management-system/`](docs/08-library-management-system/library-management-system.md)) |
| 104 | linux-mysql | Ubuntu 24.04 | 192.168.0.103 | 100.115.237.93 | MySQL 8.0 — also backs [`Animal-Shelter-Workshop`](https://github.com/tttaufiqqq/Animal-Shelter-Workshop)'s `shelter` connection (database `workshop_2`) — see [`docs/12-mysql-shelter-animals-split/`](docs/12-mysql-shelter-animals-split/mysql-shelter-animals-split.md) |
| 105 | linux-mariadb | Ubuntu 24.04 | 192.168.0.105 | 100.78.124.25 | MariaDB 10.11 — also backs [`Animal-Shelter-Workshop`](https://github.com/tttaufiqqq/Animal-Shelter-Workshop)'s `reporting` connection (database `workshop_2`) — `booking` split off onto CT 113 on 2026-07-20, see [`docs/13-mariadb-reporting-booking-split/`](docs/13-mariadb-reporting-booking-split/mariadb-reporting-booking-split.md) |
| 106 | linux-postgres | Ubuntu 24.04 | 192.168.0.107 | 100.113.234.24 | PostgreSQL 16 — also backs [`Animal-Shelter-Workshop`](https://github.com/tttaufiqqq/Animal-Shelter-Workshop)'s `users` connection (database `workshop_2`) |
| 107 | linux-oracle-db | Oracle Linux 8.10 | 192.168.0.106 | 100.118.110.114 | Oracle 23ai Free |
| 103 | spring-boot-app | Ubuntu 24.04.4 | 192.168.0.105 (DHCP, drifts) | 100.120.243.96 | Hosts [`green-lifestyle-market`](https://github.com/tttaufiqqq/green-lifestyle-market) ("prod"), Nginx — added to inventory 2026-07-14, was missing here despite being a separate node from `app-server` |
| 109 | linux-mini-io | Ubuntu 22.04.5 | 192.168.0.105 (static) | 100.73.172.85 | MinIO (S3-compatible object storage) — added 2026-07-15, also stores book cover images for [`Library-System-EDP`](https://github.com/tttaufiqqq/Library-System-EDP) |

Note: `spring-boot-app`'s Local IP is DHCP-assigned and has been observed reusing an
address also leased to `linux-mariadb` while that VM was off — always use the
Tailscale IP for this node. `linux-mini-io`'s static IP (`192.168.0.105`) has since
been observed matching that same reused address on paper; they don't run at the same
time in practice, but the Tailscale IP is the reliable way to reach either.

### Containers (LXC)

| CT ID | Name | OS | Local IP | Tailscale IP | Purpose |
|---|---|---|---|---|---|
| 108 | linux-mongodb | Ubuntu 24.04 (unprivileged) | 192.168.0.108 | 100.82.200.94 | First NoSQL engine in the lab (document store) — added 2026-07-14, joined tailnet 2026-07-17 |
| 110 | linux-vault | Ubuntu 24.04 (unprivileged) | 192.168.0.110 | 100.112.41.113 | HashiCorp Vault, centralized secrets manager for every VM/CT in the lab — added 2026-07-16 |
| 111 | linux-gh-runner | Ubuntu 24.04 (unprivileged) | 192.168.0.111 | 100.72.6.40 | Self-hosted GitHub Actions runner for [`Animal-Shelter-Workshop`](https://github.com/tttaufiqqq/Animal-Shelter-Workshop) CI — added 2026-07-19, reads DB creds from `linux-vault` via a scoped read-only token (not the root token) |
| 112 | linux-mysql-2 | Ubuntu 24.04 (unprivileged) | 192.168.0.112 | 100.123.221.89 | MySQL 8.0 — backs [`Animal-Shelter-Workshop`](https://github.com/tttaufiqqq/Animal-Shelter-Workshop)'s `animals` connection (database `workshop_2`) — added 2026-07-20 as a CT rather than a VM (same persistent-workload reasoning as `linux-mongodb`/`linux-vault`), see [`docs/12-mysql-shelter-animals-split/`](docs/12-mysql-shelter-animals-split/mysql-shelter-animals-split.md) |
| 113 | linux-mariadb-2 | Ubuntu 24.04 (unprivileged) | 192.168.0.113 | 100.97.35.29 | MariaDB 10.11 — backs [`Animal-Shelter-Workshop`](https://github.com/tttaufiqqq/Animal-Shelter-Workshop)'s `booking` connection (database `workshop_2`) — added 2026-07-20, same day as CT 112, same CT-over-VM reasoning — see [`docs/13-mariadb-reporting-booking-split/`](docs/13-mariadb-reporting-booking-split/mariadb-reporting-booking-split.md) |

Containers are used instead of VMs where a workload is a pure network/API service
with no need for a separate kernel — see the CT vs VM decision in
[`docs/07-vault/vault-setup.md`](docs/07-vault/vault-setup.md#ct-vs-vm-decision).

Full inventory, client machines, and DNS naming conventions live in
[`docs/02-dns/dns-setup.md`](docs/02-dns/dns-setup.md#1-lab-environment-overview).

---

## Documentation, in Build Order

A quick note on scope before you read these. The MariaDB, MySQL, PostgreSQL,
and SQL Server VMs already existed before this repo started, each one
dedicated to a single engine, powered on when I need it and off otherwise
(the Proxmox host only has 4 cores, and had 7.65 GiB of RAM until a
2026-07-19 upgrade to 15.51 GiB, so idle VMs stay off). Oracle is the
only engine that gets a full install log here because it was by far the
hardest of the five to get working. The others went
smoothly enough that there was nothing worth writing up. MinIO, MongoDB,
and Vault are newer additions built from scratch inside this repo's
timeline, so each gets a full doc regardless of how smoothly it went.

| # | Doc | Covers |
|---|---|---|
| 01 | [`docs/01-oracle/oracle-install.md`](docs/01-oracle/oracle-install.md) | Installing Oracle Database 23ai Free on a Proxmox VM (Oracle Linux 8), full troubleshooting log |
| 02 | [`docs/02-dns/dns-setup.md`](docs/02-dns/dns-setup.md) | Self-hosted DNS for the lab: dnsmasq plus Tailscale Split DNS, SSH config automation |
| 03 | [`docs/03-datagrip/datagrip-connectivity.md`](docs/03-datagrip/datagrip-connectivity.md) | Using DataGrip as one place to manage all six engines (DBeaver's original setup, retired 2026-07-15): connects over either the DNS hostname or the raw Tailscale IP, and makes it easy to jump between databases as VMs get powered on and off |
| 04 | [`docs/04-spring-boot/spring-boot-setup.md`](docs/04-spring-boot/spring-boot-setup.md) | Spring Boot app server, sole live host for [`green-lifestyle-market`](https://github.com/tttaufiqqq/green-lifestyle-market) (a learning project with no real users), a rewrite of an old PHP plus MySQL project into Spring Boot plus Oracle |
| 05 | [`docs/01-oracle/glm-db-access.md`](docs/01-oracle/glm-db-access.md) | Green Lifestyle Market's database side: the connection fix from doc 03 (PDB vs CDB), the schema isolation set up alongside doc 04's deployment, the `glm_dev` DBA account, and current schema health |
| 06 | [`docs/05-minio/minio-setup.md`](docs/05-minio/minio-setup.md) | Self-hosted S3-compatible object storage on a dedicated VM (MinIO), two-disk layout (OS + data), systemd service, and hardening (UFW, fail2ban, unattended-upgrades) |
| 07 | [`docs/06-mongodb/mongodb-setup.md`](docs/06-mongodb/mongodb-setup.md) | First NoSQL engine in the lab, run as an LXC container rather than a VM to keep the resource footprint down; six real issues hit getting from "CT created" to "MongoDB actually running," including a Proxmox storage content-type gap and a `bindIp` failure caused by a Tailscale IP the CT didn't actually have |
| 08 | [`docs/07-vault/vault-setup.md`](docs/07-vault/vault-setup.md) | HashiCorp Vault as a centralized secrets manager for every VM and CT in the lab, replacing credentials scattered across `.env` files and docs; CT vs VM tradeoff, `mlock` and TUN-device issues specific to running Vault + Tailscale inside an LXC container |
| 09 | [`docs/08-library-management-system/library-management-system.md`](docs/08-library-management-system/library-management-system.md) | A second downstream project — [`Library-System-EDP`](https://github.com/tttaufiqqq/Library-System-EDP), a Windows desktop WinForms app — consuming this homelab's SQL Server VM and MinIO instance from outside the tailnet; what it uses and how its access is scoped |
| 10 | [`docs/09-github-actions-runner/actions-runner-setup.md`](docs/09-github-actions-runner/actions-runner-setup.md) | Self-hosted GitHub Actions runner for [`Animal-Shelter-Workshop`](https://github.com/tttaufiqqq/Animal-Shelter-Workshop), run as an LXC container on the tailnet instead of a GitHub-hosted runner so it can reach the app's private DB servers; scoped read-only Vault token (not the root token used everywhere else) so a workflow can only read the three DB secrets it needs |
| 11 | [`docs/10-cloudflare-tunnel/cloudflare-tunnel-setup.md`](docs/10-cloudflare-tunnel/cloudflare-tunnel-setup.md) | Public HTTPS for [`Animal-Shelter-Workshop`](https://github.com/tttaufiqqq/Animal-Shelter-Workshop) via Cloudflare Tunnel instead of the certbot/nginx approach that project's own docs originally planned — no router port-forwarding, no certificate renewal to manage; a deliberate simplicity trade-off since this project has no real users or data at stake |
| 12 | [`docs/11-vault-approle-app-integration/vault-approle-app-integration.md`](docs/11-vault-approle-app-integration/vault-approle-app-integration.md) | Moving [`Animal-Shelter-Workshop`](https://github.com/tttaufiqqq/Animal-Shelter-Workshop)'s `app-server` off hardcoded/hand-applied secrets and onto Vault — a scoped `asw-deploy` AppRole (not the root token, not even the runner's own static-token pattern) read by Ansible at deploy time via `community.hashi_vault` |
| 13 | [`docs/12-mysql-shelter-animals-split/mysql-shelter-animals-split.md`](docs/12-mysql-shelter-animals-split/mysql-shelter-animals-split.md) | Splitting [`Animal-Shelter-Workshop`](https://github.com/tttaufiqqq/Animal-Shelter-Workshop)'s `shelter`+`animals` MySQL connections off `msi` onto their own dedicated hosts (`linux-mysql` VM 104, and a new CT 112 `linux-mysql-2`) — the last connection pair that didn't yet have 1-database-1-physical-machine; a real backup-target-naming bug this surfaced and fixed |
| 14 | [`docs/13-mariadb-reporting-booking-split/mariadb-reporting-booking-split.md`](docs/13-mariadb-reporting-booking-split/mariadb-reporting-booking-split.md) | Same treatment, one pair over: splitting `reporting`+`booking` off `linux-mariadb` onto a new CT 113 `linux-mariadb-2` — every `Animal-Shelter-Workshop` connection now has its own dedicated physical host; also documents a live-table-drop mistake caught and fixed within a minute |
| 15 | [`docs/14-laravel-log-permission-denied/laravel-log-permission-denied.md`](docs/14-laravel-log-permission-denied/laravel-log-permission-denied.md) | `app-server`'s Laravel log file ended up owned by the wrong group after a manual `artisan` command ran outside the web server's user, taking booking confirmation and animal-matching down with cascading "permission denied" errors; root cause was a missing setgid bit on `storage/`, fixed on the host and made permanent in the deploy playbook |
| 16 | [`docs/15-app-server-backups-permission-denied/app-server-backups-permission-denied.md`](docs/15-app-server-backups-permission-denied/app-server-backups-permission-denied.md) | `/admin/backups` 500ing turned out to be two intentional decisions fighting each other — a deliberately locked-down `0700` backups directory vs. a documented admin feature that needs to read it — resolved by opening the tree to `www-data`, reasoned through against what that boundary actually protects given `www-data` already holds live DB credentials |

---

## Disclaimer

This is a personal homelab learning project, not a production deployment
guide. Passwords and credentials referenced in these docs are lab only,
never reused elsewhere and never intended for shared or production
environments.
