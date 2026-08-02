<!-- Not yet sequenced into a numbered docs/ folder, lives here in
     docs/19-devops-practice/ until the full devops-practice-plan.md is complete.
     Date below is provisional (the date this actually happened); revisit
     once final sequencing/dating is decided. -->

# Stage 4, Containers: Docker

**Date:** 2026-07-26
**Repo the actual code/infra changes live in:** `Animal-Shelter-Workshop`
(this write-up lives in the homelab meta-repo instead, alongside the devops
practice plan it's a stage of, see `devops-practice-plan.md`, Stage 4's
checklist, all 4 items)

## Why I built this

- No dependency on Stages 1-3, genuinely new ground.
- Before this, the app only ever ran one way: `app-server.yml` installing
  PHP 8.3 + Nginx straight onto a VM, by hand, every time.
- The goal was to package the app itself (code + PHP runtime + built
  frontend assets) into one portable image, and prove it actually runs,
  including talking to a real database, without needing that whole
  Ansible checklist re-run on every new machine.

## Concept: where Docker sits next to Terraform and Ansible

- These three tools do three different, non-overlapping jobs.
- Terraform and Ansible already existed in this repo (Stages 1-2).
- Docker is a new, fourth layer that doesn't replace either of them, it
  replaces **PHP's own presence directly on the VM**.

```
┌────────────────┐     ┌────────────────┐     ┌────────────────┐
│   TERRAFORM     │ ──▶ │    ANSIBLE      │ ──▶ │     DOCKER      │
│                 │     │                 │     │                 │
│  builds the     │     │  furnishes      │     │  is the moving  │
│  empty house    │     │  the house:     │     │  box you carry  │
│  (the VM/CT      │     │  installs PHP,  │     │  in, doesn't   │
│  itself exists)  │     │  nginx, wires   │     │  care whose     │
│                 │     │  up Vault       │     │  house it is    │
└────────────────┘     └────────────────┘     └────────────────┘
   "there is a             "the house is          "the app itself,
    house now"               livable"              sealed, portable"
```

- Concretely, once a VM runs this container instead of bare PHP,
  Ansible's job on it shrinks from "install PHP 8.3 + 10 extensions +
  build assets" down to just "make sure Docker is installed", the image
  carries everything else.
- Terraform is untouched either way; it never knew PHP existed in the
  first place.

**Databases stay completely outside the box, on purpose.**
- This app talks to 5 separate real database servers (`reporting`/
  `shelter`/`animals`/`booking`/`users`, see `config/database.php`), each
  still its own Terraform-built, Ansible-configured host on the
  Tailscale-connected Proxmox fleet.
- Docker doesn't containerize any of them, it just needs the app
  container to have network reachability to call out to them, same as
  the bare-metal deployment already does.
- Stateful services (real data, Vault-backed credentials, nightly
  backups already proven in Stage 3) are the wrong candidate for
  "disposable, rebuild from scratch" containers; the app itself is
  exactly the right candidate.

```
┌────────────────────────┐
│   📦 APP BOX (Docker)    │
│   Animal-Shelter-Workshop│
└───────────┬────────────┘
            │  network calls (same as today)
   ┌────────┼────────┬────────┬────────┐
   ▼        ▼        ▼        ▼        ▼
┌──────┐┌──────┐┌──────┐┌──────┐┌──────────┐
│MySQL ││MySQL ││MySQL ││MySQL ││ Postgres  │
│animals││booking││shelter││report││  users   │
└──────┘└──────┘└──────┘└──────┘└──────────┘
   each one: still its own Terraform-built host,
   still configured by Ansible, untouched by Docker
```

- The local `docker-compose.yml` below reaches all 5 of these same real
  hosts directly — Docker doesn't containerize the databases, it just
  needs outbound network reachability to them, which a laptop's Tailscale
  membership already provides (see section 2 below for exactly how).

## Flow

