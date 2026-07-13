# Spring Boot App Server Setup
**Server:** `spring-boot-app` (Ubuntu 24.04.4 LTS — corrected 2026-07-14; previously documented as 22.04)
**IP:** `100.120.243.96` Tailscale (stable — use this one) / `192.168.0.105` local LAN (DHCP, **not static**
— confirmed via `hostname -I` on 2026-07-14, will drift on reboot and can collide with other VMs' DHCP
leases). Corrected 2026-07-14: this VM is a distinct Tailscale node named `spring-boot-app`, separate from
the `linux-app-server` / VM101 entry in [`docs/02-dns/dns-setup.md`](../02-dns/dns-setup.md) (that entry's
`192.168.0.102` / `100.100.123.90` is a different, currently-offline VM). The `192.168.0.101` previously
listed here was never reachable and appears to have been a typo. Always use the Tailscale IP for this VM.
**Purpose:** "Prod"-only host for the Green Lifestyle Market (GLM) Spring Boot app, with Oracle DB backend

> **Scope note:** GLM is a learning/portfolio project — nobody actually uses this app.
> "Prod" here just means "the one deployed, always-on copy," not a real production system with
> real users or uptime stakes. The dev/prod schema split, Flashback Archive, and the rest of the
> hardening in this doc are done for the DBA/ops practice, not because a real outage would hurt
> anyone. See [`docs/01-oracle/glm-db-access.md`](../01-oracle/glm-db-access.md) for the DB side
> of the same distinction.

## Why This Exists

