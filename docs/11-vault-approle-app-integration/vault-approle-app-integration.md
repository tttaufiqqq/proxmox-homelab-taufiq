# Vault AppRole — Animal Shelter Workshop App-Server Deploy Secrets

**Date:** 2026-07-20
**Server:** `linux-vault` (Proxmox CT 110, existing — see `docs/07-vault/vault-setup.md`)
**Consumer:** the Ansible control node (WSL, runs from `msi`) that deploys
`Animal-Shelter-Workshop`'s `app-server`
**Serves:** [`Animal-Shelter-Workshop`](https://github.com/tttaufiqqq/Animal-Shelter-Workshop)'s
`infrastructure/ansible` — `app-server.yml` plus the 3 DB playbooks
(`linux-{mysql,mariadb,postgres}.yml`)

**Status: done.** Steps 1–5 below were run for real against `linux-vault` on 2026-07-20 — auth
method enabled, secrets seeded (verified field-length-exact against the live `.env`, twice, after
the first attempt silently corrupted two fields — see "Issues Encountered" below), policy written,
`asw-deploy` role created, scope verified (`secret/animal-shelter-workshop` readable, `secret/oracle`
and `secret/minio` both `403`). Authenticated using the root token already cached in
`~/.vault-token` on `linux-vault` from the original `vault login` during setup — no token was typed
or pasted for this. Real output is inlined below each step.

---

## Why This Exists

`app-server`'s `.env` had every one of its 5 DB passwords hardcoded as the literal `workshop_2`,
and the 3 DB playbooks (`linux-{mysql,mariadb,postgres}.yml`) hardcoded the *same* password again
as a play var — two copies of one secret, free to drift. Separately, the real Resend SMTP API key
used in production existed in exactly one place: hand-applied directly to the live `app-server`
`.env`, in no repo at all. Full detail on the app side of this change is in
`Animal-Shelter-Workshop/docs/09-production-hardening.md`'s "Secrets moved to Vault" entry — this
doc covers only the Vault-side setup: the new secret path, the policy, and the decision to use
AppRole instead of this lab's usual static token.

## Why AppRole, Not a Scoped Static Token (departure from the runner's own precedent)

Every documented Vault consumer in this lab uses a static token (`docs/07-vault/vault-setup.md`).
`docs/09-github-actions-runner/actions-runner-setup.md` already departs from that once, trading
the root token for a scoped read-only static token plus a daily renewal timer — reasonable there,
because the consumer is `linux-gh-runner`, a dedicated, hardened LXC CT that exists for exactly one
purpose.

The consumer here is different: a personal WSL shell on `msi`, used interactively for lots of
other things, where a long-lived `VAULT_TOKEN` sitting in `~/.bashrc` or shell history is a worse
fit than a credential that can be issued short-lived and regenerated on demand. AppRole's
`role_id`/`secret_id` split gives that — the `role_id` is not secret on its own, `secret_id` has
its own TTL and use-count limits independent of the token it mints, and Vault's `approle` auth
method exists specifically for "a machine/script needs to authenticate itself" rather than "a
human is at a terminal." This is the one consumer in the lab using it; every other Vault interaction
stays as-is (root token, static scoped token for the runner).

---

## Step 1 — Enable the AppRole auth method

Not yet enabled anywhere in this lab — `docs/07-vault/vault-setup.md` only ever set up the `kv-v2`
secrets engine and token-based auth.

```bash
# Run on linux-vault, using the root token
export VAULT_ADDR="http://192.168.0.110:8200"
export VAULT_TOKEN="<root-token>"

vault auth enable approle
```

Real output: `Success! Enabled approle auth method at: approle/`

## Step 2 — Store the app's secrets

One KV-v2 path, so the policy below stays a single rule. Values come from the live
`app-server`'s current `.env` (captured first, before anything else touches it — `APP_KEY` and the
Resend `MAIL_PASSWORD` exist nowhere else) and from the DB playbooks' existing `workshop_2`
password:

```bash
vault kv put secret/animal-shelter-workshop \
  app_key="<the live host's real APP_KEY — do not regenerate>" \
  db_password="<the workshop_2 app-level DB password>" \
  cloudinary_url="cloudinary://<api_key>:<api_secret>@<cloud_name>" \
  cloudinary_cloud_name="<redacted>" \
  cloudinary_api_key="<redacted>" \
  cloudinary_api_secret="<redacted>" \
  toyyibpay_key="<redacted>" \
  toyyibpay_category="<redacted>" \
  mail_host="smtp.resend.com" \
  mail_port="587" \
  mail_username="resend" \
  mail_password="<the live Resend API key>" \
  mail_from_address="noreply@mail.tttaufiqqq.com"
```

