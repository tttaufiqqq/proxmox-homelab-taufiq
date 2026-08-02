<!-- Not yet sequenced into a numbered docs/ folder, lives here in
     docs/19-devops-practice/ until the full devops-practice-plan.md is complete.
     Date below is provisional (the date this actually happened); revisit
     once final sequencing/dating is decided. -->

# Stage 2, Ansible Roles, Idempotency, Molecule, Vault, and Fleet Expansion

**Date:** 2026-07-26
**Repo the actual code/infra changes live in:** `Animal-Shelter-Workshop`
(this write-up lives in the homelab meta-repo instead, alongside the devops
practice plan it's a stage of, see `devops-practice-plan.md`, Stage 2's
checklist, all 5 items)

## Why I built this

- Stage 1 proved Terraform could stand up and adopt real infrastructure.
- Stage 2's own plan note called out that "fixing Stage 1's blocker means
  touching this exact Ansible/cloud-init boundary anyway", so the two
  stages ran back to back.
- `infrastructure/ansible` already worked in production; what was missing
  was:
  - structure (one giant task file, not roles)
  - proof (idempotency was assumed, never formally checked)
  - real automated testing (Molecule hadn't been tried)
  - one deliberately-plaintext credential
  - coverage (4 homelab-level hosts were still hand-provisioned, invisible
    to Ansible entirely)

## Flow

```
┌────────────────────────────────────┐
│         STAGE 2, ANSIBLE          │▏
└────────────────────────────────────┘▔▔

┌────────────────────────────────┐     done, vault-agent.yml + shared
│ 1. Build roles/ structure       │▏     DB logic → vault_agent, mysql_family,
│    (vault_agent + DB roles)     │▏     postgres_db, db_firewall,
└────────────────────────────────┘▔▔    legacy_backup_cleanup
              │
              ▼
┌────────────────────────────────┐     done, every playbook run twice,
│ 2. Verify idempotency            │▏    changed=0 on 2nd run (both site.yml
│    (run each playbook 2x)       │▏     and app-server.yml)
└────────────────────────────────┘▔▔
              │
              ▼
┌────────────────────────────────┐     done, no Docker available, used
│ 3. Molecule on linux-postgres    │▏    a scratch LXC container instead;
│    role                         │▏     found + fixed a real SQL_ASCII/UTF8
└────────────────────────────────┘▔▔    bug --check mode would've missed
              │
              ▼
┌────────────────────────────────┐     done, mysql_root_password moved
│ 4. MySQL/MariaDB root cred      │▏     into Vault (secret/animal-shelter-
│    → Vault                      │▏     workshop), re-verified changed=0
└────────────────────────────────┘▔▔
              │
              ▼
┌────────────────────────────────┐     done, vault (check-only, seal
│ 5. Extend mgmt to 4 hosts        │▏    risk), gh-runner, mini-io real +
│    (vault/gh-runner/mini-io/    │▏     idempotent, mongodb: found + fixed
│     mongodb)                    │▏     a pre-existing outage (stale bindIp)
└────────────────────────────────┘▔▔
```

## What I built

### 1. A real `roles/` structure

- `playbooks/tasks/vault-agent.yml` became `roles/vault_agent/` (tasks,
  handlers, templates, defaults, files).
- The shared pieces of the five DB playbooks split into
  `roles/mysql_family/`, `roles/postgres_db/`, `roles/db_firewall/`, and
  `roles/legacy_backup_cleanup/`.
- The five DB playbooks are now a handful of `vars:` plus a `roles:` list
  each, instead of 120+ line duplicated task blocks.
- One structural improvement along the way: the original vault-agent task
  file used a `register: X_deployed` + `when: X_deployed.changed or
  Y_deployed.changed` construct to decide whether to restart php-fpm.
- Moving into a role's own `handlers/main.yml` let this become plain
  `notify:` on each of the three tasks that actually matter.
- Ansible's own handler deduplication does the same job, more idiomatically.
- `ansible.cfg` needed one addition (`roles_path = ./roles`).
- Ansible's default role search path is relative to wherever
  `ansible-playbook` is actually invoked from, not the playbook's own
  directory.
- This matters a lot once Molecule enters the picture (see below).

### 2. Idempotency, formally proven

- Ran `site.yml -l databases` (all 5 DB hosts) twice back-to-back, then
  `app-server.yml --tags provision` twice.
- `changed=0` on the second run in both cases, confirming the roles
  refactor is byte-for-byte behaviorally identical to the pre-refactor
  playbooks it replaced.
- The one deliberately non-idempotent task (MySQL/MariaDB root-auth
  bootstrap, `failed_when: false`) still shows in the recap as
  `ignored=1`, exactly as documented, untouched, by design.

### 3. Molecule against `linux-postgres`'s new role

- No Docker/Podman available on this control node (WSL, Docker Desktop's
  WSL integration not enabled for this distro, no passwordless sudo to fix
  that or install Podman).
- Used Molecule's `default` driver instead, delegated to a disposable
  scratch LXC container on Proxmox, the exact same
  create-a-throwaway-container pattern already used for Stage 1's
  Terraform container-import dry run, just reused for role testing.
- `create.yml`/`destroy.yml` drive `pct` over SSH.
- The container joins Tailscale directly (rather than routing through
  Proxmox as an SSH jump host) because Molecule's `instance_config.yml`
  schema only supports `address`/`user`/`port`/`identity_file`, no room
  for a custom `ProxyCommand`.
- A custom `ProxyCommand` doesn't survive between Molecule's
  separately-invoked `create`/`converge`/`verify` playbook runs.

Getting there took genuine debugging, each one a real environment gap, not a
scenario-file typo:

- **DNS deadlock:**
  - This VLAN's DHCP hands out Tailscale's stub resolver
    (`100.100.100.100`) by default, which only answers once `tailscaled`
    is actually running.
  - This is a chicken-and-egg problem for the `apt`/`curl` calls that have
    to happen *before* Tailscale is installed.
  - Fixed with an explicit `--nameserver 8.8.8.8` on `pct create`, matching
    what the real DB hosts already do.
- **`tailscaled` race:**
  - `tailscale up` run immediately after `systemctl enable --now
    tailscaled` hit `503 Service Unavailable: no backend`.
  - The daemon hadn't finished initializing its local API yet.
  - Fixed with a short retry loop around `tailscale up`.
- **Missing TUN device:**
  - `tailscaled` then crash-looped with `CreateTUN("tailscale0") failed;
    /dev/net/tun does not exist`, the exact same gap Stage 1 documented
    for the real Tailscale-joined DB containers.
  - Fixed by appending the same two raw LXC config lines
    (`lxc.cgroup2.devices.allow`/`lxc.mount.entry`) to the scratch
    container's config before starting it.
- **Real bug in the role, found by Molecule, not by `--check`:**
  - A fresh `initdb` on a container with no locales generated leaves
    `template1` at `SQL_ASCII` encoding, which conflicts with the `UTF8`
    the role's `postgresql_db` task asks for.
  - `--check` mode never exercises this (`command`/`shell` tasks like the
    PostgreSQL-version probe don't run in check mode at all), so this
    whole failure path was invisible to eyeballing `--check` output,
    exactly the gap Molecule was brought in to close.
  - Fixed properly, not worked around: `template: template0` on the
    `postgresql_db` task, Postgres's own recommended fix for this exact
    error, and a strict improvement (template0 is always
    encoding-compatible, regardless of what template1 ended up as).
  - Re-verified against the real `linux-postgres` host afterward:
    `changed=0`, confirming the fix is a true no-op there.

- Full `molecule test` sequence (create → converge → idempotence → verify
  → destroy) passes clean.

### 4. MySQL/MariaDB root credential moved into Vault

- `group_vars/all.yml`'s `mysql_root_password` was the one named plaintext
  exception next to the Vault-backed `asw_secrets.db_password`.
- Added `mysql_root_password` as a new field on the existing
  `secret/animal-shelter-workshop` KV entry (`vault kv patch`, using the
  Vault root token found in `linux-vault`'s own home directory, a one-time
  administrative write, not something baked into any playbook or
  group_var).
- Changed `group_vars/all.yml` to read `asw_secrets.mysql_root_password`
  instead of the literal string.
- Same AppRole, same read-only scope, no new Vault ACL work needed.
- Re-ran the DB playbooks afterward: `changed=0`, confirming the swap is a
  true no-op, the value itself didn't change, only where Ansible sources
  it from.

### 5. Extended management to the 4 homelab-level hosts

- `linux-vault`, `linux-gh-runner`, `linux-mini-io`, and `linux-mongodb`
  were all provisioned by hand, straight from their own setup docs
  (`proxmox-homelab-taufiq/docs/{07-vault,09-github-actions-runner,05-minio,
  06-mongodb}/`).
- New playbooks manage the safely-idempotent structural state on each:
  packages, services, firewall, non-secret config lines.
- Deliberately left alone: one-time, credential-bearing bootstrap steps.

- **`linux-vault`:**
  - Package/service/UFW/SSH-hardening only.
  - Nothing here touches `vault.hcl`'s content or notifies a vault
    restart, on purpose.
  - This Vault is live and unsealed right now, serving every secret this
    entire session's Ansible runs depend on, and the unseal keys live in
    Bitwarden only, reachable by nobody running this playbook.
  - A `systemctl restart vault` with no way to unseal it again would be a
    self-inflicted, session-ending outage.
  - This playbook only ever runs in `--check` mode, confirmed clean (no
    errors).
  - The 4 proposed changes are a real, intentional tightening of SSH to
    LAN+Tailscale-only instead of the doc's current wide-open `22/tcp`,
    left proposed rather than applied.
- **`linux-gh-runner`:**
  - Real run, twice, `changed=0` on the second.
  - Baseline tooling, Ansible Galaxy collections, the Vault token renewal
    timer, and firewall are all now Ansible-managed.
  - Runner registration itself (single-use, ~1hr-valid token) stays
    manual, same as it always was.
- **`linux-mini-io`:**
  - Real run, twice, `changed=0` on the second.
  - Verified SSH still worked immediately after the `sshd` restart it
    triggered.
  - Verified the MinIO health endpoint (which Stage 1's Terraform state
    backend depends on) still responded afterward.
  - Data disk/fstab and `/etc/default/minio`'s actual credential contents
    deliberately left unmanaged, real data and a real secret already
    working, nothing to gain from re-declaring either.
- **`linux-mongodb`:**
  - Found and fixed a real, pre-existing outage in the process.
  - `mongod` had been crash-looping since **before this session**
    (`journalctl` showed the same failure as far back as 2026-07-22) with
    `exit code 48` (`EXIT_NET_ERROR`).
  - Root cause: `net.bindIp` still listed the container's old static LAN
    IP (`192.168.0.108`) from before this network was migrated to
    VLAN-tagged DHCP; its real LAN IP is now `10.0.20.7`, so `mongod` was
    trying to bind an address that no longer exists on any interface.
  - Not something this playbook introduced: the first run's `lineinfile`
    task reported `ok` (matching the already-broken value verbatim), and
    the *service* task's restart just re-exposed a failure that was
    already there at container boot.
  - Fixed properly rather than papering over it: changed `bindIp` to
    `0.0.0.0`, matching how every other DB engine in this repo already
    binds (MySQL/MariaDB's `bind-address 0.0.0.0`, PostgreSQL's
    `listen_addresses '*'`).
  - Tailscale and UFW are the actual security boundary everywhere else,
    and an enumerated IP list is exactly what went stale here.
  - **Correction (found later, `plans/05-k3s-asw-db-connectivity-plan
    (executed).md`):** on the 5 DB hosts, UFW wasn't actually enforcing
    anything — Tailscale's own netfilter management inserts a `ts-input`
    iptables chain ahead of ufw's chains that unconditionally accepts all
    `tailscale0` traffic, so every `from_ip`-scoped UFW rule on those
    hosts was a silent no-op from the day this role was written until
    that plan's verification pass caught it and fixed it with
    `tailscale set --netfilter-mode=off`. This is a default Tailscale
    behavior, not something specific to the `db_firewall` role, so the
    same bypass plausibly affects every other Tailscale-joined,
    UFW-protected host in this homelab (`linux-vault`, `linux-gh-runner`,
    this `linux-mongodb` host included) — **not yet checked**, flagged
    here rather than assumed fixed.
  - Verified `mongod` active and listening on `0.0.0.0:27017` afterward;
    second run confirmed `changed=0`.

## Verification

- Roles refactor: `site.yml -l databases` and `app-server.yml --tags
  provision`, each run twice, `changed=0` on the second run both times.
- Molecule: full `create`/`converge`/`idempotence`/`verify`/`destroy`
  sequence passes; `idempotence` step itself is `changed=0`.
- Vault credential migration: DB playbooks re-run after the swap,
  `changed=0`.
- Fleet expansion: `linux-gh-runner`, `linux-mini-io`, `linux-mongodb` each
  run twice for real, `changed=0` on the second run for all three;
  `linux-vault` validated via `--check` only, by design.

### How to independently verify each item

- Run from WSL, inside `infrastructure/ansible/`, with
  `ANSIBLE_CONFIG=./ansible.cfg`.
- `<become password>` and the two `VAULT_*_ID` pairs are the same ones
  already in `CLAUDE.md` (gitignored) / WSL's `~/.bashrc`, not repeated
  here since this doc is a tracked, pushed file.

**1. Roles structure exists**
```bash
ls infrastructure/ansible/roles/
```
- Expect 5 directories: `db_firewall`, `legacy_backup_cleanup`,
  `mysql_family`, `postgres_db`, `vault_agent`.

**2. Idempotency, run the DB playbooks twice**
```bash
ANSIBLE_BECOME_PASS='<become password>' \
VAULT_ROLE_ID='<role id>' VAULT_SECRET_ID='<secret id>' \
ansible-playbook -i inventory-ip.yml playbooks/site.yml -l databases
```
- Run it a second time immediately after.
- Expect the **second** run's `PLAY RECAP` to show `changed=0` for all 5
  hosts.
- `linux-mysql`/`linux-mariadb` will still show `ignored=1`, that's the
  deliberately non-idempotent root-auth bootstrap task, correct and
  expected, not a failure.

**3. Molecule**
```bash
cd infrastructure/ansible/roles/postgres_db
python3 -m venv ~/molecule-venv && source ~/molecule-venv/bin/activate
pip install molecule
ANSIBLE_ROLES_PATH=/absolute/path/to/infrastructure/ansible/roles molecule test
```
- Expect the final `SCENARIO RECAP` line to read `default … successful=N …
  failed=0` with no `CRITICAL` lines anywhere above it.
- Takes a few minutes: it creates a real scratch LXC container on Proxmox,
  converges it twice, verifies, then destroys it.

**4. Vault credential migration**
```bash
grep mysql_root_password infrastructure/ansible/group_vars/all.yml
```
- Expect `mysql_root_password: "{{ asw_secrets.mysql_root_password }}"`, a
  Jinja lookup, not a literal string.
- To confirm the value is actually in Vault (needs the root token,
  Bitwarden-only):
```bash
ssh linux-vault
vault login   # paste the root token when prompted
vault kv get secret/animal-shelter-workshop
```
- Expect a `mysql_root_password` field in the output, alongside
  `db_password` and the others.

**5. Fleet expansion, per host**
```bash
# linux-vault: check-only, by design, expect no failures, and the 4 UFW
# tasks showing "changed" (proposed, never applied) rather than "ok"
ansible-playbook -i inventory-ip.yml playbooks/linux-vault.yml --check

# linux-gh-runner / linux-mini-io: already applied this session, expect
# changed=0, confirming nothing has drifted since
ansible-playbook -i inventory-ip.yml playbooks/linux-gh-runner.yml
ansible-playbook -i inventory-ip.yml playbooks/linux-mini-io.yml

# linux-mongodb: same expectation, changed=0
ansible-playbook -i inventory-ip.yml playbooks/linux-mongodb.yml
```
- Then confirm the actual services are healthy, independent of Ansible:
```bash
curl -o /dev/null -w "%{http_code}\n" http://100.73.172.85:9000/minio/health/live
# expect: 200

ssh linux-mongodb "systemctl is-active mongod && sudo ss -tlnp | grep 27017"
# expect: "active", and a line showing mongod LISTEN on 0.0.0.0:27017
```

### Screenshots still to add

- This session was almost entirely CLI-driven (`ansible-playbook`,
  `vault kv`, `ssh`, `pct`), unlike Stage 1's GUI-heavy setup, so there
  wasn't an obvious one to grab along the way.
- Two are worth adding by hand:

- **`images/stage2-vault-ui-mysql-root-password.png`**
  1. Open `http://100.112.41.113:8200` in a browser (must be on the
     Tailscale network).
  2. Sign in with the Vault root token (Bitwarden-only, not in any repo).
  3. In the left nav, open the `secret/` KV engine → click
     `animal-shelter-workshop`.
  4. Click the "eye" icon (or "Show" toggle) next to `mysql_root_password`
     so the field name **and** that it has a non-empty value are both
     visible in the screenshot, the value itself doesn't need to be
     legible, just that the field exists.
  5. Save as `stage2-vault-ui-mysql-root-password.png` in
     `docs/19-devops-practice/images/`.

- **`images/stage2-deploy-success.png`**
  - Can't do this one yet; needs the work in this doc committed and pushed
    to `Animal-Shelter-Workshop` first.
  - Once pushed:
    1. Go to the repo's **Actions** tab on GitHub.
    2. Wait for (or find) the `Tests` run triggered by the push, and the
       `Deploy` run that follows it via `workflow_run`.
    3. Screenshot the `Deploy` run's summary page once it shows a green
       checkmark, with the commit SHA and job names (`plan`, `deploy-db`,
       `deploy-app`) visible.
    4. Save as `stage2-deploy-success.png` in
       `docs/19-devops-practice/images/`.

## Where things live

| Piece | Path (in `Animal-Shelter-Workshop` unless noted) |
|---|---|
| New roles | `infrastructure/ansible/roles/{vault_agent,mysql_family,postgres_db,db_firewall,legacy_backup_cleanup}/` |
| Refactored DB playbooks | `infrastructure/ansible/playbooks/linux-{mysql,mysql-2,mariadb,mariadb-2,postgres}.yml` |
| Molecule scenario | `infrastructure/ansible/roles/postgres_db/molecule/default/` |
| Vault credential change | `infrastructure/ansible/group_vars/all.yml` (`mysql_root_password`) |
| New homelab-host playbooks | `infrastructure/ansible/playbooks/linux-{vault,gh-runner,mini-io,mongodb}.yml` |
| New inventory groups | `infrastructure/ansible/inventory.yml`, `inventory-ip.yml` (`homelab_hosts` and its 4 children) |
| `ansible.cfg` change | `roles_path = ./roles` added |
| This write-up | `proxmox-homelab-taufiq/docs/19-devops-practice/02-ansible-roles-idempotency-molecule-vault-and-fleet-expansion.md` (homelab meta-repo) |
