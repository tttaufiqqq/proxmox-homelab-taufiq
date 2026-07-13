# Taufiq's Homelab — Documentation Hub

A personal Proxmox-based homelab used for hands-on database administration and
infrastructure learning. Six machines, five different database engines,
connected over a Tailscale mesh with a self-hosted DNS layer (`taufiq.lab`).

Each topic below is documented in the order it was actually built, as a
running log of what was done, what broke, and how it was fixed — not a
sanitized tutorial.

---

## Environment Inventory

### Proxmox Host

| Component | Value |
|---|---|
| Hostname | taufiq |
| OS | Proxmox VE |
| Local IP | 192.168.0.10 |
| Tailscale IP | 100.97.8.93 |

### Virtual Machines

| VM ID | Name | OS | Local IP | Tailscale IP | Engine |
|---|---|---|---|---|---|
| 101 | app-server | Ubuntu 24.04 | 192.168.0.102 | 100.100.123.90 | — |
| 102 | linux-sql-server | Ubuntu 22.04 | 192.168.0.104 | 100.117.38.113 | SQL Server 2022 |
| 104 | linux-mysql | Ubuntu 24.04 | 192.168.0.103 | 100.115.237.93 | MySQL 8.0 |
| 105 | linux-mariadb | Ubuntu 24.04 | 192.168.0.105 | 100.78.124.25 | MariaDB 10.11 |
| 106 | linux-postgres | Ubuntu 24.04 | 192.168.0.107 | 100.113.234.24 | PostgreSQL 16 |
| 107 | linux-oracle-db | Oracle Linux 8.10 | 192.168.0.106 | 100.118.110.114 | Oracle 23ai Free |

Full inventory, client machines, and DNS naming conventions:
[`docs/02-dns/dns-setup.md`](docs/02-dns/dns-setup.md#1-lab-environment-overview).

---

## Documentation, in Build Order

| # | Doc | Covers |
|---|---|---|
| 01 | [`docs/01-oracle/oracle-install.md`](docs/01-oracle/oracle-install.md) | Installing Oracle Database 23ai Free on a Proxmox VM (Oracle Linux 8), full troubleshooting log |
| 02 | [`docs/02-dns/dns-setup.md`](docs/02-dns/dns-setup.md) | Self-hosted DNS for the lab — dnsmasq + Tailscale Split DNS, SSH config automation |
| 03 | [`docs/03-dbeaver/dbeaver-connectivity.md`](docs/03-dbeaver/dbeaver-connectivity.md) | Connecting DBeaver to all five database engines over Tailscale + DNS |
| 04 | [`docs/04-spring-boot/spring-boot-setup.md`](docs/04-spring-boot/spring-boot-setup.md) | Spring Boot app server (dev/prod) backed by Oracle, with Cloudflare Tunnel for public access |

---

## Disclaimer

This is a personal homelab learning project, not a production deployment
guide. Passwords and credentials referenced in these docs are lab-only —
never reused elsewhere and never intended for shared or production
environments.
