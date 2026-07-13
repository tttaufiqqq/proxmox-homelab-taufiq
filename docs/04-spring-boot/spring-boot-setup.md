# Spring Boot App Server Setup
**Server:** `spring-boot-app` (Ubuntu 22.04)
**IP:** `192.168.0.101`
**Purpose:** Development and production host for Spring Boot app with Oracle DB backend

## Why This Exists

The plan for this server is to remake an old PHP plus MySQL project as
Spring Boot plus Oracle, mainly as an experiment to compare performance
between the two stacks. This server hosts the rewritten app, and the
`linux-oracle-db` VM documented in
[`docs/01-oracle/oracle-install.md`](../01-oracle/oracle-install.md) is
the database backend it connects to.

---

## What's Installed

| Component | Version | Notes |
|---|---|---|
| Java | 17 (OpenJDK) | Runtime for Spring Boot |
| Maven | system default | Build tool |
| Git | system default | Pull code from GitHub |
| ojdbc11 | 23.3.0 | Oracle JDBC driver, installed to Maven local repo |
| cloudflared | 2026.6.1 | Named Cloudflare Tunnel for permanent public access |
| tmux | system default | Keep processes alive after SSH disconnect |

---

## Directory Structure

```
/opt/springapp/
├── dev/                        <- development environment (port 8080)
├── prod/                       <- production environment (port 8081)
└── setup-oracle-jdbc.sh        <- re-run this if server is reprovisioned

/var/log/springapp/
├── dev.log
├── dev-error.log
├── prod.log
├── prod-error.log
├── tunnel-dev.log
└── tunnel-prod.log

/etc/
├── springapp-dev.env           <- DB credentials for dev (chmod 600)
└── springapp-prod.env          <- DB credentials for prod (chmod 600)

/etc/systemd/system/
├── springapp-dev.service       <- Spring Boot DEV (port 8080)
├── springapp-prod.service      <- Spring Boot PROD (port 8081)
├── cloudflared-dev.service     <- Tunnel for DEV (auto-start on boot)
└── cloudflared-prod.service    <- Tunnel for PROD (auto-start on boot)

~/.cloudflared/
├── cert.pem                    <- Cloudflare account certificate
├── dev.yml                     <- Named tunnel config for DEV
├── prod.yml                    <- Named tunnel config for PROD
├── 6a9cf731-...json            <- DEV tunnel credentials (keep secret)
└── bf9aa8be-...json            <- PROD tunnel credentials (keep secret)

~/.m2/repository/com/oracle/database/jdbc/ojdbc11/23.3.0/
└── ojdbc11-23.3.0.jar          <- Oracle JDBC driver
```

---

## Users

| User | Purpose |
|---|---|
| `spring-boot-app` | main login user (your SSH user) |
| `springapp` | dedicated app user that owns `/opt/springapp` |

---

## Permanent Tunnel URLs

Named tunnels — these never change regardless of VM restarts.

| Environment | URL | Port |
|---|---|---|
| DEV | `https://6a9cf731-a20d-496c-b6e9-a42f5d23f24d.cfargotunnel.com` | 8080 |
| PROD | `https://bf9aa8be-4ab6-4028-ad63-bfd5e25aff00.cfargotunnel.com` | 8081 |

Tunnels are managed by systemd and auto-start on boot:
```bash
sudo systemctl status cloudflared-dev
sudo systemctl status cloudflared-prod
```

---

## Security

### Firewall (UFW)
Only SSH (port 22) is open inbound. App ports 8080 and 8081 are intentionally blocked — all public traffic goes through Cloudflare Tunnel only.

```bash
sudo ufw status verbose
```

### Secrets Management
DB credentials are stored in env files, not in the codebase. The systemd services load them via `EnvironmentFile`.

```
/etc/springapp-dev.env   (chmod 600 — root read only)
/etc/springapp-prod.env  (chmod 600 — root read only)
```

Both `application-dev.properties` and `application-prod.properties` are in `.gitignore` and must never be committed to GitHub.

---

## Environment Setup

### Dev vs Prod Profiles

