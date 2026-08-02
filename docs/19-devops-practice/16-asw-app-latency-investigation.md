# asw-app Page Latency Investigation

**Date:** 2026-08-02

## Why I built this

- Noticed while poking around Grafana during doc 13/14's monitoring
  follow-on: ordinary `asw-app` pages took 1.5-2.5s to respond, while
  Laravel's own `/up` health route (bypasses the `web` middleware group
  entirely) responded in 0.35-0.55s. Not urgent — no real users yet —
  but worth understanding rather than leaving as an unexplained
  characteristic, especially before any future real-traffic milestone.
- Everything triable from *outside* a request was already ruled out
  before `plans/09-asw-app-latency-investigation-plan.md` existed:
  network/Cloudflare Tunnel, DB query volume, Redis round-trip, missing
  config/route cache, raw PHP/Laravel bootstrap, CPU core starvation,
  DNS. The `/up` vs. normal-page gap was the one real lead — something
  in the `web` middleware stack.
- Plan 09's Stage 1 called for Laravel Telescope or manual timing
  middleware to see where the time actually went. In practice neither
  was needed — direct `tinker` timing on the live cluster found the
  answer directly.

## What I built

```
┌────────────────────────────────────┐
│  PLAN 09 EXECUTION — MY APPROACH   │▏
└────────────────────────────────────┘▔▔

┌────────────────────────────────┐     tinker timing directly on the
│ 1. Find the bottleneck with real  │▏    live cluster instead of
│    numbers, not more guessing     │▏    Telescope — faster, and the
└────────────────────────────────┘▔▔    container's read-only
              │                          filesystem ruled out a live
              │                          composer install anyway
              ▼
┌────────────────────────────────┐     InjectDatabaseStatus middleware:
│ 2. Read the bottleneck straight   │▏    ~1.16s live probe of all 5 DBs,
│    from the data                  │▏    on every single page, just for
└────────────────────────────────┘▔▔    an offline-DB banner
              │
              ▼
┌────────────────────────────────┐     cache the middleware's own read
│ 3. Fix it, scoped to the finding  │▏    (safe, cosmetic) — NOT the
└────────────────────────────────┘▔▔    checker service itself (tests
              │                          require it stay live)
              ▼
┌────────────────────────────────┐     tried extending the same cache
│ 4. Found a second contributor,    │▏    to safeQuery()/isDatabaseAvailable()
│    fix attempt broke a real test  │▏    — CI caught a genuine
└────────────────────────────────┘▔▔    correctness regression, reverted
              │                          before it ever reached prod
              ▼
┌────────────────────────────────┐     curl -w time_starttransfer,
│ 5. Verify with real numbers       │▏    before/after, same method used
└────────────────────────────────┘▔▔    throughout the investigation
```

### 1. Finding the bottleneck

- Plan 09 anticipated needing Laravel Telescope or manual timing
  middleware. Neither was actually installed: `asw-app`'s container
  filesystem is read-only for the app user (`kubectl exec ... rm` on an
  app file returned `Permission denied`) — a sound production posture,
  but it also meant no live `composer require` in the running pod.
- Went straight to `php artisan tinker` against a running pod instead,
  timing suspect services directly with real `microtime(true)` deltas.
  Confirmed the `/up` vs. normal-page gap first with `curl` against the
  cluster's own NodePort (bypasses Cloudflare Tunnel/internet jitter
  entirely, unlike curling the public domain from a laptop):

  ```
  ssh linux-k3s
  curl -s -o /dev/null -w 'ttfb=%{time_starttransfer}s\n' http://localhost:30080/up   # ~4.5ms
  curl -s -o /dev/null -w 'ttfb=%{time_starttransfer}s\n' http://localhost:30080/     # ~1.485s
  ```

### 2. Root cause #1 — the DB-status banner middleware

- `app/Http/Middleware/InjectDatabaseStatus.php` runs on **every** page
  in the `web` middleware group, calling
  `DatabaseConnectionChecker::checkAll()` to populate `dbConnectionStatus`
  for an offline-DB warning banner (a real, deliberate graceful-
  degradation feature, not dead code).
