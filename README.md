# Oracle Database 23ai Free on Proxmox — Homelab Setup

A step-by-step, real-world documented install of Oracle Database 23ai Free on Oracle Linux 8, running as a Proxmox VM and secured over a Tailscale private mesh network. This is part of a larger multi-database homelab workshop (PostgreSQL, MariaDB, MySQL, SQL Server, Oracle) used for hands-on DBA and infrastructure learning.

This document is written as an honest troubleshooting log, not a sanitized tutorial. Every error encountered, its root cause, and the actual fix applied are documented in full, including the wrong turns, because that's usually the part tutorials skip and the part that's actually useful.

---

## Table of Contents

- [Environment Summary](#environment-summary)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Phase 0: VM Provisioning](#phase-0-vm-provisioning)
- [Phase 1: SSH Host Key Conflict](#phase-1-ssh-host-key-conflict)
- [Phase 2: Root Privilege Escalation](#phase-2-root-privilege-escalation)
- [Phase 3: Tailscale Installation](#phase-3-tailscale-installation)
- [Phase 4: Oracle Preinstall Package](#phase-4-oracle-preinstall-package)
- [Phase 5: Oracle 23ai Free Binary Install](#phase-5-oracle-23ai-free-binary-install)
- [Phase 6: Database Instance Configuration](#phase-6-database-instance-configuration)
- [Phase 7: Persistent Environment Variables](#phase-7-persistent-environment-variables)
- [Phase 8: Application User Creation](#phase-8-application-user-creation)
- [Phase 9: Listener Troubleshooting](#phase-9-listener-troubleshooting)
- [Phase 10: Firewall Hardening](#phase-10-firewall-hardening)
- [Phase 11: Service Persistence](#phase-11-service-persistence)
- [Phase 12: Verification via DBeaver](#phase-12-verification-via-dbeaver)
- [Troubleshooting Reference Table](#troubleshooting-reference-table)
- [Key Lessons Learned](#key-lessons-learned)
- [Why This Setup](#why-this-setup)
- [Future Work](#future-work)
- [Disclaimer](#disclaimer)

---

## Environment Summary

| Component | Detail |
|---|---|
| Hypervisor | Proxmox VE |
| VM ID | 107 |
| Hostname | `linux-oracle-db` |
| Guest OS | Oracle Linux 8.8 (`OracleLinux-R8-U8-x86_64-dvd.iso`) |
| vCPU | 2 cores (1 socket, 2 cores), CPU type `host` |
| RAM | 4 GiB |
| Disk | 70 GiB, qcow2, manual LVM partitioning |
| BIOS | OVMF (UEFI) |
| Machine type | q35 |
| Network | virtio, bridged via `vmbr0` + Tailscale overlay |
| DBMS | Oracle Database 23ai Free (`23.7.0.25.01`) |
| DB identifiers | CDB: `FREE` · PDB: `FREEPDB1` |
| Remote access | Tailscale mesh only (LAN/public access disabled) |
| DB client | DBeaver Community |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Proxmox Host (taufiq)                    │
│                                                                │
│   ┌──────────────────────────────────────────────────────┐   │
│   │           VM 107 — linux-oracle-db (OL 8.8)           │   │
│   │                                                        │   │
│   │   /            (20 GiB, LVM, xfs)                     │   │
│   │   /u01         (15 GiB, LVM, xfs) — reserved for       │   │
│   │                 Oracle binaries (unused, install       │   │
│   │                 defaulted to /opt/oracle)               │   │
│   │   /u02         (29 GiB, LVM, xfs) — reserved for        │   │
│   │                 datafiles (unused, same reason)        │   │
│   │   swap         (4 GiB)                                 │   │
│   │                                                        │   │
│   │   Oracle Database 23ai Free                            │   │
│   │     ├── CDB: FREE                                      │   │
│   │     └── PDB: FREEPDB1                                  │   │
│   │           └── laravel_app (application user)           │   │
│   │                                                        │   │
│   │   Listener: 0.0.0.0:1521 (bound to all interfaces,     │   │
│   │              but firewall only trusts tailscale0)      │   │
│   └──────────────────────────────────────────────────────┘   │
│                              │                                 │
└──────────────────────────────┼─────────────────────────────────┘
                                │
                        tailscale0 (100.118.110.114)
                                │
                    ┌───────────┴────────────┐
                    │   Tailscale Mesh (WAN)  │
                    └───────────┬────────────┘
                                │
                      ┌─────────┴─────────┐
                      │  Windows Client    │
                      │  DBeaver Community │
                      └────────────────────┘
```

**Security model:** the Oracle listener binds to `0.0.0.0:1521` at the application layer, but `firewalld` only trusts the `tailscale0` interface. This means the database is unreachable from the local LAN or the public internet, only devices authenticated on the Tailscale tailnet can connect.

---

## Prerequisites

- Proxmox VE host with sufficient resources (4 GiB RAM / 70 GiB disk minimum for this VM)
- Oracle Linux 8.x installation ISO ([yum.oracle.com/oracle-linux-isos.html](https://yum.oracle.com/oracle-linux-isos.html))
- A Tailscale account and tailnet already set up on other homelab nodes
- DBeaver Community (or any Oracle-thin-driver-compatible SQL client) on the client machine
- Basic familiarity with `dnf`, `systemctl`, `firewalld`, and LVM

---

## Phase 0: VM Provisioning

### 0.1 — Failed first attempt: Oracle Linux 10

The VM was initially built on **Oracle Linux 10**, since it was the newest available release. This produced two consecutive boot-level failures before it was determined that Oracle Database 23ai Free does not officially support OL10 at all.

**Kernel panic on boot (SeaBIOS + CPU type `x86-64-v2-AES`):**
```text
[    5.256326] ---[ end Kernel panic - not syncing: Attempted to kill init! exit code=0x00007f00 ]---
```

Attempted fix: switched BIOS from SeaBIOS to **OVMF (UEFI)**.

**New failure after UEFI switch:**
```text
Fatal glibc error: CPU does not support x86-64-v3
```

**Root cause:** Oracle Linux 10's glibc build requires the `x86-64-v3` microarchitecture baseline (AVX2, BMI2, FMA). The VM's CPU type was set to `x86-64-v2-AES`, one level below what OL10's userland requires.

**Resolution attempted:** changed Proxmox CPU type to `host` (Hardware → Processors → Edit), which passes through the full physical CPU feature set. This resolved the glibc error, but a subsequent check confirmed **Oracle 23ai Free is only officially supported on Oracle Linux 8 and 9** — so the VM was rebuilt from scratch on OL8 instead of proceeding further on OL10.

### 0.2 — Final install: Oracle Linux 8.8

Reinstalled using `OracleLinux-R8-U8-x86_64-dvd.iso`.

**VM hardware configuration:**
- BIOS: OVMF (UEFI), with EFI disk added
- Format: `qcow2` (thin provisioning, snapshot support)
- Graphic card: `Default` (standard VGA via Proxmox noVNC console)
- CPU type: `host`

### 0.3 — Manual disk partitioning (OFA-style layout)

Rather than accepting Anaconda's automatic partitioning, a manual layout was used on the 70 GiB disk, modeled after Oracle Flexible Architecture (OFA) conventions commonly used in production Oracle deployments:

| Mount point | Size | Device type | Filesystem | Purpose |
|---|---|---|---|---|
| `/boot/efi` | ~699 MiB | Standard | EFI System Partition | UEFI boot files |
| `/boot` | 1024 MiB | Standard | xfs | Kernel/initramfs (kept outside LVM intentionally) |
| swap | 4 GiB | LVM | swap | Matches VM RAM |
| `/` (`ol-root`) | 20 GiB | LVM | xfs | Base OS |
| `/u01` | 15 GiB | LVM | xfs | Reserved for Oracle software binaries |
| `/u02` | ~29 GiB | LVM | xfs | Reserved for datafiles/redo logs/FRA |

All LVM volumes share a single volume group (`ol`) with 0 B free, fully allocated.

> **Note:** the RPM-based 23ai Free installer defaults to `/opt/oracle` regardless of this partitioning. `/u01` and `/u02` are currently unused. See [Future Work](#future-work) for a planned fix.

### 0.4 — Software selection

Base environment: **Server** (headless, no GUI). Chosen over "Server with GUI" to avoid unnecessary desktop-environment overhead on a database VM managed entirely via SSH.

---

## Phase 1: SSH Host Key Conflict

**Symptom**, connecting from the Windows client after the OS reinstall:
```text
WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
```

**Root cause:** the VM's SSH host key fingerprint changed because the OS was reinstalled (OL10 → OL8). The Windows local `known_hosts` file still held the fingerprint from the previous install, triggering OpenSSH's man-in-the-middle protection.

**Fix:**
```bash
ssh-keygen -R 192.168.0.106
```

---

## Phase 2: Root Privilege Escalation

**Symptom**, attempting to run the Tailscale install script as the default `linux-oracle-db` user:
```bash
curl -fsSL https://tailscale.com/install.sh | sh
# linux-oracle-db is not in the sudoers file. This incident will be reported.
```

**Fix:** switched to the root account directly for the remainder of privileged setup steps:
```bash
su -
```

**Recommended follow-up (not yet applied):** grant the standard user sudo rights going forward instead of relying on `su -` every time:
```bash
usermod -aG wheel linux-oracle-db
```

---

## Phase 3: Tailscale Installation

```bash
tailscale up
```

Authenticated via the browser-based auth link. Confirmed with `Success`.

Verified the new tailnet interface:
```bash
ip a
```

Result — `tailscale0` assigned:
```text
inet 100.118.110.114/32 scope global tailscale0
```

---

## Phase 4: Oracle Preinstall Package

**Symptom**, first attempt merged an unrelated command into the package name (typo, not an environment issue):
```bash
sudo dnf install -y oracle-database-preinstall-23aicd /tmp
# Error: No match for argument: oracle-database-preinstall-23aicd
```

**Fix:** ran a full system update first, then installed the correctly named package. On Oracle Linux 8, this package is served directly from the default `ol8_appstream` repository, no extra repo configuration required (unlike the earlier failed attempt to manually add a nonexistent OL10 repo path):
```bash
sudo dnf update -y
sudo dnf install -y oracle-database-preinstall-23ai
```

This single package automatically handled:
- Creating the `oracle` OS user and `oinstall` / `dba` groups
- Setting required kernel parameters (shared memory, semaphores)
- Installing dependencies: `ksh`, `sysstat`, `libXtst`, `libXxf86dga`, `libdmx`, `lm_sensors-libs`, `xorg-x11-utils`, `xorg-x11-xauth`

---

## Phase 5: Oracle 23ai Free Binary Install

**Symptom:** an initial `curl -O` download silently produced a 0-byte file (likely a redirect not being followed), which then failed at install time:
```bash
curl -O https://download.oracle.com/otn-pub/otn_software/db-free/oracle-database-free-23ai-1.0-1.el8.x86_64.rpm
# ... downloaded 0 bytes ...
dnf -y localinstall oracle-database-free-23ai-1.0-1.el8.x86_64.rpm
# Can not load RPM file: oracle-database-free-23ai-1.0-1.el8.x86_64.rpm.
```

**Fix:** re-downloaded using `-fL` (fail loudly on HTTP errors, follow redirects):
```bash
cd /tmp
curl -fL -O https://download.oracle.com/otn-pub/otn_software/db-free/oracle-database-free-23ai-1.0-1.el8.x86_64.rpm
```

This time the full 1.3 GB RPM downloaded successfully (~25 seconds at ~52 MB/s). Installed:
```bash
dnf -y localinstall oracle-database-free-23ai-1.0-1.el8.x86_64.rpm
```

Installed footprint: 3.5 GB, under `/opt/oracle/product/23ai/dbhomeFree`.

---

## Phase 6: Database Instance Configuration

```bash
/etc/init.d/oracle-free-23ai configure
```

**Symptom:** the first password attempt was rejected:
```text
The password you entered contains invalid characters.
```

**Root cause:** the chosen password contained an `@` character. Oracle reserves `@` for native connection string syntax (`user/password@database`), so it's disallowed inside the credential itself.

**Fix:** used a password meeting the minimum policy (8+ characters, at least 1 uppercase, 1 lowercase, 1 digit) without the reserved character.

Configuration completed successfully, creating:
- **Container Database (CDB):** `FREE`
- **Pluggable Database (PDB):** `FREEPDB1`

Verified:
```sql
sqlplus sys/<password> as sysdba

SQL> SHOW PDBS;

    CON_ID CON_NAME                       OPEN MODE  RESTRICTED
---------- ------------------------------ ---------- ----------
         2 PDB$SEED                       READ ONLY  NO
         3 FREEPDB1                       READ WRITE NO
```

---

## Phase 7: Persistent Environment Variables

Added to `/root/.bash_profile`:
```bash
cat << 'EOF' >> /root/.bash_profile

# Oracle Environment Variables
export ORACLE_SID=FREE
export ORACLE_HOME=/opt/oracle/product/23ai/dbhomeFree
export PATH=$PATH:$ORACLE_HOME/bin
EOF
```

The same block was replicated in:
- `/home/linux-oracle-db/.bashrc`
- `/home/oracle/.bash_profile` (the Oracle software owner)

Applied and verified:
```bash
source /root/.bash_profile
sqlplus -V
# SQL*Plus: Release 23.0.0.0.0 - Production
```

---

## Phase 8: Application User Creation

Created a dedicated application-layer database user, intended for future framework integration (e.g., Laravel via `yajra/laravel-oci8`), scoped inside `FREEPDB1` rather than the container root:

```sql
CREATE USER laravel_app IDENTIFIED BY <password>;
ALTER USER laravel_app QUOTA UNLIMITED ON USERS;
GRANT CONNECT, RESOURCE, CREATE VIEW, CREATE SESSION TO laravel_app;
```

> Note: `CONNECT` already implicitly includes `CREATE SESSION` on modern Oracle releases, granting both is redundant but harmless.

---

## Phase 9: Listener Troubleshooting

### 9.1 — Wrong process owner

**Symptom**, running the listener as `root`:
```bash
lsnrctl stop
lsnrctl start
```
```text
TNS-12547: TNS:lost contact
TNS-12560: Database communication protocol error.
 TNS-00517: Lost contact
  Linux Error: 32: Broken pipe
```

**Root cause:** the Oracle listener process must run under the `oracle` OS user (the owner of `$ORACLE_HOME`), never root. Running it as root causes a context/permission mismatch that surfaces as a misleading network-looking error.

### 9.2 — Interface binding

The default listener configuration also needed to explicitly bind to all interfaces rather than localhost only.

**Fix — switched to the `oracle` user:**
```bash
su - oracle
export ORACLE_SID=FREE
export ORACLE_HOME=/opt/oracle/product/23ai/dbhomeFree
export PATH=$PATH:$ORACLE_HOME/bin
```

**Rewrote `listener.ora`:**
```bash
cat << 'EOF' > /opt/oracle/product/23ai/dbhomeFree/network/admin/listener.ora
LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = 0.0.0.0)(PORT = 1521))
      (ADDRESS = (PROTOCOL = IPC)(KEY = EXTPROC1521))
    )
  )
EOF
```

**Started cleanly as the `oracle` user:**
```bash
lsnrctl start
```
```text
Listening on: (DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=0.0.0.0)(PORT=1521)))
Listening on: (DESCRIPTION=(ADDRESS=(PROTOCOL=ipc)(KEY=EXTPROC1521)))
The command completed successfully
```

**Forced immediate PDB registration** (rather than waiting for PMON's background registration interval):
```sql
sqlplus / as sysdba
SQL> ALTER SYSTEM REGISTER;
```

---

## Phase 10: Firewall Hardening

### 10.1 — Initial (temporary) validation step

To confirm the listener actually worked end-to-end, port 1521 was first opened globally:
```bash
firewall-cmd --permanent --add-port=1521/tcp
firewall-cmd --reload
```

### 10.2 — Final, hardened state

After confirming connectivity worked, the global rule was reversed and replaced with a Tailscale-scoped trust rule, so the database is reachable **only over the Tailscale mesh**, never the open LAN or public internet:

```bash
# Remove the global port rule
firewall-cmd --permanent --remove-port=1521/tcp

# Trust the Tailscale interface specifically
firewall-cmd --permanent --zone=trusted --add-interface=tailscale0

# Apply changes
firewall-cmd --reload
```

This mirrors the same access model already used for SSH on the other homelab VMs: reachable over Tailscale, closed off from the general LAN and internet.

---

## Phase 11: Service Persistence

Ensured the database and listener start automatically after VM reboots:
```bash
systemctl daemon-reload
systemctl enable oracle-free-23ai
systemctl is-enabled oracle-free-23ai
```
```text
oracle-free-23ai.service is not a native service, redirecting to systemd-sysv-install.
enabled
```

---

## Phase 12: Verification via DBeaver

### Administrative connection (SYSDBA)

| Field | Value |
|---|---|
| JDBC URL | `jdbc:oracle:thin:@100.118.110.114:1521/FREE` |
| Username | `sys` |
| Password | *(set during Phase 6)* |
| Role | SYSDBA |

### Application-layer connection (Laravel testing)

| Field | Value |
|---|---|
| Host | `100.118.110.114` |
| Port | `1521` |
| Service name | `FREEPDB1` |
| Username | `laravel_app` |
| Driver type | thin |

Both connections verified successfully from DBeaver Community over the Tailscale network.

---

## Troubleshooting Reference Table

| Symptom | Root Cause | Fix |
|---|---|---|
| `Kernel panic - Attempted to kill init` | CPU type / SeaBIOS mismatch on OL10 installer | Switched to OVMF, later abandoned OL10 entirely |
| `Fatal glibc error: CPU does not support x86-64-v3` | OL10 glibc baseline exceeds `x86-64-v2` CPU type | Set Proxmox CPU type to `host` (still ultimately required OL8 due to support policy) |
| `No match for argument: oracle-database-preinstall-23aicd` | Shell command typo/concatenation | Corrected command syntax |
| Downloaded RPM is 0 bytes | `curl -O` silently failed on redirect | Used `curl -fL -O` instead |
| `Can not load RPM file` | Corrupt/empty RPM from failed download | Re-downloaded with correct flags |
| `The password you entered contains invalid characters` | `@` character reserved for Oracle connection strings | Used a password without `@` |
| `TNS-12547: TNS:lost contact` / broken pipe | Listener run as `root` instead of `oracle` OS user | Ran `lsnrctl start` as `oracle` |
| `linux-oracle-db is not in the sudoers file` | Standard user lacks sudo rights | Used `su -` to become root |
| `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!` | Stale SSH fingerprint after OS reinstall | `ssh-keygen -R <ip>` |

---

## Key Lessons Learned

1. **Check OS/DBMS compatibility before installing the OS.** Oracle 23ai Free officially supports only OL8/OL9. Attempting OL10 first cost significant time on kernel panics and glibc errors that were symptoms of the underlying mismatch, not standalone bugs.
2. **Proxmox CPU type affects more than performance.** The `x86-64-v2` vs `v3` microarchitecture baseline can hard-fail a distro's userland at the glibc level, not just cause slower execution.
3. **Oracle's listener must run as the `oracle` OS user, never root.** Mismatched process ownership produces `TNS-12547` / broken pipe errors that look like network problems but are actually permission problems.
4. **`curl -O` can silently fail on redirects.** `curl -fL -O` fails loudly and follows redirects — the safer default for large binary downloads.
5. **Harden security after confirming functionality, not before.** Temporarily opening a port globally to validate a listener, then narrowing to a specific trusted interface, is a reasonable debugging sequence as long as the final state is locked down.
6. **Avoid `@` in Oracle account passwords.** It conflicts with native `user/password@database` connection string syntax.

---

## Why This Setup

- **PL/SQL engine capability** — business logic can be offloaded from the application layer (e.g. Laravel/PHP) directly into optimized database-side procedures.
- **In-memory-capable storage** — read-heavy tables can be cached to reduce query latency for hybrid transactional/analytical workloads.
- **Isolated learning environment** — fully separate from the other workshop databases (PostgreSQL, MariaDB, MySQL), reachable only over Tailscale, safe to break and rebuild without affecting the rest of the lab.
- **Portable DBA practice** — replicates the kind of hands-on Oracle administration environment normally only available in a university lab, but accessible anytime from a personal laptop via a lightweight VM.

---

## Future Work

- [ ] Relocate Oracle software and datafiles onto the reserved `/u01` and `/u02` LVM volumes instead of the default `/opt/oracle` path, for full OFA compliance
- [ ] Grant the standard user sudo rights (`usermod -aG wheel linux-oracle-db`) instead of relying on `su -`
- [ ] Take a Proxmox snapshot of the working state before beginning intentional break/fix practice (tablespace exhaustion, process kills, datafile corruption recovery)
- [ ] Configure RMAN backup jobs and practice restore scenarios
- [ ] Integrate `laravel_app` into a real Laravel project via `yajra/laravel-oci8` and compare developer experience against the existing PostgreSQL/MySQL workshop VMs
- [ ] Document AWR/performance monitoring basics once workload testing begins

---

## Disclaimer

This is a personal homelab learning project, not a production deployment guide. Passwords in this document are placeholders (`<password>`), replace with your own values and never commit real credentials to version control. Firewall and network configuration here reflects a single-user Tailscale tailnet threat model and should be reviewed before applying to any shared or production environment.