The plan for this server is to remake an old PHP plus MySQL project as
Spring Boot plus Oracle, mainly as an experiment to compare performance
between the two stacks. This server hosts the rewritten app — [Green Lifestyle
Market](https://github.com/) (`green-lifestyle-market` repo) — and the
`linux-oracle-db` VM documented in
[`docs/01-oracle/oracle-install.md`](../01-oracle/oracle-install.md) is
the database backend it connects to.

**2026-07-14 update — dev/prod split retired.** This VM now hosts **prod only**.
Local development happens on the primary workstation (`.env` + `mvn spring-boot:run`
against the same Oracle DB, isolated by schema); nothing dev-related runs on this VM
anymore. See [Prod-Only Deployment (GLM)](#prod-only-deployment-glm-2026-07-14) below
for what changed and why.

---

## What's Installed

| Component | Version | Notes |
|---|---|---|
| Java | 21 (OpenJDK) | Upgraded 2026-07-14 from 17 — GLM's `pom.xml` pins `java.version=21` (virtual threads, records). Installed alongside 17 via `apt`, then made default with `update-alternatives --set java/javac`. |
| Nginx | 1.24.0 | Added 2026-07-14 — serves the GLM SPA build and reverse-proxies `/api` + `/ws` to Spring Boot. GLM's `deploy/nginx.conf` assumes this; it wasn't installed before. |
| Maven | system default | Build tool |
| Git | system default | Pull code from GitHub |
| ojdbc11 | 23.3.0 | Oracle JDBC driver, installed to Maven local repo |
| cloudflared | 2026.6.1 | Named Cloudflare Tunnel for permanent public access (prod tunnel only, see below) |
| tmux | system default | Keep processes alive after SSH disconnect |

---

## Prod-Only Deployment (GLM) — 2026-07-14

**Decision:** keep dev entirely off this VM. Development for `green-lifestyle-market`
happens on the primary workstation (`mvn spring-boot:run -Dspring-boot.run.profiles=dev`
against a dev schema on the same Oracle DB). This VM runs **prod only**. Rationale: the
VM's only job is to be the hosting target, so running two competing profiles on it
added operational surface (two systemd units, two tunnels, two log sets) with no benefit
— nobody was actually developing against the VM's `dev` instance.

**What changed on this VM as a result:**

1. **Java 17 → 21** (see table above) — required by GLM's `pom.xml`.
2. **`springapp-dev.service` and `cloudflared-dev.service` disabled and stopped**
   (`systemctl disable --now`). Left in place (not deleted) in case dev hosting is
   ever needed here again — just not auto-starting.
3. **Nginx installed**, serving GLM's built SPA and reverse-proxying to the prod
   Spring Boot instance. Config lives at `/etc/nginx/sites-available/glm-prod`
   (symlinked into `sites-enabled`; the default nginx site was removed). It's a
   copy of the repo's `deploy/nginx.conf` with the proxy targets changed from
   `8080` (dev) to **`8081`** (prod, the only profile running here now):
   - `location /api/` → `proxy_pass http://127.0.0.1:8081;`
   - `location /ws/` → same, with WebSocket upgrade headers
   - `root /var/glm/frontend/dist;` — SPA static files
   - `location /media/` → alias `/var/glm/uploads/` (matches `UPLOAD_DIR` in `docs/environment.md`)
   - `/actuator/` blocked except `/actuator/health`, per the repo's own note to
     never expose actuator endpoints publicly
4. **`/var/glm/frontend/dist` and `/var/glm/uploads` created**, owned by `springapp`,
   for nginx to serve from. Empty for now — no frontend build has been deployed yet
   (see Outstanding below).
5. **Cloudflare prod tunnel (`bf9aa8be-...`) re-pointed from `http://localhost:8081`
   directly to `http://localhost:80`** (nginx), so public traffic goes
   `Cloudflare edge → tunnel → nginx → (static SPA, or proxy to 8081 for /api and /ws)`
   instead of hitting the Spring Boot process directly and bypassing static file
   serving entirely. Config: `~/.cloudflared/prod.yml` on the VM.
6. UFW was left untouched (SSH only, inbound) — nginx on port 80 doesn't need a
   firewall rule opened because the tunnel connects to it over loopback, not
   over the LAN/WAN.

**Outstanding — not done, needs a decision from the repo owner before prod actually serves traffic:**

- **No code has been cloned/built on this VM yet.** `/opt/springapp/prod` and
  `/var/glm/frontend/dist` are both empty. The backend has substantial code already
  (contradicts the `green-lifestyle-market` README's "Implementation not started" —
  that line is stale) but deploying it needs a git clone, a `mvn package`, a frontend
  `vite build` copied into `/var/glm/frontend/dist`, and a real `application-prod.properties`
  / prod env file with secrets (ToyyibPay keys, VAPID keys, mail creds) that weren't
  provided as part of this infra pass.
- **`glm_app`'s current DB password is unknown.** The schema (`docs/01-oracle/oracle-install.md`
  / `deploy/oracle-provision.sql`) is already provisioned on the Oracle VM — verified
  2026-07-14: `GLM_APP` exists, is `OPEN`, has exactly the grants `oracle-provision.sql`
  asks for (CREATE SESSION/TABLE/SEQUENCE/PROCEDURE/TRIGGER/VIEW, `CTXAPP` role,
  `FLASHBACK ARCHIVE ADMINISTER`), and already owns 44 tables — meaning Flyway has
  already migrated it from somewhere. Its password is **not** the placeholder in
  `oracle-provision.sql` (`ChangeMe_Strong1!` — confirmed rejected), so it was rotated
  at some point and that password isn't recorded in this repo. A prod env file can't
  be created for `springapp-prod.env` until either that password is supplied or it's
  reset (`ALTER USER glm_app IDENTIFIED BY ...`) — the latter is a live credential
  rotation, so it needs sign-off first rather than being done unilaterally.
- **`docs/environment.md` in the GLM repo has a service-name inconsistency**: its
  example `DB_URL` uses `.../FREE` (the CDB root), while `backend/pom.xml`'s
  integration-test config and this VM's own working connection both use `.../FREEPDB1`
  (the actual pluggable DB — confirmed reachable and correct via `v$pdbs`). Any prod
  `DB_URL` here should use `FREEPDB1`, not `FREE`.
- **Security note, unrelated to this VM but found during this pass:** GLM's local dev
  `backend/.env` (on the primary workstation) authenticates as `sys`/`sysdba` with a
  plaintext password, and the same password is hardcoded in `backend/pom.xml`
  (`IT_DB_SYS_PASS`) and committed to the repo. That's a live SYS credential in version
  control — worth rotating and moving to a secret store regardless of this deployment.

---

## Directory Structure

```
/opt/springapp/
├── dev/                        <- development environment (unused as of 2026-07-14 — dev is not hosted on this VM)
├── prod/                       <- production environment (port 8081) — empty, code not yet deployed
└── setup-oracle-jdbc.sh        <- re-run this if server is reprovisioned

/var/glm/                        <- added 2026-07-14 for nginx
├── frontend/dist/              <- SPA static build (nginx docroot) — empty, no build deployed yet
└── uploads/                    <- UPLOAD_DIR, served via nginx /media/ alias

/etc/nginx/
├── sites-available/glm-prod    <- added 2026-07-14, adapted from deploy/nginx.conf (proxies to :8081)
└── sites-enabled/glm-prod      <- symlink; default site removed

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

| Environment | URL | Ingress target |
|---|---|---|
| DEV | `https://6a9cf731-a20d-496c-b6e9-a42f5d23f24d.cfargotunnel.com` | disabled 2026-07-14 — service stopped, tunnel not running |
| PROD | `https://bf9aa8be-4ab6-4028-ad63-bfd5e25aff00.cfargotunnel.com` | `http://localhost:80` (nginx) — changed 2026-07-14, was `:8081` direct |

Tunnels are managed by systemd and auto-start on boot:
```bash
sudo systemctl status cloudflared-prod   # dev tunnel is disabled, see Prod-Only Deployment above
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
ssh spring-boot-app@100.120.243.96   # Tailscale IP — corrected 2026-07-14, see header
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
sudo apt update && sudo apt install -y openjdk-21-jdk maven git tmux nginx
sudo update-alternatives --set java /usr/lib/jvm/java-21-openjdk-amd64/bin/java
sudo update-alternatives --set javac /usr/lib/jvm/java-21-openjdk-amd64/bin/javac
# Deploy /etc/nginx/sites-available/glm-prod (see deploy/nginx.conf in the app repo,
# proxy targets pointed at :8081) and symlink into sites-enabled; remove default site.

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
| SSH into server | `ssh spring-boot-app@100.120.243.96   # Tailscale IP — corrected 2026-07-14, see header` |
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