Create these files inside your project under `src/main/resources/`:

**`application-dev.properties`**
```properties
server.port=8080
spring.datasource.url=${DB_URL}
spring.datasource.username=${DB_USERNAME}
spring.datasource.password=${DB_PASSWORD}
spring.datasource.driver-class-name=oracle.jdbc.OracleDriver
spring.jpa.database-platform=org.hibernate.dialect.OracleDialect
spring.jpa.hibernate.ddl-auto=update
spring.jpa.show-sql=true
```

**`application-prod.properties`**
```properties
server.port=8081
spring.datasource.url=${DB_URL}
spring.datasource.username=${DB_USERNAME}
spring.datasource.password=${DB_PASSWORD}
spring.datasource.driver-class-name=oracle.jdbc.OracleDriver
spring.jpa.database-platform=org.hibernate.dialect.OracleDialect
spring.jpa.hibernate.ddl-auto=validate
spring.jpa.show-sql=false
```

Key differences:

| Setting | Dev | Prod |
|---|---|---|
| Port | 8080 | 8081 |
| DB user | `app_dev` | `app_prod` |
| `ddl-auto` | `update` (auto-migrate schema) | `validate` (safe, no changes) |
| `show-sql` | `true` | `false` |

Add to `.gitignore` in your project:
```bash
echo "src/main/resources/application-dev.properties" >> .gitignore
echo "src/main/resources/application-prod.properties" >> .gitignore
echo "src/main/resources/application.properties" >> .gitignore
```

### pom.xml — Oracle Dependency

```xml
<dependency>
    <groupId>com.oracle.database.jdbc</groupId>
    <artifactId>ojdbc11</artifactId>
    <version>23.3.0</version>
</dependency>
```

---

## Log Rotation

Logs under `/var/log/springapp/` rotate daily, keep 7 days, and compress old files automatically via `/etc/logrotate.d/springapp`.

To manually trigger rotation:
```bash
sudo logrotate --force /etc/logrotate.d/springapp
```

---

## Day-to-Day Workflow

### SSH in from your laptop

```bash
ssh spring-boot-app@192.168.0.101
```

### First-time clone (once code is ready)

```bash
sudo -u springapp git clone https://github.com/YOUR_REPO_URL /opt/springapp/dev
sudo -u springapp git clone https://github.com/YOUR_REPO_URL /opt/springapp/prod
sudo chown -R springapp:springapp /opt/springapp/
```

Then add the properties files (these are gitignored — create them manually on the server):
```bash
sudo nano /opt/springapp/dev/src/main/resources/application-dev.properties
sudo nano /opt/springapp/prod/src/main/resources/application-prod.properties
```

Then enable and start the app services:
```bash
sudo systemctl enable springapp-dev springapp-prod
sudo systemctl start springapp-dev springapp-prod
```

### Pull latest code and restart

```bash
# Dev
cd /opt/springapp/dev
git pull origin main
sudo systemctl restart springapp-dev

# Prod
cd /opt/springapp/prod
git pull origin main
sudo systemctl restart springapp-prod
```

### Check app logs

```bash
tail -f /var/log/springapp/dev.log
tail -f /var/log/springapp/prod.log
```

### Check service status

```bash
sudo systemctl status springapp-dev --no-pager
sudo systemctl status springapp-prod --no-pager
sudo systemctl status cloudflared-dev --no-pager
sudo systemctl status cloudflared-prod --no-pager
```

### Manual run (for debugging, outside systemd)

```bash
# Open a tmux session first so it survives SSH disconnect
tmux new -s dev
cd /opt/springapp/dev
mvn spring-boot:run -Dspring-boot.run.profiles=dev
# Ctrl+B then D to detach

tmux new -s prod
cd /opt/springapp/prod
mvn spring-boot:run -Dspring-boot.run.profiles=prod
# Ctrl+B then D to detach
```

Reattach:
```bash
tmux attach -t dev
tmux attach -t prod
tmux ls
```

---

## Oracle DB Connectivity Check