`TOYYIBPAY_BASE_URL` is deliberately **not** in this list — it stays a hardcoded literal
(`https://dev.toyyibpay.com`) in `env-app.j2` itself, since switching it is permanently out of
scope (see `Animal-Shelter-Workshop/docs/09-production-hardening.md`).

**Real values were never typed as CLI args like the example above shows.** They were extracted
from the live `.env` with a small Python script (JSON-encoding, quote-stripping) piped straight
into `vault kv put secret/animal-shelter-workshop -` (JSON on stdin) over SSH, so no secret value
ever appeared as a shell argument, in shell history, or printed to any terminal along the way. This
mattered in practice — a first attempt using plain shell `key=value` args with `%q`/`eval`
re-quoting silently truncated `app_key` by one character and mangled `mail_from_address` entirely.
The JSON/stdin approach was verified field-length-exact against the raw
`.env` afterward:
```
app_key: 51 chars           (matches raw .env)
cloudinary_api_key: 15 chars
cloudinary_api_secret: 27 chars
cloudinary_cloud_name: 9 chars
cloudinary_url: 66 chars
db_password: 10 chars
mail_from_address: 27 chars (quotes stripped — raw .env has them literally, dotenv parsers strip these on load)
mail_host: 15 chars
mail_password: 36 chars
mail_port: 3 chars
mail_scheme: 0 chars        (empty in the live .env too — correct)
mail_username: 6 chars
toyyibpay_category: 8 chars
toyyibpay_key: 36 chars
```
Vault kv metadata after the corrected write: `version: 2` (version 1 was the corrupted attempt,
never used by anything since it was overwritten in the same session before any Ansible run).

## Step 3 — Write the read-only policy

```bash
vault policy write asw-deploy - <<'EOF'
path "secret/data/animal-shelter-workshop" {
  capabilities = ["read"]
}
EOF
```

One path, read-only — the same shape as the GH runner's `gh-runner` policy, scoped even tighter
since this consumer only ever needs one app's secrets. Confirmed via `vault policy read asw-deploy`
after writing it — output matched the HCL above exactly.

## Step 4 — Create the AppRole

```bash
vault write auth/approle/role/asw-deploy \
  token_policies="asw-deploy" \
  token_ttl=15m \
  token_max_ttl=30m \
  secret_id_ttl=90d \
  secret_id_num_uses=0

vault read auth/approle/role/asw-deploy/role-id
# role_id: <uuid>

vault write -f auth/approle/role/asw-deploy/secret-id
# secret_id: <uuid>
```

Short token TTL (15m/30m) is deliberate — a deploy run finishes in well under that, and each run
mints a fresh token from the `secret_id` rather than reusing one that sits around. `secret_id_ttl`
of 90 days means the `secret_id` itself needs manual rotation roughly quarterly; no renewal timer
like the runner's, since a WSL shell isn't always-on the way `linux-gh-runner` is.

`role_id` and `secret_id` are exported as `VAULT_ROLE_ID`/`VAULT_SECRET_ID` in the WSL shell that
runs `ansible-playbook` — never committed, never written to a file inside the repo (see
`Animal-Shelter-Workshop/infrastructure/ansible/.gitignore`, which now guards against a stray
`vault-approle*`/`.envrc` file leaking either value).

Real `role_id` (not secret on its own — safe to record here): `242a9660-e3d2-e062-feb9-c5bb8ebf8b08`.
`secret_id` was generated (`secret_id_accessor: 48da3cfd-c3e7-ff2b-a97c-8c2f069df16e`,
`secret_id_ttl: 768h`) and handed to the operator directly — not recorded here, matching this repo's
own convention of never writing live credentials into a committed doc.

## Step 5 — Verify scope

```bash
VAULT_ADDR="http://192.168.0.110:8200" vault write auth/approle/login \
  role_id="<role_id from Step 4>" \
  secret_id="<secret_id from Step 4>"
# → issues a short-lived token scoped to the asw-deploy policy

# using that token:
vault kv get -field=db_password secret/animal-shelter-workshop   # should succeed
vault kv get secret/oracle                                       # should be 403
vault kv get secret/minio                                        # should be 403
```

