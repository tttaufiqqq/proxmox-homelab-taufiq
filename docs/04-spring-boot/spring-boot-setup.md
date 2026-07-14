# Spring Boot App Server Setup
**Server:** `spring-boot-app`, VM ID `103` (Ubuntu 24.04.4 LTS — corrected 2026-07-14; previously documented as 22.04)
**IP:** `100.120.243.96` Tailscale (stable — use this one) / `192.168.0.105` local LAN (DHCP, **not static**
— confirmed via `hostname -I` on 2026-07-14, will drift on reboot and can collide with other VMs' DHCP
leases). Corrected 2026-07-14: this VM is a distinct Tailscale node named `spring-boot-app`, separate from
the `linux-app-server` / VM101 entry in [`docs/02-dns/dns-setup.md`](../02-dns/dns-setup.md) (that entry's
`192.168.0.102` / `100.100.123.90` is a different, currently-offline VM). The `192.168.0.101` previously
listed here was never reachable and appears to have been a typo. Always use the Tailscale IP for this VM.
**Purpose:** Sole host for the live Green Lifestyle Market (GLM) Spring Boot app, with Oracle DB backend.

> **Scope note:** GLM is a learning/portfolio project — nobody actually uses this app. The
> hardening in this doc (schema isolation, Flashback Archive, credential hygiene) is done for
> the DBA/ops practice, not because a real outage would hurt anyone. See
> [`docs/01-oracle/glm-db-access.md`](../01-oracle/glm-db-access.md) for the DB side.

## Why This Exists