```
┌────────────────────────────────────┐
│         STAGE 4, DOCKER           │▏
└────────────────────────────────────┘▔▔

┌────────────────────────────────┐     done, composer builder + node/vite
│ 1. Multi-stage Dockerfile        │▏    builder + php:8.3-fpm-alpine runtime,
│    (build once, ship a slim box) │▏    extension list matches app-server.yml
└────────────────────────────────┘▔▔    exactly
              │
              ▼
┌────────────────────────────────┐     done, app + nginx, wired to
│ 2. docker-compose.yml            │▏    all 5 real DB connections via
│    (dev credentials, all 5 DBs) │▏     .env's workshop_2_dev account
└────────────────────────────────┘▔▔
              │
              ▼
┌────────────────────────────────┐     done, v1.0.0 and latest,
│ 3. Image tagging/versioning      │▏    same digest, both pushed
└────────────────────────────────┘▔▔
              │
              ▼
┌────────────────────────────────┐     done, docker.io/tttaufiqqq/
│ 4. Push to a registry            │▏    animal-shelter-workshop, Harbor
│    (Docker Hub)                 │▏     deferred per the plan's own
└────────────────────────────────┘▔▔    capacity note
```

## What I built

### 1. Multi-stage `Dockerfile`

Three stages, each throwing away what the next one doesn't need:

- **`vendor` (composer:2)**: `composer install --no-dev --optimize-autoloader`.
  - Split into two `RUN` layers (install without the app code, then
    `dump-autoload` after copying it) so `vendor/` stays cached across
    app-code changes that don't touch `composer.json`/`composer.lock`.
- **`frontend` (node:20-alpine)**: `npm ci && npm run build` (Vite).
  - Doesn't need PHP or Composer at all.
- **`runtime` (php:8.3-fpm-alpine)**: the only stage that ships.
  - Extension list copied 1:1 from
    `infrastructure/ansible/playbooks/app-server.yml`'s own "Install
    PHP 8.3 and required extensions" task: `mbstring`, `curl`, `zip`,
    `bcmath`, `pdo_mysql`, `pdo_pgsql`, `gd`, `intl`, `opcache`, plus
    `redis` via PECL.
  - `xml`/`pdo`/core curl support ship built into the official image
    already.
  - Alpine's dev headers (`icu-dev`, `postgresql-dev`, `libzip-dev`,
    etc.) are installed as a `.build-deps` virtual package and purged
    in the same layer once the extensions are compiled.
  - Final image is **254MB / 59MB actual content**, not the 700MB+ a
    kitchen-sink dev image.
  - Laravel Sail's own `runtimes/8.3/Dockerfile`, already vendored in
    this repo, is the reference point for "what NOT to copy": it's
    Ubuntu-based, ships Xdebug/Imagick/Playwright/Swoole, and is built
    for local `artisan serve`, not a production-shaped image.

- Final stage copies `vendor/` from the `vendor` stage and
  `public/build/` from `frontend`.
- Runs as `www-data`.
- `EXPOSE 9000` for `php-fpm` (no built-in web server, Nginx is a
  separate container, see below).

### 2. `docker-compose.yml`, wired to all 5 real databases

![Excalidraw diagram: docker compose up starts 2 containers (webserver-1/nginx, app-1/the built app image) inside the WSL host's Tailscale-authorized "Dockerized Workshop 2 project for development" frame. app-1 reads dev credentials from .env and reaches out through the host's tailscale0 interface to all 5 real database hosts, each labeled by role and engine — MariaDB (report), MySQL (shelter), PostgreSQL (user), MySQL (animals), MariaDB (booking).](images/stage4-dev-credential-flow.png)

- Two services: `app` (this image) and `webserver`. No local database
  container at all.
- `webserver` (`nginx:alpine`) proxies `.php` requests to `app:9000`
  over TCP, config in `docker/nginx/default.conf`, adapted from the
  production `nginx-locations.conf.j2` template.