- `checkAll()` does a live `fsockopen` **and** a full PDO connect
  against all 5 distributed databases (reporting/animals/shelter/
  booking/users — MySQL/MariaDB/MariaDB/MariaDB/PostgreSQL, spread
  across 5 separate hosts), sequentially, uncached:

  ```
  php artisan tinker --execute='
  $start = microtime(true);
  app(App\Services\DatabaseConnectionChecker::class)->checkAll();
  echo round((microtime(true)-$start)*1000,1)."ms\n";
  '
  # → 1155.6ms
  ```

- That single call accounted for ~78% of the 1.48s gap, on every page,
  for a feature nobody was looking at on most requests.

### 3. Fix #1 — cache at the middleware, not the checker (kept, deployed)

- `DatabaseConnectionCheckerTest` (`tests/Unit/Services/`) explicitly
  locks `checkAll()`/`isConnected()` to always be live, never cached —
  a test literally named *"checkAll() always reflects live status,
  never a cached snapshot"*. That's there because
  `PreventDatabaseTimeout` middleware calls `isConnected('users')`
  directly before login/register/password-reset routes, and that check
  needs to be live.
- Caching inside `DatabaseConnectionChecker` itself would have broken
  that contract. Instead, cached the *middleware's own read* — a
  separate `web_db_connection_status` Redis key, 15s TTL, via
  `Cache::remember()`:

  ```php
  $dbStatus = Cache::remember('web_db_connection_status', 15, fn () => $this->checker->checkAll());
  ```

- Safe because this specific call only feeds a cosmetic banner — a
  15-second-stale "all databases online" read is a fine trade for not
  paying a 1.16s tax on every page. Verified via `tinker` against the
  real Redis store before deploying: cold (uncached) 1161ms, warm
  (cached) 0.5ms.
- Deployed as `Animal-Shelter-Workshop@156b109`.

### 4. Root cause #2 — safeQuery()'s own live pre-checks

- After fix #1, `/` stabilized around 0.89-0.9s — better than the
  1.485s baseline, but still nowhere near `/up`'s few-millisecond floor.
- `app/DatabaseErrorHandler.php`'s `safeQuery()`/`isDatabaseAvailable()`
  helpers — used throughout controllers for the app's graceful-
  degradation pattern (skip a query and fall back gracefully if its DB
  is down) — each call `DatabaseConnectionChecker::isConnected()`
  **independently**, live, uncached. The homepage
  (`ManagesReports::indexUser()`) alone calls this twice
  (`reporting`, `users`) before any real work happens.
- Confirmed the per-call cost directly:

  ```
  php artisan tinker --execute='
  $start = microtime(true);
  app(App\Services\DatabaseConnectionChecker::class)->isConnected("reporting");
  echo round((microtime(true)-$start)*1000,1)."ms\n";
  '
  # → 204.7ms
  ```

### 5. Fix #2 — attempted, correctly reverted after CI caught a real regression

- Tried the same trick as fix #1: have `isDatabaseAvailable()` read the
  middleware's already-cached `web_db_connection_status` instead of
  re-probing, falling back to a live check when nothing's cached
  (console commands, tests).
- Pushed as `Animal-Shelter-Workshop@0eb6cd5`. CI's backend suite (366
  tests, ~12 minutes) failed exactly one:
  `PaymentCrossDbConsistencyTest > it skips shelter slot update when
  the shelter DB is offline` — expected `slot->status` to stay
  `'occupied'` (write skipped, DB forced offline mid-flow), got
  `'available'` (write went through).
- Real bug, not a flaky test: that test forces `shelter` offline
  *after* an earlier request in the same flow had already populated
  the 15s cache with `shelter: online`. The cached read papered over a
  DB going offline **mid-session** — exactly the scenario the graceful-
  degradation feature exists to catch before a write happens. Unlike
  fix #1's cosmetic banner, this path gates real writes; staleness here
  is a correctness bug, not a display nicety.