The plan for this server is to remake an old PHP plus MySQL project as
Spring Boot plus Oracle, mainly as an experiment to compare performance
between the two stacks. This server hosts the rewritten app —
[`green-lifestyle-market`](https://github.com/tttaufiqqq/green-lifestyle-market) — and the
`linux-oracle-db` VM documented in
[`docs/01-oracle/oracle-install.md`](../01-oracle/oracle-install.md) is
the database backend it connects to.

---

## What's Installed

| Component | Version | Notes |
|---|---|---|
| Java | 21 (OpenJDK) | Upgraded 2026-07-14 from 17 — GLM's `pom.xml` pins `java.version=21` (virtual threads, records). Installed alongside 17 via `apt`, then made default with `update-alternatives --set java/javac`. |
| Nginx | 1.24.0 | Added 2026-07-14 — serves the GLM SPA build and reverse-proxies `/api` + `/ws` to Spring Boot. GLM's `deploy/nginx.conf` assumes this; it wasn't installed before. |
| Maven | system default | Build tool |
| Git | system default | Pull code from GitHub |
| ojdbc11 | 23.3.0 | Oracle JDBC driver, installed to Maven local repo |
| cloudflared | 2026.6.1 | Named Cloudflare Tunnel for permanent public access |
| tmux | system default | Keep processes alive after SSH disconnect |

---

## Deployment — 2026-07-14

This VM runs one thing: `green-lifestyle-market`, listening on `8081`, fronted by nginx
on port 80, exposed publicly via a named Cloudflare Tunnel.

1. **Java 21**, **nginx** installed (see table above).
2. **Nginx** serves GLM's built SPA and reverse-proxies to Spring Boot. Config at
   `/etc/nginx/sites-available/glm-prod` (symlinked into `sites-enabled`; the default
   nginx site was removed). Adapted from the repo's `deploy/nginx.conf`:
   - `location /api/` → `proxy_pass http://127.0.0.1:8081;`
   - `location /ws/` → same, with WebSocket upgrade headers
   - `root /var/glm/frontend/dist;` — SPA static files
   - `location /media/` → alias `/var/glm/uploads/` (matches `UPLOAD_DIR` in `docs/environment.md`)
   - `/actuator/` blocked except `/actuator/health`, per the repo's own note to
     never expose actuator endpoints publicly
3. **`/var/glm/frontend/dist` and `/var/glm/uploads`** created, owned by `springapp`,
   holding the built frontend.
4. **Cloudflare Tunnel (`bf9aa8be-...`) points at `http://localhost:80`** (nginx), so
   public traffic goes `Cloudflare edge → tunnel → nginx → (static SPA, or proxy to
   8081 for /api and /ws)`. Config: `~/.cloudflared/prod.yml` on the VM. DNS-routed to
   the custom domain `glm.tttaufiqqq.com` via `cloudflared tunnel route dns` — both
   that and the raw `bf9aa8be-...cfargotunnel.com` URL resolve to this tunnel.
5. UFW: SSH only, inbound. Nginx on port 80 needs no firewall rule opened — the tunnel
   connects to it over loopback, not the LAN/WAN.

**GLM is live: https://glm.tttaufiqqq.com** — verified `200` on `/` and `/api/v1/products`.
`springapp-prod.service` is `active (running)`.

**What it took to get from "infra ready" to "actually serving traffic"** — six real
bugs, found by just trying to boot the app for the first time against a real Oracle
backend:

1. **`V6`'s Flashback Archive name collision** (`glm_fda` hardcoded, unique per PDB
   not per-schema) was fixed via a Flyway placeholder, but editing an already-applied
   migration changed its checksum. The schema history table still had the old
   checksum, so `Validate failed: Migrations have failed validation` blocked every
   boot until a one-time `flyway repair` (run via a small standalone Java class using
   the project's own `flyway-core` dependency, since no `flyway` CLI is installed)
   realigned it.
2. **Spring Session JDBC tables never existed.** `application-prod.yml` had a comment
   claiming they were Flyway-managed; no migration actually created them. Added
   `V8__spring_session.sql`, copied verbatim from `spring-session-jdbc:3.3.3`'s own
   bundled `schema-oracle.sql`.
3. **`springapp-prod.service` was missing `EnvironmentFile=`** entirely (so
   `/etc/springapp-prod.env` was never actually loaded) **and had the wrong
   `WorkingDirectory`** (`/opt/springapp/prod` instead of `/opt/springapp/prod/backend`,
   where `pom.xml` actually lives — would have failed with "No plugin found for prefix
   'spring-boot'"). Both were bugs in the unit file from before this deployment existed.
4. **`NotificationRepository.markAllReadForUser`'s JPQL used `CURRENT_TIMESTAMP`**
   against an `Instant`-typed field; Hibernate 6.5's stricter query validator rejects
   the implicit `java.sql.Timestamp` → `Instant` assignment at repository-bean-creation
   time — meaning the *entire app* failed to boot over one query method, not just that
   endpoint. Never caught by the project's unit tests, since H2 is more lenient than
   real Oracle-dialect validation. Fixed by passing `Instant.now()` from Java instead.
5. **`webpush`'s `PushService` needs a `JwtFactory` implementation for VAPID signing**;
   `pom.xml` declared neither. First attempt added raw `jose4j` (wrong — `webpush`
   needs its own glue module); fixed with `dev.blanke.webpush.jwt:webpush-jwt-jose4j`,
   which pulls `jose4j` transitively. Real VAPID keys were generated with
   `npx web-push generate-vapid-keys` (blank/placeholder keys are **not** an option —
   `PushService.Builder.withVapidPublicKey` decodes and validates the key eagerly in
   `NotificationPublisher`'s constructor, so a bad key crashes startup, not just push).
6. **`application-prod.yml` never actually set `server.port: 8081`** despite nginx,
   the tunnel, UFW notes, and this doc all assuming it — the app silently ran on the
   base default `8080`. `curl` to `8081` was connection-refused until this was added.

**Frontend deploy:** `npm run build` locally, `scp` the `dist/` output to the VM,
`rsync` into `/var/glm/frontend/dist`. One gotcha: `rsync -a` preserved the source
directory's restrictive `700` permissions, which `nginx` (running as its own user)
couldn't read — fixed with `chmod 755` on dirs / `644` on files after the copy.

**Still genuinely open, by choice, not oversight:** ToyyibPay and mail secrets are
still blank — confirmed safe (no eager validation at startup, see the code audit
above), so payment and email flows simply won't work until real sandbox
credentials are supplied. Not needed for a no-real-users learning deployment.

**Found but not resolved — a data question, not a bug:** running the Flyway repair
above surfaced a stale seed-data migration entry in the schema history that had to
be marked deleted (its migration script isn't on this VM's classpath). That implies
this app's Oracle schema — the one with 44 tables discovered pre-existing at the
start of this whole session — may have had test/seed data loaded into it at some
point before this VM became the sole live deployment target. Nothing was deleted or
altered; flagged here for the repo owner to check the data itself if it matters
(e.g. `SELECT * FROM users WHERE email LIKE '%@glm.dev'`).

---

## Directory Structure

```
/opt/springapp/
├── prod/                        <- the running deployment (port 8081)
└── setup-oracle-jdbc.sh         <- re-run this if server is reprovisioned

/var/glm/                        <- added 2026-07-14 for nginx
├── frontend/dist/               <- SPA static build (nginx docroot)
└── uploads/                     <- UPLOAD_DIR, served via nginx /media/ alias

/etc/nginx/
├── sites-available/glm-prod     <- added 2026-07-14, adapted from deploy/nginx.conf (proxies to :8081)
└── sites-enabled/glm-prod       <- symlink; default site removed

/var/log/springapp/
├── prod.log
└── prod-error.log

/etc/
└── springapp-prod.env           <- DB credentials and app secrets (chmod 600)

/etc/systemd/system/
├── springapp-prod.service       <- the app (port 8081)
└── cloudflared-prod.service     <- the tunnel (auto-start on boot)

~/.cloudflared/
├── cert.pem                     <- Cloudflare account certificate
├── prod.yml                     <- Named tunnel config (points at nginx :80)
└── bf9aa8be-...json             <- Tunnel credentials (keep secret)

~/.m2/repository/com/oracle/database/jdbc/ojdbc11/23.3.0/
└── ojdbc11-23.3.0.jar           <- Oracle JDBC driver
```

---

## Users

| User | Purpose |
|---|---|
| `spring-boot-app` | main login user (your SSH user) |
| `springapp` | dedicated app user that owns `/opt/springapp` |

---

## Permanent Tunnel URL

Named tunnel — never changes regardless of VM restarts.

| URL | Ingress target |
|---|---|
| `https://bf9aa8be-4ab6-4028-ad63-bfd5e25aff00.cfargotunnel.com` **and** `https://glm.tttaufiqqq.com` (custom domain, DNS-routed 2026-07-14 via `cloudflared tunnel route dns` — both resolve to the same tunnel) | `http://localhost:80` (nginx) |

Managed by systemd, auto-starts on boot:
```bash
sudo systemctl status cloudflared-prod
```

---

## Security

### Firewall (UFW)
Only SSH (port 22) is open inbound. Port 8081 (the Spring Boot port) is intentionally blocked — all public traffic goes through Cloudflare Tunnel → nginx only.

```bash
sudo ufw status verbose
```

### Secrets Management
DB credentials and app secrets are stored in an env file, not in the codebase. The systemd service loads it via `EnvironmentFile`.

```
/etc/springapp-prod.env  (chmod 600 — root read only)
```

`application-prod.yml` is in `.gitignore` and must never be committed to GitHub.

---

## Environment Setup

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
sudo -u springapp git clone https://github.com/tttaufiqqq/green-lifestyle-market /opt/springapp/prod
sudo chown -R springapp:springapp /opt/springapp/
```

Then add the properties/env file (gitignored — create it manually on the server):
```bash
sudo nano /opt/springapp/prod/src/main/resources/application-prod.yml
```

Then enable and start the service:
```bash
sudo systemctl enable springapp-prod
sudo systemctl start springapp-prod
```

### Pull latest code and restart

```bash
cd /opt/springapp/prod
git pull origin main
sudo systemctl restart springapp-prod
```

### Check app logs

```bash
tail -f /var/log/springapp/prod.log
```

### Check service status

```bash
sudo systemctl status springapp-prod --no-pager
sudo systemctl status cloudflared-prod --no-pager
```

### Manual run (for debugging, outside systemd)

```bash
# Open a tmux session first so it survives SSH disconnect
tmux new -s app
cd /opt/springapp/prod
mvn spring-boot:run -Dspring-boot.run.profiles=prod
# Ctrl+B then D to detach
```

Reattach:
```bash
tmux attach -t app
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

### Oracle Schema

This app connects using the `glm_app` schema. See
[`docs/01-oracle/glm-db-access.md`](../01-oracle/glm-db-access.md) for accounts,
grants, and Flashback Archive setup.

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
# (copy cert.pem and the .json credential file back to ~/.cloudflared/)

# 5. Recreate the env file
sudo nano /etc/springapp-prod.env
sudo chmod 600 /etc/springapp-prod.env

# 6. Restore systemd services and reload
sudo systemctl daemon-reload
sudo systemctl enable springapp-prod cloudflared-prod
sudo systemctl start cloudflared-prod
```

---

## Quick Reference

| Task | Command |
|---|---|
| SSH into server | `ssh spring-boot-app@100.120.243.96   # Tailscale IP — corrected 2026-07-14, see header` |
| Pull latest | `cd /opt/springapp/prod && git pull origin main` |
| Restart app | `sudo systemctl restart springapp-prod` |
| Watch logs | `tail -f /var/log/springapp/prod.log` |
| Check all services | `sudo systemctl status springapp-prod cloudflared-prod nginx` |
| Check firewall | `sudo ufw status verbose` |
| List tunnels | `cloudflared tunnel list` |
| Check Oracle connectivity | `nc -zv linux-oracle-db.taufiq.lab 1521` (or `100.118.110.114`) |
| Reinstall ojdbc11 | `bash /opt/springapp/setup-oracle-jdbc.sh` |

---

## Notes

- `mvn spring-boot:run` requires a valid `pom.xml` with the Spring Boot plugin in the project directory. Running it outside a Spring Boot project throws `No plugin found for prefix 'spring-boot'`.
- The ojdbc11 jar is not on Maven Central. It was manually downloaded from Oracle and installed into the local Maven repo. Use `setup-oracle-jdbc.sh` to reinstall if needed.
- The named Cloudflare tunnel is permanent — its URL does not change on restart. Managed by systemd, it auto-starts on boot.
- This app connects to the Oracle DB VM using the `glm_app` schema. See [`docs/01-oracle/glm-db-access.md`](../01-oracle/glm-db-access.md) for the full account picture.
- Do not commit `application-prod.yml` or `.env` to GitHub. They are gitignored and must be created manually.

---

## Related Docs

- [`docs/01-oracle/oracle-install.md`](../01-oracle/oracle-install.md): how the Oracle backend this app connects to was built
- [`docs/02-dns/dns-setup.md`](../02-dns/dns-setup.md): where `linux-oracle-db.taufiq.lab` and other lab hostnames come from