- `app` reaches all 5 real Tailscale-hosted databases directly,
  authenticating as a dedicated **dev** credential (`workshop_2_dev`,
  read from the repo's own `.env`) — never the `workshop_2_prod` account
  production uses. Same 5 real hosts as production, separate account.

**Why this works with zero extra networking:** the Docker host (WSL) is
itself a Tailscale node. Outbound traffic from a container to any
`100.x.x.x` address gets NAT'd through the host's own `tailscale0`
interface via Docker's normal bridge networking — no sidecar, no
`network_mode: host`, nothing special. Confirmed live with `nc -zv` from
inside the `app` container against each database host before touching any
compose config.

```
   your browser
        │  http://localhost:8080
        ▼
┌─────────────────┐
│   webserver-1    │   nginx, serves static files directly,
│   (nginx:alpine) │   forwards *.php requests onward
└────────┬─────────┘
         │  fastcgi, port 9000
         ▼
┌─────────────────┐
│      app-1       │   our built image, runs PHP-FPM,
│ (animal-shelter-  │   reads workshop_2_dev creds from .env
│  workshop:latest) │
└────────┬─────────┘
         │  outbound via docker0 bridge, NAT'd through
         │  the WSL host's own tailscale0 interface
         ▼
┌─────────────────────────────────────────────┐
│         WSL host's tailscale0 interface        │   no sidecar, no
└─────────────────────────────────────────────┘   special networking
         │
   ┌─────┼──────┬──────────┬──────────┐
   ▼     ▼      ▼          ▼          ▼
reporting shelter animals   booking    users
(mariadb) (mysql) (mysql-2) (mariadb-2)(postgres)
   all 5: workshop_2_dev database + user, on the
   same real hosts production uses
```

![WSL terminal running `docker compose up --build` for Animal-Shelter-Workshop: full multi-stage BuildKit output (vendor/frontend/runtime stages, cached layers reused, image exported and tagged animal-shelter-workshop:latest in 35.8s), then `docker compose up` bringing up 2 containers (app-1, webserver-1, no db-1) and streaming php-fpm's own startup log lines confirming it's ready to handle connections](images/stage4-wsl-docker-compose-build-up.png)

![Second WSL terminal pane: `docker ps` showing just the 2 real containers (webserver-1 on nginx:alpine mapped to 0.0.0.0:8080, app-1 on animal-shelter-workshop:latest, port 9000 internal-only), `docker compose logs -f app` tailing the same php-fpm ready-to-handle-connections lines live, then a clean `docker compose down` removing both containers and the network](images/stage4-wsl-docker-ps-logs-down.png)

Both screenshots are native WSL Docker CLI — this stage was originally
run through Docker Desktop's GUI, but Docker Desktop was uninstalled
2026-07-31 in favor of native Docker Engine inside WSL, so all Docker work
in this repo runs through the `docker`/`docker compose` CLI directly now.
`docker ps` is the direct, current-state answer to a distinction worth
being explicit about, since it's easy to misread:
- `docker ps` / `docker compose ps` lists running **containers**, live
  instances, not **images**.
- The *IMAGE* column just names which image each container was started
  from.
- `docker images` is where the actual image list lives (one entry each
  for `animal-shelter-workshop:latest`, `nginx:alpine`, not one per
  container).

**`config/database.php`'s own defaults for `DB1_HOST`/`DB2_HOST`/`DB5_HOST`
were stale**, still pointing at pre-migration VM IPs from before
`docs/21-asw-db-vms-to-ct-migration` moved those 3 databases from VMs to
CTs — `.env`'s dev block carried the same staleness. Fixed in both, to the
new CT IPs.

**Getting a fresh dev schema onto the databases wasn't a plain
`php artisan migrate`.** This app's migrations aren't cleanly separable by
connection — some single migration files create tables across 2-3
connections in one `up()` method. Two of the 5 hosts (`animals`,
`booking`) already carried a full `workshop_2_dev` schema; the other 3
(`reporting`, `shelter`, `users` — the same 3 hosts
`docs/21-asw-db-vms-to-ct-migration` moved from VM to CT) needed it built
fresh, since that migration only ever carried over `workshop_2_prod`, not
the separate dev account (see that doc's own note on the gap). Ran
`migrate` with the ledger persisted to a mounted sqlite file across
container runs, pre-seeding the ledger for whatever already existed on
`animals`/`booking` so those portions weren't re-attempted, letting only
the genuinely missing portions execute for real.

- The app's own default connection is a persistent `sqlite` file (baked
  into the image, `database/database.sqlite`) — this is what already
  holds Laravel's own framework tables (cache/sessions/migrations
  ledger) even in production, per `config/database.php`'s
  `'default' => env('DB_CONNECTION', 'sqlite')`.