Real output:
```
$ vault kv get -field=mail_host secret/animal-shelter-workshop
smtp.resend.com
$ vault kv get secret/oracle
Error reading secret/data/oracle: ... Code: 403. Errors: * 1 error occurred: * permission denied
$ vault kv get secret/minio
Error reading secret/data/minio: ... Code: 403. Errors: * 1 error occurred: * permission denied
```
Scope is exactly as designed: this AppRole can read `secret/animal-shelter-workshop` and nothing
else in this Vault instance.

---

## Issues Encountered

Lesson running through all of these: **verify against the live box, never assume the template or
the control-node environment was already correct** — none of this had ever actually been exercised
end-to-end before.

### 1. ToyyibPay variable names never matched

Before seeding anything, the live `app-server`'s actual `.env` variable names were checked against
`env-app.j2` field-by-field (`grep -oE '^[A-Z_0-9]+=' .env` — names only, no values, over SSH).
`env-app.j2` had `TOYYIBPAY_SECRET_KEY`/`TOYYIBPAY_CATEGORY_CODE`/`TOYYIBPAY_RETURN_URL`/
`TOYYIBPAY_CALLBACK_URL`; the live `.env` and `Animal-Shelter-Workshop/config/toyyibpay.php` both
use `TOYYIBPAY_KEY`/`TOYYIBPAY_CATEGORY`, and the two URL vars aren't read anywhere in `app/` at
all. Pre-existing bug in the template, not introduced by the Vault change — any deploy through the
old template would have rendered a `.env` with `TOYYIBPAY_KEY` unset, silently breaking the payment
flow, and nobody would have noticed until a deploy actually ran (the live box was always
hand-configured, never through this template — see
`Animal-Shelter-Workshop/docs/09-production-hardening.md`'s path-mismatch entry). Fixed: `env-app.j2`
and this doc's `vault kv put` example both use `toyyibpay_key`/`toyyibpay_category` now, and the two
dead URL fields were dropped entirely.

### 2. `DB2_HOST`/`DB3_HOST` pointed at a database that doesn't exist

`env-app.j2`'s `DB2_HOST`/`DB3_HOST` (shelter/animals) were hardcoded to `linux-mysql`
(`100.115.237.93`) — a host confirmed live to have **no `workshop_2` database at all**. The real
data (102 rows in `animal`, confirmed live via `mysql -h 100.68.235.121 ... SELECT COUNT(*) FROM
animal`) is on `msi` (`100.68.235.121`), matching both CLAUDE.md's connection table and the live
`.env`. Fixed in `env-app.j2` before any Vault seeding happened — this would have pointed the app
at an empty/nonexistent database on the very first real deploy, `force: true` or not.

### 3. WSL's DNS was broken by the same Tailscale-takeover bug as `linux-vault`/`linux-gh-runner`

Running the actual `ansible-playbook` from the WSL control node (`msi`) failed `apt-get install
python3-hvac` with `Temporary failure resolving 'archive.ubuntu.com'`. `/etc/resolv.conf` pointed
at Tailscale's MagicDNS resolver (`100.100.100.100`), but no `tailscaled` runs inside WSL to answer
it — the exact same class of bug `docs/07-vault/vault-setup.md` and
`docs/09-github-actions-runner/actions-runner-setup.md`'s Issue 5 already hit, a third time, in a
new environment. The file also had the immutable attribute set (`chattr +i`) from whenever
Tailscale's installer last touched it, matching that file's own "DO NOT EDIT BY HAND" comment. Fix:
`sudo chattr -i /etc/resolv.conf`, then overwrite with public resolvers
(`8.8.8.8`/`1.1.1.1`) — the same fix already used twice elsewhere in this repo.

### 4. `ansible.cfg` silently ignored on a world-writable `/mnt/c` mount

Every `ansible-playbook`/`ansible` invocation from WSL printed `Ansible is being run in a world
writable directory ... ignoring it as an ansible.cfg source`. WSL's DrvFs mount of the Windows `C:`
drive (`access=client`, not `metadata` mode) presents everything under `/mnt/c` as `777`
regardless of actual Windows ACLs — `chmod` on the directory is a silent no-op. Explicitly setting
`ANSIBLE_CONFIG` doesn't bypass the check either; it applies to the file's containing directory, not
just cwd auto-discovery. Worked around per-invocation with explicit `-i`/`-u`/`--private-key` flags
instead of relying on `ansible.cfg`'s `inventory`/`remote_user`/`private_key_file` settings. Would
need `metadata,umask=22,fmask=11` mount options in `/etc/wsl.conf` (and a `wsl --shutdown`) to fix
properly at the filesystem level — not done, since that restarts the whole WSL instance.

### 5. `hvac` Python module missing — and `pip install` blocked by PEP 668

`community.hashi_vault`'s `vault_kv2_get` lookup needs the `hvac` Python package; Ubuntu 24.04's
WSL image doesn't ship it, and `pip3` wasn't even installed. `pip3 install --user hvac` would have
hit Ubuntu 24.04's externally-managed-environment restriction (PEP 668) had `pip3` existed at all.
Used `sudo apt-get install -y python3-hvac` instead — packaged in the `universe` repo, no `pip`
needed.

### 6. `group_vars/all.yml` only auto-loads adjacent to the inventory file actually passed to `-i`

`inventory.yml`'s `ansible_host` values are Tailscale MagicDNS short hostnames (`app-server`,
`linux-mysql`, ...), which WSL can't resolve (Issue 3's fix pointed it at public DNS, which has no
idea what `app-server` means either). Routed around it with a scratch inventory file containing raw
Tailscale IPs, initially placed in the WSL home directory — which made every task fail with
`'asw_secrets' is undefined`, because Ansible only auto-loads `group_vars/`/`host_vars/` from
directories adjacent to the inventory file *actually passed to `-i`*, not from the directory
containing the playbook. Fix: moved the scratch inventory override to sit directly inside
`infrastructure/ansible/`, next to the real `group_vars/all.yml`, so both get discovered together.