Before running the app, verify the Oracle Linux VM (`linux-oracle-db`, see
[`docs/01-oracle/oracle-install.md`](../01-oracle/oracle-install.md)) is
reachable on port 1521:

```bash
nc -zv linux-oracle-db.taufiq.lab 1521
```

If it times out, run this on the Oracle Linux VM:

```bash
sudo firewall-cmd --permanent --add-port=1521/tcp
sudo firewall-cmd --reload
```

### Oracle Schemas (run on Oracle Linux VM)

Separate schemas for dev and prod prevent a bad dev migration from affecting prod data:

```sql
-- Connect as sysdba
sqlplus / as sysdba

CREATE USER app_dev IDENTIFIED BY your_dev_password;
GRANT CONNECT, RESOURCE TO app_dev;
GRANT UNLIMITED TABLESPACE TO app_dev;

CREATE USER app_prod IDENTIFIED BY your_prod_password;
GRANT CONNECT, RESOURCE TO app_prod;
GRANT UNLIMITED TABLESPACE TO app_prod;

EXIT;
```

---

## Reprovisioning (if server is rebuilt)

Run these in order:

```bash
# 1. Install dependencies
sudo apt update && sudo apt install -y openjdk-17-jdk maven git tmux

# 2. Install cloudflared
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
sudo dpkg -i cloudflared.deb

# 3. Reinstall ojdbc11
bash /opt/springapp/setup-oracle-jdbc.sh

# 4. Restore Cloudflare tunnel credentials from backup
# (copy cert.pem and both .json credential files back to ~/.cloudflared/)

# 5. Recreate env files
sudo nano /etc/springapp-dev.env
sudo nano /etc/springapp-prod.env
sudo chmod 600 /etc/springapp-dev.env /etc/springapp-prod.env

# 6. Restore systemd services and reload
sudo systemctl daemon-reload
sudo systemctl enable springapp-dev springapp-prod cloudflared-dev cloudflared-prod
sudo systemctl start cloudflared-dev cloudflared-prod
```

---

## Quick Reference

| Task | Command |
|---|---|
| SSH into server | `ssh spring-boot-app@192.168.0.101` |
| Pull latest (dev) | `cd /opt/springapp/dev && git pull origin main` |
| Pull latest (prod) | `cd /opt/springapp/prod && git pull origin main` |
| Restart dev app | `sudo systemctl restart springapp-dev` |
| Restart prod app | `sudo systemctl restart springapp-prod` |
| Watch dev logs | `tail -f /var/log/springapp/dev.log` |
| Watch prod logs | `tail -f /var/log/springapp/prod.log` |
| Check all services | `sudo systemctl status springapp-dev springapp-prod cloudflared-dev cloudflared-prod` |
| Check firewall | `sudo ufw status verbose` |
| List tunnels | `cloudflared tunnel list` |
| Check Oracle connectivity | `nc -zv linux-oracle-db.taufiq.lab 1521` (or `100.118.110.114`) |
| Reinstall ojdbc11 | `bash /opt/springapp/setup-oracle-jdbc.sh` |

---

## Notes

- `mvn spring-boot:run` requires a valid `pom.xml` with the Spring Boot plugin in the project directory. Running it outside a Spring Boot project throws `No plugin found for prefix 'spring-boot'`.
- The ojdbc11 jar is not on Maven Central. It was manually downloaded from Oracle and installed into the local Maven repo. Use `setup-oracle-jdbc.sh` to reinstall if needed.
- Named Cloudflare tunnels are permanent — URLs do not change on restart. Managed by systemd, they auto-start on boot.
- Both `dev` and `prod` connect to the same Oracle DB VM but use separate Oracle schemas (`app_dev` / `app_prod`) to isolate data.
- Do not commit `application-dev.properties` or `application-prod.properties` to GitHub. They are gitignored and must be created manually on the server.

---

## Related Docs

- [`docs/01-oracle/oracle-install.md`](../01-oracle/oracle-install.md): how the Oracle backend this app connects to was built
- [`docs/02-dns/dns-setup.md`](../02-dns/dns-setup.md): where `linux-oracle-db.taufiq.lab` and other lab hostnames come from