- The `/up` health route (built into this app via
  `bootstrap/app.php`'s `health: '/up'`) needs no database at all.
- `php artisan db:show --database=shelter` (or any of the other 4) proves
  each connection actually reaches its real host.

### 3 & 4. Tagging and push

```
tttaufiqqq/animal-shelter-workshop:v1.0.0
tttaufiqqq/animal-shelter-workshop:latest
```

- Both tags point at the same image (`sha256:f637cc4e...`), pushed to
  Docker Hub.
- Harbor stays deferred, per the plan's own capacity note: the homelab
  host has too little free RAM right now for Harbor's
  core+Postgres+Redis+registry+trivy stack.

![Docker Hub repo page for tttaufiqqq/animal-shelter-workshop, showing the pushed image's tag summary: digest sha256:f637cc4e0..., size 56.3MB, "Updated 1 minute ago"](images/stage4-dockerhub-repo.png)

## What I found

**Bug: stale `bootstrap/cache/*.php` baked into the image.**
- The first build's `COPY . .` picked up this Windows dev machine's own
  `bootstrap/cache/packages.php`/`services.php`, generated locally
  *with* dev dependencies installed (`laravel/pail` among them).
- The image's `vendor/` is `--no-dev` and doesn't have Pail at all.
- First `docker compose up` produced a real HTTP 500:
```
Class "Laravel\Pail\PailServiceProvider" not found
```
- This is the exact same class of bug the Stage 1 writeup already hit
  once with `fakerphp/faker` (a dev-only package a production/no-dev
  environment silently assumed was there).
- Fixed two ways together: added `bootstrap/cache/*.php` to
  `.dockerignore` (so a stale host-generated cache manifest can never
  ship again), and added `RUN php artisan package:discover
  --no-interaction` to the runtime stage, right after `vendor/` and the
  app code are both in place, regenerating that cache fresh, against
  the exact `vendor/` the image actually ships.

**The app's own graceful-degradation handling covers a partial-outage
scenario for real, proven before all 5 connections were wired.** With only
`shelter` reachable and the other 4 connections genuinely down, hitting
the homepage still returned **HTTP 200** (not a 500) —
`HandleDatabaseFailures`/`InjectDatabaseStatus` middleware (already in
`bootstrap/app.php`'s middleware stack) already handle a database being
unreachable, and `/api/database-status` reported exactly that shape
(`shelter: connected`, the other 4 `connected: false`). Still true
architecturally today if any one of the 5 real hosts ever goes down —
Docker doesn't make multi-DB wiring easier by itself, it just relocates
the same problem (5 sets of credentials need to reach the app somehow)
into env vars/Secrets instead of `.env` on a VM.

## How to independently verify each item

**1. Multi-stage Dockerfile**
```bash
docker compose build app
docker images animal-shelter-workshop
```
- Expect a successful build and a final image around 250MB total /
  ~60MB actual content (`docker images --format` shows both).

**2. docker-compose.yml, all 5 real DB connections**
```bash
docker compose up -d --build
curl -o /dev/null -w "%{http_code}\n" http://localhost:8080/up
# expect: 200

docker compose exec app php artisan db:show --database=shelter
# expect: real host/database (workshop_2_dev), reachable

curl http://localhost:8080/api/database-status
# expect: "allOnline":true, all 5 connections connected:true
```

**3. Image tagging**
```bash
docker images tttaufiqqq/animal-shelter-workshop
# expect: v1.0.0 and latest, same IMAGE ID
```

**4. Registry push**
```bash
docker pull tttaufiqqq/animal-shelter-workshop:v1.0.0
```
- Or check https://hub.docker.com/r/tttaufiqqq/animal-shelter-workshop
  directly.

## What carries forward to Stage 5 (k3s), not both containers

- Worth being explicit about, since it's easy to assume "containerize
  the app" means the whole `docker-compose.yml` stack moves into
  Kubernetes as-is. It doesn't.
- Only one of the 2 containers is a real deliverable, the other is a
  local dev convenience, scoped to this stage only:

```
STAGE 4 (docker-compose, local dev)           STAGE 5 (k3s, opening move)
┌───────────┐  ┌───────────┐                  ┌───────────────────┐
│webserver-1 │  │  app-1     │                  │        Pod          │
│  (nginx)   │  │ (our box)  │       ──▶        │  (our image, same   │
└───────────┘  └───────────┘                  │  box, now scheduled │
      only        carries                      │  by k3s instead of  │
   local dev       forward                      │  docker compose)    │
                                                 └──────────┬─────────┘
                                                             │ same network
                                                             │ calls as always
                                                       real Tailscale DB fleet
```

- `webserver-1` (nginx), in Kubernetes, routing traffic in from outside is
  normally a cluster-level concern (a `Service`/`Ingress`), not a sidecar
  container you hand-run per app. Whether nginx comes back as its own piece
  is a later decision, not Stage 5's opening move.
- `app-1` is the one that matters, Stage 5's own plan starts with
  *"Get Stage 4's `Animal-Shelter-Workshop` image running manually as one
  Pod via `kubectl run`,"* then wraps it in a real `Deployment` + `Service`,
  then kills that Pod on purpose to prove it self-heals via replicas, the
  actual reason to move to Kubernetes at all: `docker compose` restarts what
  you told it to run, but a Kubernetes `Deployment` replaces a dead
  container with a fresh one automatically, across a whole cluster, not
  just one host.
- Production credentials never touch `docker-compose.yml` at all — see
  `docs/19-devops-practice/04-k3s-single-node-deployment-and-vault-injector.md`
  for where `workshop_2_prod` actually gets used (k3s, injected live from
  Vault). The two paths are deliberately parallel and non-overlapping: dev
  credentials never touch k3s, prod credentials never touch
  `docker-compose.yml`.

## Where things live

| Piece | Path (in `Animal-Shelter-Workshop` unless noted) |
|---|---|
| Dockerfile | `Dockerfile` (repo root) |
| Nginx config | `docker/nginx/default.conf` |
| PHP tuning | `docker/php/local.ini` |
| Compose file | `docker-compose.yml` (repo root) |
| Dev DB credentials | `.env` (repo root, gitignored) |
| Build-context excludes | `.dockerignore` |
| Registry | `docker.io/tttaufiqqq/animal-shelter-workshop` (`v1.0.0`, `latest`) |
| This write-up | `proxmox-homelab-taufiq/docs/19-devops-practice/03-docker-multi-stage-build-and-compose.md` (homelab meta-repo) |

### Screenshots

- `images/stage4-dockerhub-repo.png`, added above.
- `images/stage4-dev-credential-flow.png`, `stage4-wsl-docker-compose-build-up.png`,
  `stage4-wsl-docker-ps-logs-down.png`, added above — native WSL Docker
  CLI, not the original `stage4-docker-desktop-containers.png`'s GUI
  (Docker Desktop uninstalled 2026-07-31, so that screenshot no longer
  reflects how this repo runs Docker).
- **Still to add: `images/stage4-database-status-partial.png`**, browser
  screenshot of `http://localhost:8080/api/database-status` showing all 5
  `connected: true`. Save to `docs/19-devops-practice/images/`.