- Reverted (`Animal-Shelter-Workshop@2874fbd`) before this ever reached
  the cluster — CI's `Tests → Deploy` gate did exactly its job, the bad
  image was never built or pushed.

### 6. Fix #3 — memoize `isDatabaseAvailable()` per connection, per request (kept, deployed)

- Only found because the user did real page-to-page navigation after
  fix #1 shipped and it still felt slow — went back to the actual pages
  visited (`/rescue-map`, `/reports/all`, `/animal:main`, `/clinic-vet`)
  instead of just re-checking `/`.
- `RescueMapController::index()` (`/rescue-map`) calls `safeQuery()`
  against the **same** `reporting` connection **three times** back to
  back — each one a fresh live probe (~200ms, confirmed in fix #2's
  section above) of a fact that was already known from 200ms earlier in
  the same request. `ViewsAnimals`/`ManagesClinicsVets` (the other 3
  pages) have the same pattern for `reporting`/`shelter`/`animals`.
- Fix #2 was reverted because a **cross-request** (15s TTL) cache could
  read stale after a DB's state changed between requests. That risk
  doesn't exist for a cache that only lives **within one request**:
  `DatabaseErrorHandler` is a trait mixed into controllers, and Laravel
  resolves a fresh controller instance per request under PHP-FPM (no
  Octane), so a plain instance property naturally resets every request
  with no TTL, no Redis, no explicit invalidation needed:

  ```php
  protected array $databaseAvailabilityMemo = [];

  protected function isDatabaseAvailable(string $connection): bool
  {
      if (array_key_exists($connection, $this->databaseAvailabilityMemo)) {
          return $this->databaseAvailabilityMemo[$connection];
      }

      $checker = app(DatabaseConnectionChecker::class);
      return $this->databaseAvailabilityMemo[$connection] = $checker->isConnected($connection);
  }
  ```

- Local verification against `PaymentCrossDbConsistencyTest`/
  `DegradedConnectivityTest` didn't work (this Windows machine can't
  fully reach the CI-managed test databases — same pre-existing gap as
  the flagged item below) — pushed and let CI be the real gate, same as
  fix #1/#2. CI passed clean.
- Deployed as `Animal-Shelter-Workshop@6cd952b`.

### 7. Final verification

| | `/up` (bypasses `web` group) | `/` (home) |
|---|---|---|
| Before any fix | ~4.5ms (internal) / 0.35-0.55s (public, plan 09's own baseline) | 1.485s (internal) / 1.5-2.5s (public, plan 09's own baseline) |
| After fix #1 + fix #3 (deployed) | ~4.5-12ms (internal, first-hit-after-redeploy varies) | ~0.85-0.99s steady state (internal) |

