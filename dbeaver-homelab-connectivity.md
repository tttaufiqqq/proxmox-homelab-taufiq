# DBeaver Homelab Database Connectivity Setup
**Author:** Taufiq
**Date:** 2 July 2026
**Scope:** Direct DBeaver connections to all homelab databases via Tailscale VPN + taufiq.lab DNS

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Network Architecture](#3-network-architecture)
4. [Why Direct Connection (No SSH Tunnel)](#4-why-direct-connection-no-ssh-tunnel)
5. [Connection Method: Tailscale + DNS](#5-connection-method-tailscale--dns)
6. [Database-by-Database Setup](#6-database-by-database-setup)
   - [6.1 PostgreSQL (linux-postgres)](#61-postgresql-linux-postgres)
   - [6.2 MariaDB (linux-mariadb / workshop-2)](#62-mariadb-linux-mariadb--workshop-2)
   - [6.3 MySQL on linux-mysql (Proxmox VM)](#63-mysql-on-linux-mysql-proxmox-vm)
   - [6.4 MySQL on msi (Local Laptop)](#64-mysql-on-msi-local-laptop)
   - [6.5 Oracle 23ai Free (linux-oracle-db)](#65-oracle-23ai-free-linux-oracle-db)
   - [6.6 SQL Server 2022 (linux-sql-server)](#66-sql-server-2022-linux-sql-server)
7. [Credential Reference](#7-credential-reference)
8. [What Had to Be Fixed Before DBeaver Could Connect](#8-what-had-to-be-fixed-before-dbeaver-could-connect)
9. [Troubleshooting](#9-troubleshooting)
10. [Connection Summary Card](#10-connection-summary-card)

---

## 1. Overview

This document describes how DBeaver (database GUI client) was configured to connect to all six database servers in the homelab. The connections work over **Tailscale VPN** using **taufiq.lab DNS hostnames** — no SSH tunnels, no port forwarding, no exposed public ports.

The homelab runs five different database engines across six separate machines:

```
+----------------------------------------------------------------------+
|                      HOMELAB DATABASE SERVERS                        |
+----------------+----------------+------------------+-----------------+
| linux-mariadb  | linux-postgres | linux-mysql      | linux-oracle-db |
| MariaDB 10.11  | PostgreSQL 16  | MySQL 8.0        | Oracle 23ai Free|
| 100.78.124.25  | 100.113.234.24 | 100.115.237.93   | 100.118.110.114 |
| Port 3306      | Port 5432      | Port 3306        | Port 1521       |
+----------------+----------------+------------------+-----------------+
         |              |                |                    |
         +--------------+----------------+--------------------+
                        |
                +-------+---------+   +----------------------+
                | [Tailscale VPN  |   | linux-sql-server     |
                |  Mesh]          |   | SQL Server 2022      |
                | WireGuard       |   | 100.117.38.113       |
                | encrypted       |   | Port 1433            |
                +-------+---------+   +----------+-----------+
                        |                        |
                        +------------------------+
                        |
             +----------+----------+
             |    MSI LAPTOP       |
             |    100.68.235.121   |
             |    DBeaver running  |
             |    MySQL 9.5 local  |
             +---------------------+
```

---

## 2. Prerequisites

Before DBeaver can connect:

1. **Tailscale must be running** on the laptop and all servers must be online in the tailnet.
   - Verify: `tailscale status` in terminal — all servers should show as connected.

2. **Windows hosts file must have taufiq.lab entries** — the hosts file takes priority over all DNS resolvers (including Tailscale Split DNS and Java's DNS resolver). This is the most reliable method for DBeaver, which uses the JVM DNS stack that doesn't always respect Tailscale Split DNS on Windows.

   Entries in `C:\Windows\System32\drivers\etc\hosts`:
   ```
   # taufiq.lab homelab DNS (Tailscale VMs)
   100.78.124.25   linux-mariadb.taufiq.lab  mariadb.taufiq.lab
   100.113.234.24  linux-postgres.taufiq.lab postgres.taufiq.lab
   100.115.237.93  linux-mysql.taufiq.lab    mysql.taufiq.lab
   100.118.110.114 linux-oracle-db.taufiq.lab oracle.taufiq.lab
   100.117.38.113  linux-sql-server.taufiq.lab mssql.taufiq.lab
   100.100.123.90  linux-app-server.taufiq.lab app-server.taufiq.lab
   ```

   To add via PowerShell (run as Administrator):
   ```powershell
   $h = 'C:\Windows\System32\drivers\etc\hosts'
   @"

   # taufiq.lab homelab DNS (Tailscale VMs)
   100.78.124.25   linux-mariadb.taufiq.lab  mariadb.taufiq.lab
   100.113.234.24  linux-postgres.taufiq.lab postgres.taufiq.lab
   100.115.237.93  linux-mysql.taufiq.lab    mysql.taufiq.lab
   100.118.110.114 linux-oracle-db.taufiq.lab oracle.taufiq.lab
   100.117.38.113  linux-sql-server.taufiq.lab mssql.taufiq.lab
   100.100.123.90  linux-app-server.taufiq.lab app-server.taufiq.lab
   "@ | Add-Content $h -Encoding ascii
   ```

   Verify resolution (all 6 should return an IP):
   ```powershell
   @('linux-mariadb.taufiq.lab','linux-postgres.taufiq.lab','linux-mysql.taufiq.lab') | ForEach-Object {
       $ip = [System.Net.Dns]::GetHostAddresses($_)[0].IPAddressToString
       Write-Host "$_ -> $ip"
   }
   ```

3. **DBeaver** installed on the laptop (any edition — Community works fine).

4. **JDBC drivers** — DBeaver downloads these automatically the first time you create a connection of each type.

---

## 3. Network Architecture

### Full Connectivity Diagram

```
                         INTERNET
                             |
                    (Tailscale Coordination)
                             |
         +-------------------+--------------------+
         |                   |                    |
+--------+--------+ +--------+--------+ +---------+-------+
| MSI LAPTOP      | | PROXMOX HOST    | | TAILSCALE       |
| 100.68.235.121  | | 100.97.8.93     | | COORDINATION    |
|                 | |                 | | SERVER          |
| DBeaver         | | dnsmasq :53     | |                 |
| Tailscale       | | Tailscale       | | Pushes Split    |
| client          | | client          | | DNS rules to    |
+--------+--------+ +--------+--------+ | all devices     |
         |                   |          +-----------------+
         |                   |
         |         +---------+---------+
         |         |  taufiq.lab DNS   |
         |         |  Records:         |
         |         |  linux-postgres   |
         |         |    100.113.234.24 |
         |         |  linux-mariadb    |
         |         |    100.78.124.25  |
         |         |  linux-mysql      |
         |         |    100.115.237.93 |
         |         +-------------------+
         |
         | Tailscale WireGuard encrypted tunnels
         |
         +----------------------------+----------------------------+
         |                            |                            |
+--------+--------+         +---------+-------+         +---------+-------+
| linux-postgres  |         | linux-mariadb   |         | linux-mysql     |
| 100.113.234.24  |         | 100.78.124.25   |         | 100.115.237.93  |
|                 |         |                 |         |                 |
| PostgreSQL 16   |         | MariaDB 10.11   |         | MySQL 8.0       |
| Port 5432       |         | Port 3306       |         | Port 3306       |
|                 |         |                 |         |                 |
| listen: *       |         | listen: *       |         | listen: *       |
| pg_hba: 0/0 md5 |         | bind: 0.0.0.0   |         | bind: 0.0.0.0   |
+-----------------+         +-----------------+         +-----------------+
```

### DNS Resolution Flow (when DBeaver connects to `linux-postgres.taufiq.lab`)

```
DBeaver enters hostname:
"linux-postgres.taufiq.lab"
         |
         v
Windows DNS resolver asks:
"What IP is linux-postgres.taufiq.lab?"
         |
         v
Tailscale client on laptop intercepts:
"taufiq.lab matches Split DNS rule"
         |
         v (via WireGuard tunnel)
dnsmasq on Proxmox (100.97.8.93):
Checks config:
  address=/linux-postgres.taufiq.lab/100.113.234.24
         |
         v
Returns: 100.113.234.24
         |
         v
DBeaver opens TCP connection to:
  100.113.234.24:5432
(via Tailscale tunnel, encrypted)
         |
         v
PostgreSQL on linux-postgres responds.
Connection established.
```

---

## 4. Why Direct Connection (No SSH Tunnel)

DBeaver supports two modes for connecting to remote databases:

### Mode A — SSH Tunnel (NOT used here)

```
DBeaver  --[SSH]--> remote server --> localhost:DB_PORT
```

In this mode DBeaver opens an SSH session to the server, then tunnels the DB port through it. This requires SSH credentials or keys, and the DB only needs to listen on `127.0.0.1`.

**Why we don't use this:**
- Already have Tailscale — a WireGuard VPN that provides the same encrypted channel
- SSH tunnel adds unnecessary complexity (extra credentials, potential connection drops)
- Tailscale creates a persistent, always-on mesh — the connection just works
- All DB servers are configured to listen on `0.0.0.0` (all interfaces), not just localhost

### Mode B — Direct TCP via Tailscale (USED here)

```
DBeaver  --[Tailscale WireGuard]--> DB_IP:DB_PORT
```

The database listens on its Tailscale IP. DBeaver connects directly. WireGuard handles encryption at the network layer — the connection is as secure as an SSH tunnel, but simpler.

**Why this works:**
- Tailscale assigns every device a stable private IP (100.x.x.x)
- These IPs are only reachable by devices on the same tailnet
- No firewall exception needed on the local LAN or public internet
- DBeaver treats it exactly like a LAN connection

---

## 5. Connection Method: Tailscale + DNS

Instead of memorising Tailscale IPs, we use DNS hostnames from the `taufiq.lab` domain:

```
Raw IP approach (old):
  DBeaver host: 100.113.234.24

DNS approach (new):
  DBeaver host: linux-postgres.taufiq.lab
```

Benefits:
- Human-readable — immediately obvious which server you're connecting to
- Stable — if a VM gets a new Tailscale IP, only one DNS record needs updating
- Consistent with SSH config (`ssh linux-postgres` also uses the same hostname)

### Verifying DNS Works Before Setting Up DBeaver

Open PowerShell and run:

```powershell
Resolve-DnsName linux-postgres.taufiq.lab
Resolve-DnsName linux-mariadb.taufiq.lab
Resolve-DnsName linux-mysql.taufiq.lab
```

Expected output for each:

```
Name                           Type   TTL   Section    IPAddress
----                           ----   ---   -------    ---------
linux-postgres.taufiq.lab      A      0     Answer     100.113.234.24
```

If you get "DNS name does not exist", Tailscale is not running or the Split DNS rule is not active.

---

## 6. Database-by-Database Setup

### 6.1 PostgreSQL (linux-postgres)

**Server:** linux-postgres.taufiq.lab (100.113.234.24)
**Engine:** PostgreSQL 16
**Port:** 5432

#### What Had to Be Set Up on the Server

PostgreSQL needed two configuration changes to accept remote connections:

**`/etc/postgresql/16/main/postgresql.conf`**
```
listen_addresses = '*'    # Listen on all interfaces, not just localhost
```

**`/etc/postgresql/16/main/pg_hba.conf`** (append this line)
```
host  all  all  0.0.0.0/0  md5
```

This tells PostgreSQL: accept password-authenticated connections from any IP address. Since the port is only reachable via Tailscale, "any IP" in practice means "any device on our tailnet."

After changing these files, restart PostgreSQL:
```bash
sudo systemctl restart postgresql
```

Verify it is listening on all interfaces:
```bash
ss -tlnp | grep 5432
# Expected:
# LISTEN 0 200 0.0.0.0:5432 0.0.0.0:*
# LISTEN 0 200    [::]:5432    [::]:*
```

#### Superuser Password Reset

The `postgres` superuser password was not known. It was reset via:

```bash
sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'qwertY@1612';"
```

#### DBeaver Connection Settings

```
Connection type : PostgreSQL
Host            : linux-postgres.taufiq.lab
Port            : 5432
Database        : postgres          (for admin access)
                  workshop_2        (for application data)
Username        : postgres          (superuser / admin)
                  workshop_2        (application user)
Password        : qwertY@1612       (postgres superuser)
                  workshop_2        (workshop_2 user)
SSL             : off (not needed — Tailscale provides transport encryption)
SSH Tunnel      : off
```

In DBeaver UI:
1. New Connection → PostgreSQL
2. Fill in the fields above
3. Click "Test Connection" — downloads driver if first time
4. Should show "Connected to PostgreSQL 16"

#### Connection Diagram

```
+---------------------+           +----------------------+
|   DBeaver (MSI)     |           |  linux-postgres      |
|                     |           |  100.113.234.24      |
|  Host:              |           |                      |
|  linux-postgres     +---------> |  PostgreSQL 16       |
|  .taufiq.lab        |  TCP 5432 |  Port 5432           |
|                     |  (via     |  listen: 0.0.0.0     |
|  User: postgres     |  Tailscale|  pg_hba: 0/0 md5     |
|  Pass: qwertY@1612  |  WG)      |                      |
+---------------------+           +----------------------+
```

---

### 6.2 MariaDB (linux-mariadb / workshop-2)

**Server:** linux-mariadb.taufiq.lab (100.78.124.25)
**Engine:** MariaDB 10.11
**Port:** 3306

#### Root Password Reset — What Went Wrong and How It Was Fixed

The MariaDB root password was unknown. The standard approach on Debian/Ubuntu is unix socket authentication:

```bash
sudo mariadb   # should work as OS root
```

This failed because the root user's auth plugin had been changed from `unix_socket` to `mysql_native_password` at some point (visible in `mysql.history` showing the root user was explicitly created with a password).

The fix required starting MariaDB in skip-grant-tables mode. This was complicated by the `@` symbol in the target password `qwertY@1612` — when passed through nested bash quotes, the `@` was truncated in the SQL string, causing a syntax error.

**Root cause of the quoting problem:**

```bash
# This FAILS — @ inside double-quoted string inside bash -c gets truncated
mariadb -u root -e "ALTER USER root@localhost IDENTIFIED BY 'qwertY@1612';"
# SQL received: ALTER USER root@localhost IDENTIFIED BY 'qwertY

# This FAILS too — same issue with different quoting
sudo bash -c "mariadb -e \"... 'qwertY@1612' ...\""
```

**The fix — write SQL to a temp file:**

```bash
# Write SQL to a file (no quoting issues)
cat > /tmp/fix_root.sql << 'EOF'
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('qwertY@1612');
FLUSH PRIVILEGES;
EOF

# Start MariaDB in skip-grant-tables mode
systemctl stop mariadb
mariadbd --skip-grant-tables --skip-networking --user=mysql --datadir=/var/lib/mysql &
sleep 4

# Run the SQL file (no quoting issues — file is already on disk)
mariadb -u root < /tmp/fix_root.sql

# Shut down the temp instance and start normally
kill %1
sleep 2
systemctl start mariadb
```

**Complication: stale process holding file locks**

A previous skip-grant-tables attempt had left a `mariadbd` process running in the background, holding an exclusive lock on `/var/lib/mysql/aria_log_control` and `ibdata1`. Every subsequent `systemctl start mariadb` failed with:

```
ERROR: mariadbd: Can't lock aria control file '/var/lib/mysql/aria_log_control' for exclusive use
ERROR: InnoDB: Unable to lock ./ibdata1 error: 11
```

Fix: identify and kill the stale process:

```bash
ps aux | grep mariad
# Found: PID 2006 (mariadbd-safe) and PID 2141 (mariadbd)

kill 2006 2141
sleep 2
systemctl start mariadb
# Now starts cleanly
```

#### DBeaver Connection Settings

```
Connection type : MariaDB (or MySQL — both work with MariaDB)
Host            : linux-mariadb.taufiq.lab
Port            : 3306
Database        : workshop_2
Username        : root              (admin)
                  workshop_2        (application user)
Password        : qwertY@1612       (root)
                  workshop_2        (workshop_2 user)
SSL             : off
SSH Tunnel      : off
```

#### Connection Diagram

```
+---------------------+           +----------------------+
|   DBeaver (MSI)     |           |  linux-mariadb       |
|                     |           |  100.78.124.25       |
|  Host:              |           |                      |
|  linux-mariadb      +---------> |  MariaDB 10.11       |
|  .taufiq.lab        |  TCP 3306 |  Port 3306           |
|                     |  (via     |  bind: 0.0.0.0       |
|  User: root         |  Tailscale|  auth: native_pwd    |
|  Pass: qwertY@1612  |  WG)      |                      |
+---------------------+           +----------------------+
```

---

### 6.3 MySQL on linux-mysql (Proxmox VM)

**Server:** linux-mysql.taufiq.lab (100.115.237.93)
**Engine:** MySQL 8.0
**Port:** 3306
**SSH username:** workshop-mysql

#### What Had to Be Fixed on the Server

Three separate problems prevented DBeaver from connecting to linux-mysql.

**Problem A — Root password unknown**

The MySQL root password was not set to any known value. The skip-grant-tables approach was used, but MySQL 8.0's password policy (`validate_password` plugin) and socket lock file issues made this significantly harder than MariaDB.

Key obstacle: MySQL 8.0 runs `mysqld` from systemd under the `mysql` OS user. Manually launching `mysqld --skip-grant-tables` as root (via sudo) caused it to fail creating `/var/run/mysqld/mysqld.sock.lock` because the directory is owned by `mysql`. Passing `--user=mysql` didn't help because the process was still launched from a root-owned shell.

**Solution — inject init-file via systemd config:**

```bash
# Encode the SQL via base64 to avoid ALL shell quoting issues with @ in password
# (on local machine)
echo "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY 'qwertY@1612';
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'qwertY@1612';
FLUSH PRIVILEGES;" | base64 -w0
# Output: QUxURVIg...

# On linux-mysql (via SSH):
echo QUxURVIgVVNFUiAncm9vdCdAJ2xvY2FsaG9zdCcgSURFTlRJRklFRCBXSVRIIG15c3FsX25hdGl2ZV9wYXNzd29yZCBCWSAncXdlcnRZQDE2MTInOwpBTFRFUiBVU0VSICdyb290J0AnJScgSURFTlRJRklFRCBXSVRIIG15c3FsX25hdGl2ZV9wYXNzd29yZCBCWSAncXdlcnRZQDE2MTInOwpGTFVTSCBQUklWSUxFR0VTOwo= \
  | base64 -d > /tmp/init.sql
chown mysql:mysql /tmp/init.sql

# Add init-file to MySQL's systemd config so MySQL itself (running as mysql user) executes it
echo -e "[mysqld]\ninit-file=/tmp/init.sql" > /etc/mysql/mysql.conf.d/init-pw.cnf
systemctl restart mysql   # systemd launches mysqld as mysql user — no socket issues
sleep 5

# Remove init-file config so it doesn't re-run on every restart
rm /etc/mysql/mysql.conf.d/init-pw.cnf /tmp/init.sql
systemctl restart mysql
```

**Why base64?** MySQL's init-file parser treats `@` in unquoted context as a user variable reference. Passing `qwertY@1612` through nested bash quoting layers (`sudo -S bash -c '...'`) caused the `@` to be misinterpreted or truncated at both the shell level and the MySQL SQL parser level. Base64-encoding the SQL on the local machine and decoding on the server bypasses all quoting entirely — the file is written as plain bytes with no shell interpretation.

**Why systemd config injection instead of manual mysqld?** Manually launching `mysqld` as any user fails to create the unix socket lock file `/var/run/mysqld/mysqld.sock.lock` because systemd pre-creates that directory with specific permissions. The `--init-file` approach through `systemctl restart` lets systemd handle process setup correctly.

**Problem B — bind-address locked to 127.0.0.1**

After fixing the root password, DBeaver still showed "Connection refused: getsockopt" because MySQL was only listening on localhost:

```bash
ss -tlnp | grep 3306
# LISTEN 0 151  127.0.0.1:3306  0.0.0.0:*   ← only localhost, not Tailscale IP
```

Default Ubuntu MySQL config (`/etc/mysql/mysql.conf.d/mysqld.cnf`) has `bind-address = 127.0.0.1`.

**Fix:**
```bash
sudo sed -i "s/bind-address\t\t= 127.0.0.1/bind-address\t\t= 0.0.0.0/" \
  /etc/mysql/mysql.conf.d/mysqld.cnf
sudo systemctl restart mysql

# Verify
ss -tlnp | grep 3306
# LISTEN 0 151  0.0.0.0:3306  0.0.0.0:*   ✓
```

**Problem C — No remote user accounts (only @localhost existed)**

Even with MySQL listening on `0.0.0.0`, DBeaver would get "Access denied" because only `root@localhost` and `workshop_2@localhost` existed — no `@'%'` entries for remote connections.

```bash
# After resetting root password, only these existed:
# root        localhost   mysql_native_password
# workshop_2  localhost   mysql_native_password
# No @'%' entries — all remote connections rejected
```

**Fix:**
```bash
# Password policy rejects 'workshop_2' as too simple — disable temporarily
mysql -u root -p'qwertY@1612' -e "
SET GLOBAL validate_password.policy = LOW;
SET GLOBAL validate_password.length = 1;
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'qwertY@1612';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
CREATE USER IF NOT EXISTS 'workshop_2'@'%' IDENTIFIED WITH mysql_native_password BY 'workshop_2';
GRANT ALL PRIVILEGES ON workshop_2.* TO 'workshop_2'@'%';
FLUSH PRIVILEGES;
SET GLOBAL validate_password.policy = MEDIUM;
SET GLOBAL validate_password.length = 8;
"
```

#### DBeaver Connection Settings

```
Connection type : MySQL
Host            : linux-mysql.taufiq.lab
Port            : 3306
Database        : workshop_2
Username        : root              (admin)
                  workshop_2        (application user)
Password        : qwertY@1612       (root)
                  workshop_2        (workshop_2 user)
SSL             : off
SSH Tunnel      : off
```

#### Connection Diagram

```
+---------------------+           +----------------------+
|   DBeaver (MSI)     |           |  linux-mysql         |
|                     |           |  100.115.237.93      |
|  Host:              |           |                      |
|  linux-mysql        +---------> |  MySQL 8.0           |
|  .taufiq.lab        |  TCP 3306 |  Port 3306           |
|                     |  (via     |  bind: 0.0.0.0       |
|  User: root         |  Tailscale|  root@% + ws_2@%     |
|  Pass: qwertY@1612  |  WG)      |  created             |
+---------------------+           +----------------------+
```

---

### 6.4 MySQL on msi (Local Laptop)

**Server:** 100.68.235.121 (the laptop itself, no DNS alias in taufiq.lab)
**Engine:** MySQL 9.5
**Port:** 3306

This is the MySQL instance running locally on the MSI laptop. It is used by the Animal Shelter Workshop project for the `shelter` and `animals` connections.

```
Connection type : MySQL
Host            : localhost   (or 127.0.0.1)
Port            : 3306
Database        : workshop_2
Username        : root        (admin)
                  workshop_2  (application user)
Password        : password    (root — different from others, historical)
                  workshop_2  (workshop_2 user)
```

> Note: The root password on msi's MySQL is `password`, not `qwertY@1612`. This is the only exception in the homelab.

---

### 6.5 Oracle 23ai Free (linux-oracle-db)

**Server:** linux-oracle-db.taufiq.lab (100.118.110.114)
**Engine:** Oracle Database 23ai Free
**Port:** 1521
**SSH username:** linux-oracle-db
**Oracle OS user:** oracle
**Container DB (CDB):** FREE
**Pluggable DB (PDB):** FREEPDB1

#### Critical: @ is Illegal in Oracle Passwords

Oracle reserves the `@` character in connection strings to separate the host from the service name (e.g., `user@host/service`). This means **`@` cannot appear inside an Oracle password**. The password for the sys/system accounts is:

```
qwertY1612    ← no @ symbol (unlike all other homelab servers which use qwertY@1612)
```

Attempting `qwertY@1612` in DBeaver's password field will cause an ORA-01017 error. The password is `qwertY1612`.

#### Oracle Listener and Service Architecture

Oracle uses a listener process (TNSLSNR) that sits in front of the database and handles incoming connection requests. The flow is:

```
DBeaver
  |
  v
TNSLSNR (lsnrctl) on port 1521
  |
  | Routes based on SERVICE_NAME
  v
Oracle DB instance (PMON process registers the service)
  |
  | FREE = CDB, FREEPDB1 = PDB
  v
Schema / user
```

When the Oracle VM reboots, the systemd service `oracle-free-23ai` starts the database. However, the PMON background process (Process Monitor) takes approximately **30–60 seconds** to register the `FREE` service with the listener. During this window, the listener is running but rejects connections:

```
ORA-12514: TNS:listener does not currently know of service requested in connect descriptor
```

After 60 seconds (or after running `ALTER SYSTEM REGISTER;`), the service registers and connections succeed.

#### OS User Restrictions

The `linux-oracle-db` OS user (the SSH login user) is **not in the sudoers file** and is not in the `dba` group. This means:
- `sudo` commands fail: "linux-oracle-db is not in the sudoers file"
- `sqlplus / as sysdba` fails: "ORA-01017: invalid credential/logon denied" (not in dba group)

To run Oracle admin commands, you must become the `oracle` OS user:

```bash
# From linux-oracle-db user, escalate to root first, then to oracle
ssh linux-oracle-db@100.118.110.114

# su to root (password: qwertY@1612)
su - root

# su to oracle (no password needed when coming from root)
su - oracle

# Now oracle admin commands work
sqlplus / as sysdba
```

Or in one chained command (useful for scripting):

```bash
# The oracle user needs ORACLE_HOME and PATH set manually when using su -c
su - root -c 'su - oracle -c "ORACLE_HOME=/opt/oracle/product/23ai/dbhomeFree ORACLE_SID=FREE PATH=/opt/oracle/product/23ai/dbhomeFree/bin:/usr/local/bin:/usr/bin:/bin sqlplus / as sysdba <<< \"ALTER SYSTEM REGISTER; EXIT;\""'
```

**Why not use a script file?** Writing a script to `/tmp/fix_oracle.sh` and executing it is more reliable than multi-level quoting:

```bash
# On the server (as any user):
cat > /tmp/fix_oracle.sh << 'EOF'
#!/bin/bash
export ORACLE_HOME=/opt/oracle/product/23ai/dbhomeFree
export ORACLE_SID=FREE
export PATH=/opt/oracle/product/23ai/dbhomeFree/bin:/usr/local/bin:/usr/bin:/bin
sqlplus -S / as sysdba << SQL
ALTER SYSTEM REGISTER;
SELECT name, open_mode FROM v\$database;
SHOW PDBS;
EXIT;
SQL
lsnrctl status 2>&1 | grep -E "Service|Instance|Listening"
EOF
chmod +x /tmp/fix_oracle.sh

# Run it as oracle via root:
su - root -c 'su - oracle -s /bin/bash /tmp/fix_oracle.sh'
# Enter root password: qwertY@1612
```

#### Persistent Fix Applied: local_listener Parameter

The default oracle-free-23ai installation sets `local_listener = LISTENER_FREE` — a TNS alias. Without a `tnsnames.ora` file to resolve this alias, PMON cannot locate the listener and never registers the `FREE` or `FREEPDB1` services. `lsnrctl status` shows "The listener supports no services" and `ALTER SYSTEM REGISTER` appears to succeed but has no effect.

**One-time fix (already applied, persists across reboots):**

```bash
# As oracle OS user:
sqlplus / as sysdba
SQL> ALTER SYSTEM SET local_listener = '(ADDRESS=(PROTOCOL=TCP)(HOST=localhost)(PORT=1521))' SCOPE=BOTH;
SQL> ALTER SYSTEM REGISTER;
SQL> EXIT;
```

`SCOPE=BOTH` writes to both the running instance and the spfile — the parameter survives reboots. This was applied on 2 July 2026 and does not need to be repeated unless the database is rebuilt from scratch.

After applying: all four services registered immediately:
```
Service "FREE"     has 1 instance(s). Instance "FREE", status READY  ← CDB
Service "freepdb1" has 1 instance(s). Instance "FREE", status READY  ← PDB
Service "FREEXDB"  has 1 instance(s). Instance "FREE", status READY
```

DBeaver connected successfully: **Connected (714 ms)** — Oracle Database 23ai Free Release 23.0.0.0.0, Version 23.7.0.25.01.

#### What to Do After Every Oracle VM Reboot

The `local_listener` fix is now permanent. After a reboot, PMON will auto-register services within ~60 seconds. No manual intervention is needed unless the VM reboots and you try to connect within that first minute.

1. Boot the VM and wait ~60 seconds.
2. Try DBeaver — it should connect without any manual steps.
3. If `ORA-12514` still appears after 60 seconds, force immediate registration:

```bash
ssh -F /dev/null -i ~/.ssh/id_ed25519 linux-oracle-db@100.118.110.114
# (BOM in SSH config — use -F /dev/null to bypass it)
echo 'qwertY@1612' | su -s /bin/bash - root -c 'su -s /bin/bash - oracle -c "
  export ORACLE_HOME=/opt/oracle/product/23ai/dbhomeFree
  export ORACLE_SID=FREE
  export PATH=\$ORACLE_HOME/bin:\$PATH
  sqlplus / as sysdba <<< \"ALTER SYSTEM REGISTER; EXIT;\"
"'
```

#### Listener Status Check

```bash
# As oracle OS user:
lsnrctl status

# Expected output (healthy state):
# Service "FREE" has 1 instance(s).
#   Instance "FREE", status READY, has 1 handler(s) for this service...
# Service "freepdb1" has 1 instance(s).
#   Instance "FREE", status READY, has 1 handler(s) for this service...
# Service "FREEXDB" has 1 instance(s).
#   Instance "FREE", status READY, has 1 handler(s) for this service...
```

If you see "The listener supports no services" **and** the database has been running for more than 60 seconds, the `local_listener` parameter may have been reset. Run the persistent fix again (see above).

#### DBeaver Connection Settings

DBeaver supports Oracle in two modes: **thin JDBC** (no Oracle client needed) and **OCI** (requires Oracle Instant Client). Use thin JDBC:

```
Connection type : Oracle
Driver          : Oracle Thin (automatically downloaded)
Host            : linux-oracle-db.taufiq.lab   (or 100.118.110.114)
Port            : 1521
Service Name    : FREE      ← connect as SYSDBA to the CDB
                  FREEPDB1  ← connect to the pluggable database (for app use)
Username        : sys       (superuser — for admin)
                  system    (DBA account — for admin)
Role            : SYSDBA    (required for sys user — select from dropdown)
Password        : qwertY1612  ← NO @ in this password!
SSL             : off
SSH Tunnel      : off
```

> **Important:** When connecting as `sys`, the Role field in DBeaver must be set to **SYSDBA**. If Role is left as "Normal", you will get ORA-28009 even with the correct password.

#### Connection Diagram

```
+---------------------+           +------------------------+
|   DBeaver (MSI)     |           |  linux-oracle-db       |
|                     |           |  100.118.110.114       |
|  Host:              |           |                        |
|  linux-oracle-db    +---------> |  TNSLSNR :1521         |
|  .taufiq.lab        |  TCP 1521 |    |                   |
|                     |  (via     |    v                   |
|  User: sys          |  Tailscale|  Oracle 23ai Free      |
|  Role: SYSDBA       |  WG)      |  CDB: FREE             |
|  Pass: qwertY1612   |           |  PDB: FREEPDB1         |
+---------------------+           +------------------------+
                                  NOTE: no @ in password
```

---

### 6.6 SQL Server 2022 (linux-sql-server)

**Server:** linux-sql-server.taufiq.lab (100.117.38.113)
**Engine:** SQL Server 2022 on Linux (Ubuntu)
**Port:** 1433
**SSH username:** workshop-sql (or root with password qwertY@1612)

#### What Had to Be Done

SQL Server 2022 on Linux runs as a standard service (`mssql-server`). After the VM was turned on, the service started automatically and was immediately accessible — no additional configuration was needed beyond having the VM online.

The `sa` (system administrator) account is the built-in SQL Server superuser. Its password was set during initial SQL Server setup:

```
Username : sa
Password : qwertY@1612   ← @ is allowed in SQL Server passwords (unlike Oracle)
```

#### DBeaver Connection Settings

DBeaver requires one extra setting for SQL Server: **Trust Server Certificate**. SQL Server on Linux generates a self-signed TLS certificate. By default DBeaver rejects self-signed certs. Enabling "Trust Server Certificate" bypasses the validation:

```
Connection type  : SQL Server (Microsoft JDBC Driver)
Driver           : Microsoft JDBC (automatically downloaded)
Host             : linux-sql-server.taufiq.lab   (or 100.117.38.113)
Port             : 1433
Database         : master     (default/admin database)
Username         : sa
Password         : qwertY@1612
SSL              : off
SSH Tunnel       : off

Driver properties (under "Driver properties" tab):
  trustServerCertificate = true
```

To set `trustServerCertificate` in DBeaver:
1. After entering host/port/credentials, click the **"Driver Properties"** tab
2. Find `trustServerCertificate` in the list (or type it in the filter)
3. Set value to `true`
4. Click "Test Connection"

Or alternatively, in the "Main" tab, there is a checkbox "Trust server certificate" under the connection options section — tick it.

#### Service Verification (SSH)

```bash
ssh root@100.117.38.113
# password: qwertY@1612

# Check SQL Server status
systemctl status mssql-server
# Expected: active (running)

# Verify port is listening
ss -tlnp | grep 1433
# Expected: LISTEN 0 128 0.0.0.0:1433 0.0.0.0:*

# Quick connectivity test via sqlcmd (if installed)
/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P 'qwertY@1612' -Q "SELECT @@VERSION"
```

#### Connection Diagram

```
+---------------------+           +------------------------+
|   DBeaver (MSI)     |           |  linux-sql-server      |
|                     |           |  100.117.38.113        |
|  Host:              |           |                        |
|  linux-sql-server   +---------> |  SQL Server 2022       |
|  .taufiq.lab        |  TCP 1433 |  Port 1433             |
|                     |  (via     |  sa user enabled       |
|  User: sa           |  Tailscale|  trustServerCert: true |
|  Pass: qwertY@1612  |  WG)      |  (self-signed TLS)     |
+---------------------+           +------------------------+
```

---

## 7. Credential Reference

### Admin / Superuser Credentials

| Server | DNS Hostname | Tailscale IP | Engine | Admin User | Admin Password | Note |
|--------|-------------|-------------|--------|------------|----------------|------|
| linux-mariadb | linux-mariadb.taufiq.lab | 100.78.124.25 | MariaDB 10.11 | `root` | `qwertY@1612` | |
| linux-mysql | linux-mysql.taufiq.lab | 100.115.237.93 | MySQL 8.0 | `root` | `qwertY@1612` | |
| linux-postgres | linux-postgres.taufiq.lab | 100.113.234.24 | PostgreSQL 16 | `postgres` | `qwertY@1612` | |
| linux-oracle-db | linux-oracle-db.taufiq.lab | 100.118.110.114 | Oracle 23ai Free | `sys` | `qwertY1612` | **No @** — Oracle restriction |
| linux-sql-server | linux-sql-server.taufiq.lab | 100.117.38.113 | SQL Server 2022 | `sa` | `qwertY@1612` | Trust cert ON |
| msi (local) | localhost | 100.68.235.121 | MySQL 9.5 | `root` | `password` | Local only |

> **Oracle password exception:** `@` is illegal in Oracle passwords (it is a connection string delimiter). The Oracle admin password is `qwertY1612` — no `@`. All other VM admin passwords are `qwertY@1612`.

### Application User Credentials (workshop_2)

Same across all servers and all engines:

| Field | Value |
|-------|-------|
| Username | `workshop_2` |
| Password | `workshop_2` |
| Database | `workshop_2` |
| Port (MySQL/MariaDB) | 3306 |
| Port (PostgreSQL) | 5432 |

---

## 8. What Had to Be Fixed Before DBeaver Could Connect

This section documents the specific problems encountered and how they were resolved, in order.

### Problem 1 — PostgreSQL superuser password unknown

**Symptom:** Cannot authenticate as `postgres` user in DBeaver.

**Root cause:** The PostgreSQL `postgres` superuser had no known password. PostgreSQL installs with the `postgres` OS user using peer authentication, so no password is set by default.

**Fix:**
```bash
# SSH into linux-postgres
ssh workshop-postgres@100.113.234.24

# Connect as postgres OS user and set password
sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'qwertY@1612';"
```

**Verification:**
```bash
psql -h localhost -U postgres -c "SELECT version();"
# Enter password: qwertY@1612
# Returns: PostgreSQL 16.x ...
```

---

### Problem 2 — PostgreSQL not listening on external interface

**Symptom:** DBeaver showed "Connection refused: getsockopt" when connecting to `linux-postgres.taufiq.lab:5432`.

**Root cause:** Default PostgreSQL config sets `listen_addresses = 'localhost'` — it only accepts connections from `127.0.0.1`, not from external IPs (including the Tailscale IP `100.113.234.24`).

**Fix:**

Edit `/etc/postgresql/16/main/postgresql.conf`:
```
# Before
listen_addresses = 'localhost'

# After
listen_addresses = '*'
```

Edit `/etc/postgresql/16/main/pg_hba.conf` — add at the bottom:
```
host  all  all  0.0.0.0/0  md5
```

Restart:
```bash
sudo systemctl restart postgresql
```

**Verification:**
```bash
ss -tlnp | grep 5432
# Expected: LISTEN 0 200 0.0.0.0:5432 0.0.0.0:*
```

---

### Problem 3 — MariaDB root password unknown (and unix socket auth broken)

**Symptom:** `sudo mariadb` (unix socket auth) showed "Access denied for user 'root'@'localhost' (using password: NO)".

**Root cause:** The root user's auth plugin had been changed from `unix_socket` to `mysql_native_password` at some point. Connecting without a password fails because MySQL native password auth requires an actual password.

**Fix:** Requires skip-grant-tables mode. But the password contained `@`, which breaks when passed through nested bash quoting. Solution: write the SQL to a file.

Full procedure documented in [Section 6.2](#62-mariadb-linux-mariadb--workshop-2).

---

### Problem 4 — MariaDB failed to start after skip-grant-tables (file lock)

**Symptom:**
```
mariadbd: Can't lock aria control file '/var/lib/mysql/aria_log_control' for exclusive use, error: 11
InnoDB: Unable to lock ./ibdata1 error: 11
mariadb.service: Failed with result 'exit-code'
```

**Root cause:** A previous skip-grant-tables `mariadbd` process was still running in the background (not properly killed), holding exclusive locks on the InnoDB and Aria data files. Every new `mariadbd` start attempt saw those files as locked and aborted.

**Fix:**
```bash
# Find the stale processes
ps aux | grep mariad
# mariadbd-safe PID 2006, mariadbd PID 2141

# Kill them
sudo kill 2006 2141
sleep 2

# Now start normally
sudo systemctl start mariadb
# Active: active (running)
```

**Key lesson:** When killing a `mariadbd --skip-grant-tables` instance started manually, always use `kill PID` and wait for it to fully exit before starting the systemd service. Using `systemctl stop mariadb` does not stop a manually-launched `mariadbd` process.

---

### Problem 6 — MySQL (linux-mysql) three separate blockers

See [Section 6.3](#63-mysql-on-linux-mysql-proxmox-vm) for the full detail. In summary, three issues had to be fixed in sequence:

1. **Root password unknown** — reset via base64-encoded init-file injected through systemd config (avoids `@` quoting issues and socket lock file problems from manual `mysqld` launch)
2. **bind-address = 127.0.0.1** — MySQL only listened on localhost; changed to `0.0.0.0` in `/etc/mysql/mysql.conf.d/mysqld.cnf`
3. **No remote user accounts** — only `@localhost` entries existed; created `root@'%'` and `workshop_2@'%'` after temporarily lowering the `validate_password` policy (which rejected `workshop_2` as too simple)

---

### Problem 7 — Oracle ORA-12541: listener not running

**Symptom:** DBeaver showed "IO Error: The Network Adapter could not establish the connection" with internal error `ORA-12541: TNS:no listener`.

**Root cause:** The Oracle VM had just been turned on. The `oracle-free-23ai` systemd service starts the database, but the TNS listener (TNSLSNR) was not yet running. Oracle's listener is a separate process from the database instance — it must be started explicitly (or via its own systemd service, if configured).

**Fix:** Wait for the systemd service to fully start and the listener to come up. If it doesn't start automatically, start it manually as the `oracle` OS user:

```bash
# SSH as linux-oracle-db user, then escalate
ssh linux-oracle-db@100.118.110.114
su - root          # password: qwertY@1612
su - oracle

# Check listener status
lsnrctl status

# If "TNS-12541: TNS:no listener", start it
lsnrctl start

# If "TNS-12547: TNS:lost contact" — listener must run as oracle user, which it is
# The listener was already started by oracle-free-23ai systemd service
```

After the listener started, the error progressed to ORA-12514 (listener running, service not registered — see Problem 8).

---

### Problem 8 — Oracle ORA-12514: listener running but service not registered

**Symptom:** DBeaver showed `ORA-12514: TNS:listener does not currently know of service requested in connect descriptor` when connecting to service name `FREE`. `ALTER SYSTEM REGISTER` ran without error but had no effect — `lsnrctl status` continued to show "The listener supports no services."

**Root cause (deeper than PMON timing):** The default oracle-free-23ai package sets the `local_listener` database parameter to `LISTENER_FREE`, which is a TNS alias. Oracle's PMON process resolves this alias by looking in `tnsnames.ora` to find the listener's actual network address. However, `tnsnames.ora` does not exist in this installation:

```
/opt/oracle/product/23ai/dbhomeFree/network/admin/tnsnames.ora  ← FILE NOT FOUND
```

With no `tnsnames.ora`, PMON cannot resolve `LISTENER_FREE` → cannot locate the listener → never sends registration → listener shows "The listener supports no services" indefinitely, regardless of how many times `ALTER SYSTEM REGISTER` is run.

**Diagnosis:**
```sql
SHOW PARAMETER local_listener;
-- NAME           TYPE    VALUE
-- local_listener string  LISTENER_FREE   ← TNS alias, not a real address
```

**Fix — set local_listener to the explicit TCP address (SCOPE=BOTH persists across reboots):**

```bash
# As oracle OS user:
sqlplus / as sysdba

SQL> ALTER SYSTEM SET local_listener = '(ADDRESS=(PROTOCOL=TCP)(HOST=localhost)(PORT=1521))' SCOPE=BOTH;
System altered.

SQL> ALTER SYSTEM REGISTER;
System altered.

SQL> EXIT;

# Verify — should now show services:
lsnrctl status | grep -E "Service|READY"
# Service "FREE" has 1 instance(s).
#   Instance "FREE", status READY, has 1 handler(s)
# Service "freepdb1" has 1 instance(s).
#   Instance "FREE", status READY, has 1 handler(s)
```

**Result:** DBeaver connected — **Connected (714 ms)**, Oracle Database 23ai Free 23.7.0.25.01.

**Why `SCOPE=BOTH`?** `SCOPE=MEMORY` only fixes the current session — the parameter reverts on reboot. `SCOPE=BOTH` writes to the spfile, so the correct `local_listener` value is preserved permanently.

**Why can't linux-oracle-db user run sqlplus / as sysdba?**

The `linux-oracle-db` OS user is not a member of the `dba` group (which grants OS-level SYSDBA authentication). `/ as sysdba` uses OS group membership — if the user is not in `dba`, Oracle rejects it with ORA-01017 even though there is no password prompt. The `oracle` OS user is in the `dba` group, so it can connect as sysdba without a password.

---

### Problem 9 — Oracle: @ in password causes ORA-01017

**Symptom:** Entering `qwertY@1612` as the sys password in DBeaver showed `ORA-01017: invalid username/password; logon denied`.

**Root cause:** Oracle's JDBC thin driver (and Oracle's own tools) treat `@` as a delimiter in connection strings. When `@` appears inside a password, it truncates the password at the `@` character — the driver sends only `qwertY` as the password, which is wrong.

**Fix:** The Oracle admin password is `qwertY1612` — no `@` symbol. This was set during initial database configuration and cannot be changed to include `@`.

```
Wrong in DBeaver: qwertY@1612   ← @ truncates to qwertY → ORA-01017
Correct:          qwertY1612    ← no @ → connects successfully
```

This is **unique to Oracle**. All other homelab servers (MariaDB, MySQL, PostgreSQL, SQL Server) correctly handle `@` in passwords.

---

### Problem 10 — SQL Server: DBeaver rejects self-signed TLS certificate

**Symptom:** DBeaver showed "The driver could not establish a secure connection to SQL Server by using Secure Sockets Layer (SSL) encryption. Error: PKIX path building failed" or similar certificate validation error.

**Root cause:** SQL Server 2022 on Linux generates a self-signed TLS certificate during installation. DBeaver's Microsoft JDBC driver validates TLS certificates by default — it rejects self-signed certificates because they are not issued by a trusted Certificate Authority (CA).

**Fix:** Enable `trustServerCertificate` in DBeaver's driver properties:

1. Create or edit the SQL Server connection in DBeaver
2. Click the **"Driver Properties"** tab
3. Set `trustServerCertificate` = `true`
4. Click Test Connection

This tells the JDBC driver to accept the server's certificate without CA validation — appropriate for a private homelab where the server identity is already established via Tailscale VPN.

---

### Problem 5 — taufiq.lab DNS not resolving in DBeaver (earlier session)

**Symptom:** DBeaver showed "Connection refused" when using hostname `linux-postgres.taufiq.lab`, even after fixing PostgreSQL config.

**Root cause:** Tailscale Split DNS had been configured on the Proxmox host, but Windows was not yet picking up the DNS rule. This can happen when:
- Tailscale client was not restarted after the Split DNS rule was added in the admin panel
- DNS cache had a stale negative entry

**Fix:**
```powershell
# Force Tailscale to re-pull DNS config
tailscale down && tailscale up

# Or flush Windows DNS cache
ipconfig /flushdns

# Verify
Resolve-DnsName linux-postgres.taufiq.lab
```

After this, hostname resolution worked and DBeaver connected successfully.

---

## 9. Troubleshooting

### DBeaver shows "Connection refused"

```
1. Is Tailscale running on the laptop?
   - Check system tray for Tailscale icon
   - Run: tailscale status

2. Is the target server online in the tailnet?
   - Run: tailscale status | grep linux-postgres
   - Should show "active" or an IP

3. Does the hostname resolve?
   - Run: Resolve-DnsName linux-postgres.taufiq.lab
   - If not: tailscale down && tailscale up, then ipconfig /flushdns

4. Is the DB port reachable?
   - Run: Test-NetConnection linux-postgres.taufiq.lab -Port 5432
   - Should show "TcpTestSucceeded: True"

5. Is the DB service running on the server?
   - SSH in and check: sudo systemctl status postgresql
```

### DBeaver shows "Access denied for user"

```
1. Check you are using the correct credentials:
   - postgres / qwertY@1612     (PostgreSQL superuser)
   - root / qwertY@1612         (MariaDB/MySQL root on VMs)
   - root / password            (MySQL root on msi local only)
   - workshop_2 / workshop_2    (application user, all servers)

2. For PostgreSQL — verify pg_hba.conf has the 0.0.0.0/0 line:
   - SSH in: sudo grep '0.0.0.0' /etc/postgresql/16/main/pg_hba.conf
   - Expected: host all all 0.0.0.0/0 md5

3. For MariaDB — verify the user exists:
   - SSH in: sudo mariadb -u root -p
   - SELECT user, host, plugin FROM mysql.user WHERE user='root';

4. For MySQL (linux-mysql) — verify remote user accounts exist:
   - SSH in: mysql -u root -p'qwertY@1612' -e "SELECT user, host FROM mysql.user WHERE user='root';"
   - Must have root@'%' row, not just root@'localhost'
   - If missing: CREATE USER 'root'@'%' IDENTIFIED BY 'qwertY@1612'; GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION;

5. For MySQL (linux-mysql) — verify bind-address:
   - SSH in: grep bind-address /etc/mysql/mysql.conf.d/mysqld.cnf
   - Must be 0.0.0.0, not 127.0.0.1
   - If wrong: sudo sed -i "s/127.0.0.1/0.0.0.0/" /etc/mysql/mysql.conf.d/mysqld.cnf && sudo systemctl restart mysql
```

### MariaDB fails to start after manual restart

```
Symptoms:
  - aria_log_control lock error
  - ibdata1 lock error
  - mariadb.service: Failed with result 'exit-code'

Cause: A manually started mariadbd is still running.

Fix:
  sudo ps aux | grep mariad
  sudo kill <PID of mariadbd-safe> <PID of mariadbd>
  sleep 3
  sudo systemctl start mariadb
```

### Oracle ORA-12514 after VM reboot

```
Symptom:
  ORA-12514: TNS:listener does not currently know of service
             requested in connect descriptor

Most likely cause A: PMON timing (first ~60 seconds after boot)
  PMON auto-registers services within 60 seconds of DB startup.
  Just wait and retry — no action needed.

Most likely cause B: local_listener misconfigured (deeper issue)
  The local_listener parameter is set to a TNS alias (e.g. LISTENER_FREE)
  but tnsnames.ora does not exist, so PMON cannot resolve the alias and
  never sends registration to the listener.

  Diagnose:
    sqlplus / as sysdba
    SHOW PARAMETER local_listener;
    -- If value is "LISTENER_FREE" (not an address), this is the cause.

  Permanent fix (already applied on this server):
    ALTER SYSTEM SET local_listener =
      '(ADDRESS=(PROTOCOL=TCP)(HOST=localhost)(PORT=1521))' SCOPE=BOTH;
    ALTER SYSTEM REGISTER;
    -- SCOPE=BOTH writes to spfile — survives reboots

  If the parameter was reset (e.g. after DB rebuild), reapply the fix.

Verify listener is ready:
  lsnrctl status | grep "Service"
  # Must show: Service "FREE" has 1 instance(s).
```

### Oracle ORA-12541 after VM reboot (listener not running)

```
Symptom:
  ORA-12541: TNS:no listener

Cause: The TNSLSNR process is not running. This can happen if the
       oracle-free-23ai systemd service did not fully start the listener.

Check:
  ssh linux-oracle-db@100.118.110.114
  su - root && su - oracle
  lsnrctl status  # should respond; if timeout: not running

Fix:
  # As oracle OS user:
  export ORACLE_HOME=/opt/oracle/product/23ai/dbhomeFree
  export PATH=$ORACLE_HOME/bin:$PATH
  lsnrctl start

  # Then force service registration:
  sqlplus / as sysdba
  SQL> ALTER SYSTEM REGISTER;
  SQL> EXIT;
```

### Oracle: ORA-01017 even with correct password

```
Symptom:
  ORA-01017: invalid username/password; logon denied

Most likely cause A: @ in password
  - Oracle treats @ as a connection string delimiter
  - Password qwertY@1612 is sent as qwertY (truncated)
  - Correct Oracle password is qwertY1612 (no @)

Most likely cause B: forgot to set Role = SYSDBA for sys user
  - sys user requires SYSDBA role
  - In DBeaver connection settings: Role dropdown → SYSDBA
  - Without it: ORA-28009 (sys must connect as sysdba/sysoper)
```

### SQL Server: certificate/SSL error in DBeaver

```
Symptom:
  "The driver could not establish a secure connection to SQL Server"
  "PKIX path building failed: sun.security.provider.certpath.SunCertPathBuilderException"

Cause: SQL Server uses a self-signed TLS certificate. DBeaver JDBC driver
       rejects it because it is not CA-signed.

Fix:
  In DBeaver connection editor → Driver Properties tab:
    trustServerCertificate = true

  Or in the Main tab look for:
    ☑ Trust server certificate  (tick the checkbox)
```

### SQL Server: access denied / login failed

```
Symptom:
  Login failed for user 'sa'. (Microsoft SQL Server, Error: 18456)

Check 1: SQL Server Authentication mode
  SQL Server must be in "Mixed mode" (SQL Server + Windows auth).
  On Linux, this is the default when SA password is set during install.

Check 2: SA account enabled
  ssh root@100.117.38.113
  /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P 'qwertY@1612' \
    -Q "SELECT name, is_disabled FROM sys.sql_logins WHERE name='sa';"
  # is_disabled must be 0

  If disabled:
  /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P 'qwertY@1612' \
    -Q "ALTER LOGIN sa ENABLE;"
```

### DBeaver driver download fails

```
DBeaver downloads JDBC drivers from Maven Central on first use.
If behind a proxy or firewall, manual installation is needed.

Driver locations:
  PostgreSQL JDBC: https://jdbc.postgresql.org/download/
  MySQL JDBC:      https://dev.mysql.com/downloads/connector/j/
  MariaDB JDBC:    https://mariadb.com/kb/en/about-mariadb-connector-j/

Install: DBeaver → Driver Manager → Edit driver → Add jar file
```

---

## 10. Connection Summary Card

Quick reference for setting up all connections in DBeaver.

```
+==============================================================================+
|                    DBEAVER HOMELAB CONNECTIONS — QUICK CARD                  |
+==============================================================================+
|                                                                              |
|  PREREQUISITE: Tailscale running + hosts file has taufiq.lab entries         |
|  Both the DNS hostname AND raw Tailscale IP work for all connections.         |
|                                                                              |
+-------------------+-----------------------------+---------------------------+
|  PostgreSQL                                                                  |
+-------------------+-----------------------------+---------------------------+
|  Host (DNS)       |  linux-postgres.taufiq.lab  |  or: postgres.taufiq.lab |
|  Host (IP)        |  100.113.234.24             |                          |
|  Port             |  5432                       |  Database: postgres       |
|  Admin user/pass  |  postgres / qwertY@1612     |          (or workshop_2) |
|  App user/pass    |  workshop_2 / workshop_2    |                          |
|  SSH Tunnel       |  OFF                        |                          |
+-------------------+-----------------------------+---------------------------+
|  MariaDB (linux-mariadb / workshop-2)                                        |
+-------------------+-----------------------------+---------------------------+
|  Host (DNS)       |  linux-mariadb.taufiq.lab   |  or: mariadb.taufiq.lab  |
|  Host (IP)        |  100.78.124.25              |                          |
|  Port             |  3306                       |  Database: workshop_2    |
|  Admin user/pass  |  root / qwertY@1612         |                          |
|  App user/pass    |  workshop_2 / workshop_2    |                          |
|  SSH Tunnel       |  OFF                        |                          |
+-------------------+-----------------------------+---------------------------+
|  MySQL (linux-mysql Proxmox VM)                                              |
+-------------------+-----------------------------+---------------------------+
|  Host (DNS)       |  linux-mysql.taufiq.lab     |  or: mysql.taufiq.lab    |
|  Host (IP)        |  100.115.237.93             |                          |
|  Port             |  3306                       |  Database: workshop_2    |
|  Admin user/pass  |  root / qwertY@1612         |                          |
|  App user/pass    |  workshop_2 / workshop_2    |                          |
|  SSH Tunnel       |  OFF                        |                          |
+-------------------+-----------------------------+---------------------------+
|  Oracle 23ai Free (linux-oracle-db)                                          |
+-------------------+-----------------------------+---------------------------+
|  Host (DNS)       |  linux-oracle-db.taufiq.lab |  or: oracle.taufiq.lab   |
|  Host (IP)        |  100.118.110.114            |                          |
|  Port             |  1521                       |  Service: FREE or        |
|  Admin user/pass  |  sys / qwertY1612 (SYSDBA)  |          FREEPDB1        |
|  App user/pass    |  laravel_app / <password>   |  NOTE: no @ in password! |
|  SSH Tunnel       |  OFF                        |                          |
+-------------------+-----------------------------+---------------------------+
|  SQL Server 2022 (linux-sql-server)                                          |
+-------------------+-----------------------------+---------------------------+
|  Host (DNS)       |  linux-sql-server.taufiq.lab|  or: mssql.taufiq.lab    |
|  Host (IP)        |  100.117.38.113             |                          |
|  Port             |  1433                       |  Database: master        |
|  Admin user/pass  |  sa / qwertY@1612           |  Trust cert: ON          |
|  SSH Tunnel       |  OFF                        |                          |
+-------------------+-----------------------------+---------------------------+
|  MySQL (msi local)                                                           |
+-------------------+-----------------------------+---------------------------+
|  Host             |  localhost                  |                          |
|  Port             |  3306                       |  Database: workshop_2    |
|  Admin user/pass  |  root / password            |  ← different pwd!        |
|  App user/pass    |  workshop_2 / workshop_2    |                          |
|  SSH Tunnel       |  OFF                        |                          |
+-------------------+-----------------------------+---------------------------+

  All VM admin passwords : qwertY@1612  (except Oracle: qwertY1612, msi: password)
  Application user       : workshop_2 / workshop_2  (all servers)
  Oracle note            : @ is illegal in Oracle passwords — use qwertY1612

  Related docs:
    homelab-dns-setup-taufiq-lab.md   — full DNS infrastructure setup
    ../Animal-Shelter-Workshop/CLAUDE.md — DB connection mapping per module
    ../Animal-Shelter-Workshop/README.md — DB architecture overview

+==============================================================================+
```

---

*Documentation generated: 2 July 2026*
*Environment: DBeaver on MSI Windows 11 → Tailscale VPN → Proxmox homelab VMs*
*DNS: dnsmasq on Proxmox 100.97.8.93, domain taufiq.lab*
