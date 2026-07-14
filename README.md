# Taufiq's Homelab

Five database engines. Six machines. One guy, one Proxmox box, and a lot of
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
| Database administration | Installing, securing, and troubleshooting Oracle, MySQL, MariaDB, PostgreSQL, and SQL Server, each with its own quirks (Oracle's illegal `@` in passwords, MySQL's bind address defaults, Postgres's `pg_hba.conf`) |
| Linux systems administration | User and permission management, systemd services, firewalld and UFW, log rotation, service persistence across reboots |
| Virtualization | Provisioning and hardening VMs on Proxmox VE, including a real CPU compatibility failure (glibc requiring a microarchitecture the VM's CPU type didn't support) |
| Networking | Designing a Tailscale mesh VPN across six machines, then building a self-hosted DNS layer (dnsmasq) with split horizon resolution on top of it |
| Application integration | A Spring Boot service talking to Oracle over JDBC, with separate dev and prod environments and a permanent Cloudflare Tunnel for public access |
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
| RAM | 7.65 GiB |
| Storage | 225.19 GiB |
| Kernel | Linux 6.17.2-1-pve |
| Local IP | 192.168.0.10 |
| Tailscale IP | 100.97.8.93 |

### Virtual Machines

| VM ID | Name | OS | Local IP | Tailscale IP | Engine |
|---|---|---|---|---|---|
| 101 | app-server | Ubuntu 24.04 | 192.168.0.102 | 100.100.123.90 | Hosts [`Animal-Shelter-Workshop`](https://github.com/tttaufiqqq/Animal-Shelter-Workshop) (sole purpose — corrected 2026-07-14, previously mislabeled "general purpose"; offline when not in use) |
| 102 | linux-sql-server | Ubuntu 22.04 | 192.168.0.104 | 100.117.38.113 | SQL Server 2022 |
| 104 | linux-mysql | Ubuntu 24.04 | 192.168.0.103 | 100.115.237.93 | MySQL 8.0 |
| 105 | linux-mariadb | Ubuntu 24.04 | 192.168.0.105 | 100.78.124.25 | MariaDB 10.11 |
| 106 | linux-postgres | Ubuntu 24.04 | 192.168.0.107 | 100.113.234.24 | PostgreSQL 16 |
| 107 | linux-oracle-db | Oracle Linux 8.10 | 192.168.0.106 | 100.118.110.114 | Oracle 23ai Free |
| 103 | spring-boot-app | Ubuntu 24.04.4 | 192.168.0.105 (DHCP, drifts) | 100.120.243.96 | Hosts [`green-lifestyle-market`](https://github.com/tttaufiqqq/green-lifestyle-market) ("prod"), Nginx — added to inventory 2026-07-14, was missing here despite being a separate node from `app-server` |

Note: `spring-boot-app`'s Local IP is DHCP-assigned and has been observed reusing an
address also leased to `linux-mariadb` while that VM was off — always use the
Tailscale IP for this node.

Full inventory, client machines, and DNS naming conventions live in
[`docs/02-dns/dns-setup.md`](docs/02-dns/dns-setup.md#1-lab-environment-overview).

---

## Documentation, in Build Order

A quick note on scope before you read these. The MariaDB, MySQL, PostgreSQL,
and SQL Server VMs already existed before this repo started, each one
dedicated to a single engine, powered on when I need it and off otherwise
(the Proxmox host only has 4 cores and 7.65 GiB of RAM, so idle VMs stay
off). Oracle is the only engine that gets a full install log here because
it was by far the hardest of the five to get working. The others went
smoothly enough that there was nothing worth writing up.

| # | Doc | Covers |
|---|---|---|
| 01 | [`docs/01-oracle/oracle-install.md`](docs/01-oracle/oracle-install.md) | Installing Oracle Database 23ai Free on a Proxmox VM (Oracle Linux 8), full troubleshooting log |
| 02 | [`docs/02-dns/dns-setup.md`](docs/02-dns/dns-setup.md) | Self-hosted DNS for the lab: dnsmasq plus Tailscale Split DNS, SSH config automation |
| 03 | [`docs/03-dbeaver/dbeaver-connectivity.md`](docs/03-dbeaver/dbeaver-connectivity.md) | Using DBeaver as one place to manage all five engines: connects over either the DNS hostname or the raw Tailscale IP, and makes it easy to jump between databases as VMs get powered on and off |
| 04 | [`docs/04-spring-boot/spring-boot-setup.md`](docs/04-spring-boot/spring-boot-setup.md) | Spring Boot app server, sole live host for [`green-lifestyle-market`](https://github.com/tttaufiqqq/green-lifestyle-market) (a learning project with no real users), a rewrite of an old PHP plus MySQL project into Spring Boot plus Oracle |
| 05 | [`docs/01-oracle/glm-db-access.md`](docs/01-oracle/glm-db-access.md) | Green Lifestyle Market's database side: the DBeaver connection fix from doc 03 (PDB vs CDB), the schema isolation set up alongside doc 04's deployment, the `glm_dev` DBA account, and current schema health |

---

## Disclaimer

This is a personal homelab learning project, not a production deployment
guide. Passwords and credentials referenced in these docs are lab only,
never reused elsewhere and never intended for shared or production
environments.