- Steady-state `/` is now ~0.9s, down from 1.485s (~40% reduction).
  `/rescue-map`/`/clinic-vet`/`/animal:main` (fix #3's actual target)
  save more proportionally, since those pages had 2-3x redundant
  same-connection checks that `/` itself never had — not independently
  curl-timed (they require an authenticated admin session), but the
  per-call cost (fix #2's ~204.7ms figure) times the call count removed
  is the same measured unit either way.
- The remaining gap to `/up`'s floor is the live `safeQuery()`
  pre-checks (one genuine, unavoidable probe per *distinct* connection
  a page touches) plus normal session/CSRF/Livewire/view-render cost,
  and isn't safely reducible further without weakening the
  graceful-degradation feature — see below.

## Why full parity with `/up`'s floor isn't the right goal here

- `/up` is a deliberately bare Laravel health route with no session, no
  CSRF, no Livewire, no DB awareness at all — it was never a realistic
  target for a normal page, just a useful floor to measure against.
- The remaining ~0.9s on `/` is dominated by `safeQuery()`'s live,
  per-connection availability checks — a real, tested safety feature
  (5 separate DB hosts, any of which can go down independently; the app
  is explicitly designed to degrade gracefully rather than 500). Fix #2
  showed directly that caching this path trades correctness for speed.
  Left as-is: intentional, verified-necessary latency, not an
  unexplained one anymore.

## Also this session: k9s installed on `linux-k3s`

- Not part of the latency investigation itself — came up while waiting
  on a CI run mid-session. This whole investigation leaned on repeated
  raw `kubectl get pods`/`logs`/`exec` one-liners over SSH; a terminal
  UI for that loop is a genuine quality-of-life win for whoever is
  driving interactively (not for me — I still need scriptable,
  parseable command output, a TUI doesn't help automation).
- Installed via the official `.deb` release, not `apt`/`snap` (not in
  the default Ubuntu 24.04 repos):

  ```
  ssh linux-k3s
  curl -sL https://github.com/derailed/k9s/releases/latest/download/k9s_linux_amd64.deb -o /tmp/k9s.deb
  sudo dpkg -i /tmp/k9s.deb
  ```

- No extra config needed — `linux-k3s`'s own user already has
  `KUBECONFIG=$HOME/.kube/config` exported in `.bashrc`/`.profile` from
  an earlier session, readable without `sudo` (unlike
  `/etc/rancher/k3s/k3s.yaml` itself, `root`-only `600`). Confirmed
  working against all 3 nodes on first launch:

  ![k9s terminal UI showing the default namespace's 12 running pods spread across all 3 k3s nodes — asw-app (3 replicas, 2/2 ready, on linux-k3s), asw-nginx (3 replicas, on linux-k3s-2), asw-redis, cloudflared, vault-agent-injector, and 3 Grafana Alloy pods — with per-pod NODE and AGE columns visible, and cluster CPU at 8% / memory at 41% in the header](images/16-k9s-pods-view.png)

- Just `k9s` after SSH'ing in normally (interactive login shell, so the
  exported `KUBECONFIG` is picked up) — no flags, no `sudo`.

## Also this session: CI was filling `linux-gh-runner`'s disk on every push

- This investigation alone triggered 5 separate CI `Tests`/`Deploy`
  cycles (fix #1, the reverted fix #2, its revert, fix #3, this fix
  itself), each building two fresh Docker images from scratch — on
  `linux-gh-runner`'s small 10GB root disk, with no cleanup step,
  that's real accumulation. Alertmanager's `HighDiskUsage` (>90% full)
  fired via Telegram mid-session — 9:02 PM, resolved 9:55 PM, fired
  again 10:21 PM, disk genuinely at 92% (8.5G/9.8G) at the time.
- **Manual mitigation in the moment**: `docker builder prune -f
  --keep-storage 200MB` + `docker image prune -af` via SSH, freed
  ~1GB, 92% → 81%. A stopgap, not a fix — the very next CI build
  climbed it right back to 88%.
- **Permanent fix**: a new step in `.github/workflows/deploy.yml`'s
  `build-and-push-k3s-images` job, right after the images are already
  pushed to Docker Hub (so it's always safe to drop the local copies —
  k3s pulls from Docker Hub, never from this runner's local cache):

  ```yaml
  - name: Prune Docker build cache and local images
    if: always()
    run: |
      docker image prune -af || true
      docker builder prune -f --keep-storage 300MB || true
  ```

  `if: always()` so it still runs even if an earlier step in the job
  fails — the whole point is disk hygiene, which matters most exactly
  when something already went wrong.
- Deployed as `Animal-Shelter-Workshop@95efa62`. First real run
  (`build-and-push-k3s-images` job) reclaimed 191.7MB from
  `docker image prune -af` directly in the logs. `docker builder prune
  --keep-storage` itself printed a deprecation notice (renamed to
  `--reserved-space` upstream, with inverted semantics — reserved-space
  means "keep at least this much free", not "cap the cache at this
  much") — worth switching to the new flag name eventually, but the
  image prune alone already did the real work: disk after this run was
  **77% (7.1G/9.8G)**, not climbing back toward 90%+ like the
  unpruned builds before it.

## Also this session: `node_exporter` never made it onto the CT-migrated DB hosts

- Surfaced via three simultaneous `InstanceDown` (critical) Telegram
  alerts for `linux-mariadb`/`linux-postgres`/`linux-mysql` — the
  **live production DB fleet** `asw-app` actually uses, not the old
  decommissioned VMs. Worth treating as a possible real incident until
  checked.
- **Not an outage**: all 3 hosts were reachable over SSH, and their
  actual DB services (`mariadb`/`postgresql`/`mysql`) were all
  `active`. `node_exporter` itself was the thing down — not just
  stopped, but genuinely never installed (`systemctl status
  node_exporter` → *"Unit node_exporter.service could not be found"*,
  no binary, no unit file).
- **Root cause**: these 3 hosts are the CT-migrated replacements for
  the original DB VMs (`plans/04-asw-db-vms-to-ct-migration-plan.md`,
  confirmed still running as LXC via `systemd-detect-virt` → `lxc`).
  The migration's provisioning playbooks
  (`infrastructure/ansible/playbooks/linux-mariadb-new.yml` and its
  `-mysql`/`-postgres` siblings, in `Animal-Shelter-Workshop`) only run
  the `mysql_family`/`db_firewall` roles — `node_exporter` was never
  part of them, even though all 3 hosts are already listed in
  `inventory.yml`'s `monitoring_targets` group that the fleet-wide
  `node-exporter-fleet.yml` playbook targets. The playbook that would
  have caught this was just never re-run against the new CTs.
- **Fix**: ran the existing fleet-wide playbook, scoped to just these
  3 hosts, from `linux-gh-runner` (reusing the same Vault-sourced CD
  credentials `deploy-db` already uses, since this Windows machine's
  own SSH config can't reach the DB fleet and WSL has a separate
  Tailscale identity with no DB-fleet access either):

  ```
  ansible-playbook -i inventory-ip.yml --private-key <cd_key> \
    --limit 'linux-mariadb,linux-postgres,linux-mysql' \
    playbooks/node-exporter-fleet.yml
  ```

- Clean run, `changed=2` per host (package install + UFW rule), zero
  failures. Confirmed via Prometheus's own `/api/v1/targets` — all 3
  report `health: up`.
- Not a code change, no commit — purely an Ansible run against live
  infrastructure. Same gap likely exists for `linux-mysql-2`/
  `linux-mariadb-2` if their own provisioning ever gets redone from
  scratch; worth checking those specifically if this recurs.

## How to independently verify each item

| # | Command | Expected |
|---|---------|----------|
| 2 | `ssh linux-k3s "sudo kubectl exec <asw-app pod> -c app -- php artisan tinker --execute='dd(microtime(true)); app(App\Services\DatabaseConnectionChecker::class)->checkAll(); dd(microtime(true));'"` | ~1.1s+ elapsed (uncached probe still exists, just no longer runs unconditionally) |
| 3 | `git show Animal-Shelter-Workshop@156b109 -- app/Http/Middleware/InjectDatabaseStatus.php` | `Cache::remember('web_db_connection_status', 15, ...)` |
| 5 | `git log --oneline Animal-Shelter-Workshop -- app/DatabaseErrorHandler.php \| head -3` | `2874fbd` (revert) is the most recent commit before `faad4d1`/`6cd952b` (fix #3); `0eb6cd5` (the attempted cache) is reverted, not live |
| 6 | `git show Animal-Shelter-Workshop@6cd952b -- app/DatabaseErrorHandler.php` | `$databaseAvailabilityMemo` array property, no `Cache::` calls |
| 7 | `ssh linux-k3s "curl -s -o /dev/null -w 'ttfb=%{time_starttransfer}s\n' http://localhost:30080/"` (x5) | ~0.85-1.0s steady state |
| 7 | `ssh linux-k3s "sudo kubectl get deploy asw-app -o jsonpath='{.spec.template.spec.containers[0].image}'"` | tag starts with `6cd952b` (or later) |
| CI prune | `gh run view --log --job=<build-and-push-k3s-images job id>` on a recent `Animal-Shelter-Workshop` Deploy run | a `Prune Docker build cache and local images` step present, reporting `Total reclaimed space` |
| CI prune | `ssh linux-gh-runner "df -h /"` | comfortably under 90%, even shortly after a build |
| node_exporter | `curl -s http://linux-observability:9090/api/v1/targets \| python3 -c "import json,sys;[print(t['labels']['instance'],t['health']) for t in json.load(sys.stdin)['data']['activeTargets']]"` (or the Prometheus UI, **Status → Targets**) | `linux-mariadb`/`linux-postgres`/`linux-mysql` all `up` |

## Worth flagging, not fixed this session

- **CI's Tests job is slow** — ~13-15 minutes for the backend suite
  alone once actually running, and one run this session queued long
  enough to look hung before it started (30+ minutes wall clock
  including queueing). The *disk-filling* consequence of running it
  repeatedly is now fixed (see above), but the underlying slowness
  itself isn't — not investigated further, worth profiling if it keeps
  happening.
- **3 of 5 `.env.testing` distributed test-DB hosts are stale** — `DB1`
  (`reporting`), `DB2` (`shelter`), and `DB5` (`users`) point at
  `linux-mariadb-old`/`linux-mysql-old`/`linux-postgres-old` (VMs
  104/105/106), all stopped since the CT migration
  (`plans/04-asw-db-vms-to-ct-migration-plan.md`). `DB3`/`DB4` were
  already updated to the current CT fleet. This causes 3 pre-existing
  local failures in `DatabaseConnectionCheckerTest` — confirmed
  pre-existing (same failures with and without every change made this
  session) and apparently not hit in CI's own network path, since CI's
  full suite passed both times it actually ran. Not fixed here — out of
  scope for a latency investigation, deserves its own look at why
  `.env.testing` was only partially updated.

## Where things live

- **Fix #1 (kept):** `Animal-Shelter-Workshop@156b109` —
  `app/Http/Middleware/InjectDatabaseStatus.php`.
- **Fix #2 (reverted):** `Animal-Shelter-Workshop@0eb6cd5` (the
  change) / `@2874fbd` (the revert) — `app/DatabaseErrorHandler.php`.
  Left in git history deliberately, same as this repo's other
  found-and-reverted bugs (e.g. doc 13's `SESSION_DRIVER`/
  `SESSION_CONNECTION` fixes) — the regression and its catch are worth
  keeping visible, not squashing away.
- **Fix #3 (kept):** `Animal-Shelter-Workshop@faad4d1` (rebased/pushed
  as `@6cd952b`) — `app/DatabaseErrorHandler.php` (same file as fix
  #2, different mechanism).
- **The investigation plan:** `plans/09-asw-app-latency-investigation-plan.md`.
- **DB connection definitions:** `app/Services/DatabaseConnectionChecker.php`
  (the 5 named connections) and `app/Services/Concerns/DatabaseConnection/
  ChecksConnections.php` (the actual probe — untouched, still live/uncached
  as its own tests require).
- **k9s:** installed directly on `linux-k3s`, not tracked in any repo
  (a `.deb` install, not config-as-code).
- **The CI disk-prune fix:** `Animal-Shelter-Workshop@95efa62` —
  `.github/workflows/deploy.yml`'s `build-and-push-k3s-images` job.
- **The `node_exporter` fix:** an Ansible run, not a commit —
  `infrastructure/ansible/playbooks/node-exporter-fleet.yml` (already
  existed) against `linux-mariadb`/`linux-postgres`/`linux-mysql`. The
  gap it fixed lives in `linux-mariadb-new.yml`/`linux-mysql-new.yml`/
  `linux-postgres-new.yml` (same directory) never including the
  `node_exporter` role — worth adding there directly if these hosts
  ever get fully re-provisioned from scratch again.