### 7. `FILESYSTEM_DISK` missing from the template entirely

Caught by the real `--check --diff` diff itself, not by field-name inspection like Issues 1–2:
`env-app.j2` never set `FILESYSTEM_DISK` at all. `Animal-Shelter-Workshop/config/filesystems.php`
defaults that to `'local'` when unset, which would have silently moved every upload off Cloudinary
onto local disk on the first real deploy. The same diff also showed `BOOKING_PREFER_SQLSRV`,
`VITE_APP_NAME`, and `BROADCAST_CONNECTION` present in the live `.env` but absent from the template —
checked all three against the actual codebase and confirmed all three are dead (no
`config/broadcasting.php` exists at all; the other two aren't referenced anywhere), so those were
left out deliberately. Fixed: `FILESYSTEM_DISK=cloudinary` added as a plain literal (not a secret,
not Vault-sourced).

### 8. `storage/.provisioned` missing — would have reseeded live data

`app-server.yml` only runs `db:seed --force` when `storage/.provisioned` doesn't already exist —
the guard `docs/09-production-hardening.md` added specifically so a redeploy never wipes/reseeds
real data. The live box was hand-configured outside this playbook and had never gone through a real
deploy, so that marker file was missing — meaning the very first real run would have read as a
first deploy and seeded demo/starter records on top of real data (102 real animal rows, real user
accounts, everything already live). Confirmed missing via SSH before any real run was even
considered. Fixed: an empty `storage/.provisioned` created directly on the box — the same marker
the playbook's own "Mark server as provisioned" task would create on a first run, just created
proactively so seeding never gets a chance to run against live data. Full detail:
`Animal-Shelter-Workshop/docs/09-production-hardening.md`'s "Deploy pipeline no longer destroys
data" section.

---

## Ansible side (already implemented, in the app repo)

`Animal-Shelter-Workshop/infrastructure/ansible/group_vars/all.yml` defines one shared
`asw_secrets` fact via `community.hashi_vault.vault_kv2_get`, authenticating with
`auth_method: approle` and reading `role_id`/`secret_id` from `VAULT_ROLE_ID`/`VAULT_SECRET_ID`.
`app-server.yml`'s `.env` template and all 3 DB playbooks' `db_password` now reference it. Full
detail: `Animal-Shelter-Workshop/docs/06-ansible.md` and `docs/09-production-hardening.md`.

---

## Vault Agent — secrets stopped touching disk at runtime too (2026-07-20)

**Status: done, run for real against the live box, rolled back and re-enabled once to confirm the
rollback path itself works, both verified end-to-end.**

### Why this exists

The AppRole work above closed "secrets hardcoded in the repo," but everything it delivers still
landed as **plaintext on app-server's disk** — `env-app.j2` rendered every secret into `.env` on
every deploy, and `php artisan config:cache` then baked the same resolved values into
`bootstrap/cache/config.php` a second time. Anyone with file read access to app-server (not just
remote code execution) could read every credential. Flagged as a known, deliberate gap in a prior
session; this is that follow-up, prompted by wanting a version that could be rolled back cheaply if
running an extra always-on process turned out to be too much load for the Proxmox node. In
practice the node had CPU essentially idle and ~23% RAM free at the time (Vault Agent itself uses
tens of MB), so performance was never actually the constraint — but the rollback design was built
in either way, and its rollback path was exercised for real, not just designed.

### Design

- New AppRole, `asw-app-server-agent`, bound to the same read-only `asw-deploy` policy but with a
  `token_period` (periodic, renewable indefinitely) instead of the CLI deploy role's 15m/30m TTL —
  the deploy role suits a short Ansible run; a long-running agent needs a token that renews itself.
  `secret_id_ttl=0`, `secret_id_num_uses=0` (no expiry/use-limit) — matches this being a personal
  homelab with no real data, same trust level as the deploy role's own secret already gets.
- `Animal-Shelter-Workshop/infrastructure/ansible/playbooks/tasks/vault-agent.yml`, toggled by a new
  `vault_agent_enabled` var (`group_vars/all.yml`). When `true`: installs the `vault` client,
  deploys the AppRole's `role_id`/`secret_id` to `/etc/vault-agent/`, renders 3 Vault Agent configs
  from one template (`agent-fpm.hcl`, `agent-migrate.hcl`, `agent-seed.hcl` — see "Bug 1" below for
  why 3, not 1), and wraps php-fpm's systemd unit + the migrate/seed CLI tasks under `vault agent`.
  `env-app.j2` blanks every Vault-sourced field in this mode (a Jinja `secret()` macro); `config:cache`
  is skipped entirely (see "why not just wrap php-fpm" below). `vault_agent_enabled: false` fully
  reverts: removes the systemd override, restarts php-fpm under normal supervision, and lets
  `env-app.j2`/`config:cache` go back to the plain plaintext flow — **this direction was actually
  run**, not just written, to confirm it really restores service.
- **Why not just wrap php-fpm and call it done:** the obvious-looking design (wrap only the
  php-fpm service) was rejected before deploying anything, because `config:cache` runs from the CLI
  reading `.env` directly and would keep baking the same secrets into
  `bootstrap/cache/config.php` regardless of what php-fpm's own process env held — that would move
  the plaintext, not remove it. Both the CLI paths that need secrets (migrate/seed) and `config:cache`
  had to be dealt with, not just the request-serving process.

### Bugs found running this for real (in the order they were hit)

1. **This Vault version (v2.0.3) has no CLI `-exec` flag.** The original design planned one shared
   agent config with the command supplied via `vault agent -exec="..."` per invocation. `vault agent
   -h` confirmed no such flag exists — the exec command has to live in the config file's own `exec`
   stanza instead. This is why there are 3 rendered configs (`agent-fpm.hcl`/`agent-migrate.hcl`/
   `agent-seed.hcl`) instead of one: each needs a different baked-in command. Caught the hard way —
   the first attempt crashed php-fpm outright (`flag provided but not defined: -exec`), taking the
   live site down (502) until the systemd override was removed and `.env` restored from a same-day
   backup.
2. **Sink-path permission mismatches.** php-fpm's config uses `/run/vault-agent/token`
   (systemd's `RuntimeDirectory=`, root-owned — correct, since php-fpm's master also runs as root).
   migrate/seed run as `become_user: taufiq`, which can't write there — they got their own sink
   paths under `/etc/vault-agent/` instead. That directory itself was created `0750` (owner-only
   write), which still blocked `taufiq`; fixed to `0770` so the group can actually write, not just
   read/traverse.
3. **`needrestart`'s interactive prompt hangs unattended `apt` installs.** Hit on `Install Node.js 20
   LTS`, a task with no relation to Vault Agent at all — a non-pty Ansible `apt` install has no
   terminal for needrestart's "which services should restart?" dialog to render to, so it hangs
   indefinitely rather than erroring. `needrestart.conf`'s own `$nrconf{restart}='a'` wasn't
   sufficient by itself; fixed with play-level `DEBIAN_FRONTEND=noninteractive`/`NEEDRESTART_MODE=a`.
4. **A recursive `chmod 0775` was silently making tracked files executable.** Also unrelated to
   Vault Agent specifically, but blocked every subsequent deploy once it happened: `Set storage and
   cache permissions` used numeric mode + `recurse: true`, which applies identically to files and
   directories — flipping 38 tracked files (images, `.gitignore`, `cacert.pem`) from `100644` to
   `100755`. Git tracks that bit, so the next `git pull` failed with "local modifications exist,"
   every time, forever, until fixed. Fixed with symbolic mode `u=rwX,g=rwX,o=rX`, which only grants
   execute to directories.
5. **`php-fpm`'s pool defaults to `clear_env=yes`.** Vault Agent injected secrets into the master
   process correctly, php-fpm itself came up healthy — but every request still 500'd ("No
   application encryption key has been specified"), because php-fpm wipes the environment for
   worker processes by default, regardless of what the master process (which Vault Agent execs into)
   was handed. Fixed by setting `clear_env = no` in `/etc/php/8.3/fpm/pool.d/www.conf`.
6. **Vault Agent deduplicates `env_template` blocks by their literal `contents` string.** All 5 DB
   connections share one app-level password (`db_password`), so all 5 `env_template` blocks
   (`DB1_PASSWORD`..`DB5_PASSWORD`) had byte-identical `contents`. Only the last-declared one
   (`DB5_PASSWORD`) actually got delivered to the running process — the other 4 read as `(unset)`,
   confirmed directly via a temporary debug script hit over HTTP, which is how 4 of 5 databases
   silently went "disconnected" even though php-fpm, the credential, and connectivity were all
   otherwise fine. Fixed with an inert per-variable Go-template comment
   (`{{/* DB1_PASSWORD */}}`, renders as nothing) appended to each, making the 5 templates'
   *source text* unique without changing their rendered value.

None of these 6 had ever been exercised before — same root cause as every bug found in the AppRole
work above: this deploy path had never actually been run for real until this session.

### Consequence worth stating plainly

Runtime now depends on Vault being reachable, which it previously didn't (`config:cache`'s baked
values meant an already-running app was unaffected if Vault went down after deploy). Every php-fpm
*restart* — not just every deploy — now needs Vault Agent to successfully re-authenticate and render
secrets, or php-fpm fails to start. Accepted tradeoff for a personal homelab with no real
availability requirement; would need `restart_on_secret_changes`/retry tuning or a fallback path in
a real production deployment.

Full detail on the app side: `Animal-Shelter-Workshop/docs/09-production-hardening.md`'s "Secrets
stopped touching disk entirely" section.

---

## Still Open

- ~~`Animal-Shelter-Workshop`'s Ansible playbook has been dry-run (`--check --diff`) against the
  live box... but not yet run for real.~~ — **resolved.** Run for real multiple times this session
  (see the Vault Agent section above), including a deliberate rollback-and-re-enable cycle to
  confirm `vault_agent_enabled: false` genuinely restores service.
- **A root-token value was pasted somewhere it didn't need to be during this work** (the cached
  `~/.vault-token` on `linux-vault` was used instead, so the pasted value was never actually
  needed). That token should be treated as burned — rotate/revoke it (`vault token revoke
  <token>`).
- **No renewal automation for the `secret_id`**, unlike the GH runner's token-renewal timer — by
  design (see Step 4), but worth revisiting if this WSL-driven deploy flow becomes frequent enough
  that a 90-day manual rotation gets annoying. The new `asw-app-server-agent` role shares this
  design (also no rotation automation, also `secret_id_ttl=0` for the same reason).
- **Vault still runs with `tls_disable = true`** (`docs/07-vault/vault-setup.md`). Fine behind
  Tailscale for DB-engine root passwords; now the app's own secrets (`APP_KEY` included) cross that
  same unencrypted listener too. Not blocking for a lab with no real data — noted, not fixed.
- ~~Secret rotation requires a manual php-fpm restart to take effect~~ — **wrong, corrected after
  real evidence.** When `db_password` was later patched in Vault (renaming the app's DB credential
  to `workshop_2_prod` — see `Animal-Shelter-Workshop/CLAUDE.md`'s Database Connection Mapping),
  php-fpm picked up the new value with no manual restart at all: `restart_on_secret_changes =
  "always"` (already in `agent-fpm.hcl`) means Vault Agent's own watcher detects the change and
  live-restarts the child process itself, invisible to systemd (`ActiveEnterTimestamp` on the unit
  never moved). Confirmed via `getenv('DB1_PASSWORD')` showing the new 15-char value over HTTP
  minutes after the Vault patch, with zero Ansible/systemd action taken in between.
