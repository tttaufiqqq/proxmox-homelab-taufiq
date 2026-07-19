# GitHub Actions Self-Hosted Runner — Setup Documentation

**Date:** 2026-07-19
**Container:** `linux-gh-runner`, CT ID `111` (Ubuntu 24.04 LTS, unprivileged LXC)
**Local IP:** `192.168.0.111` (static)
**Tailscale IP:** `100.72.6.40` — joined 2026-07-19
**Host Node:** `taufiq` (Proxmox VE 9.1.1)
**Serves:** [`Animal-Shelter-Workshop`](https://github.com/tttaufiqqq/Animal-Shelter-Workshop) CI/CD

---

## Why This Exists

`Animal-Shelter-Workshop` needs a CI runner that can reach its distributed DB
backend — `workshop-2` (MariaDB), `msi` (MySQL), `workshop-mysql` (MySQL 8.0),
and `workshop-postgres` (PostgreSQL), all only reachable over this lab's
Tailscale mesh, never on the public internet. GitHub-hosted runners can't
reach those addresses without either exposing DB ports publicly or joining
the runner to the tailnet with credentials stored in GitHub Secrets — both
worse than just hosting the runner here.

Threat model this setup is built around:

- **Repo stays private.** A self-hosted runner on a public repo lets anyone
  open a PR that runs arbitrary code on it — GitHub calls this out directly
  in their own docs. Non-negotiable given this CT can reach every DB in the
  lab.
- **No DB credentials in GitHub Secrets, ever.** Credentials are pulled from
  the lab's Vault (CT 110) at job runtime instead.
- **Outbound-only.** The runner polls GitHub over HTTPS; nothing needs an
  inbound port opened toward it from GitHub's side. Tailscale is also
  outbound/NAT-traversal based, so nothing in this path needs a public
  listener.

## CT vs VM Decision

Same call as `linux-vault` and `linux-mongodb`: **LXC container, not a VM.**
A GitHub Actions runner is a pure network/API workload — it polls GitHub,
then shells out to `git`/`mysql`/`psql`/`vault`. No special kernel features
needed, and the host is still capped at 4 cores regardless of the recent RAM
upgrade (see main README) — CPU, not memory, is the scarce resource here,
and a CT costs a fraction of a VM's CPU/RAM overhead for the same job.

---

## CT Specifications

| Component | Value |
|-----------|-------|
| CT ID | 111 |
| Type | LXC Container (Unprivileged) |
| Hostname | linux-gh-runner |
| OS | Ubuntu 24.04 LTS |
| CPU | 1 core |
| RAM | 1024 MB |
| Swap | 512 MB |
| Disk | 10 GiB |
| Local IP | `192.168.0.111/24` (static) |
| Gateway | `192.168.0.1` |
| Bridge | vmbr0 |
| Nameserver | `8.8.8.8` (explicit `pct set`, see Issue 5 — don't rely on Proxmox's default DNS injection) |
| Searchdomain | `local` |
| Tailscale IP | `100.72.6.40` |
| Tailscale Interface | `tailscale0` |
| SSH user | `linux-gh-runner` (sudo, key-only — root login and password auth both disabled) |

---

## Provisioning

```bash
# On the Proxmox host
pct create 111 local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
  --hostname linux-gh-runner \
  --cores 1 --memory 1024 --swap 512 \
  --net0 name=eth0,bridge=vmbr0,firewall=1,gw=192.168.0.1,ip=192.168.0.111/24,type=veth \
  --rootfs local:10 \
  --unprivileged 1 \
  --features nesting=1 \
  --ostype ubuntu

# TUN device passthrough — required for Tailscale in an unprivileged CT,
# same fix as linux-vault (see docs/07-vault/vault-setup.md)
echo 'lxc.cgroup2.devices.allow: c 10:200 rwm' >> /etc/pve/lxc/111.conf
echo 'lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file' >> /etc/pve/lxc/111.conf

pct start 111
```

DNS was set to `8.8.8.8` / `1.1.1.1` in `/etc/resolv.conf` from the start
this time, to avoid the "CT points at Tailscale DNS before Tailscale is
installed" trap that `linux-vault` hit — but this didn't actually stick;
see Issue 5 below for what broke and the real fix.

### Dedicated user + SSH hardening

Same pattern as the rest of the inventory — no direct root SSH anywhere:

```bash
useradd -m -s /bin/bash -G sudo linux-gh-runner
# authorized_keys gets the same lab-wide SSH key used everywhere else
echo 'linux-gh-runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/linux-gh-runner
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart ssh
```

Password auth was disabled here from the start — unlike `linux-vault`, which
was found still defaulted to `PasswordAuthentication yes` while auditing this
setup. Fixed same-day: disabled on `linux-vault` too (via `pct exec 110` from
the Proxmox host, since the `linux-vault` user doesn't have passwordless
sudo), `systemctl restart ssh`, then confirmed key-based SSH still worked
before moving on.

### Firewall

```bash
ufw allow from 192.168.0.0/24 to any port 22 proto tcp
ufw allow in on tailscale0 to any port 22 proto tcp
ufw --force enable
```

No other inbound rule needed — the runner only makes outbound connections
(to GitHub and to the DB hosts over Tailscale).

---

## Issues Encountered

### 1. `tailscale up --ssh` refused to run over an existing Tailscale SSH session
Attempted `tailscale up --ssh` out of habit (copied from muscle memory, not
actually needed here). It aborted with *"this action will reroute SSH
traffic to Tailscale SSH and will result in your session disconnecting"*.
Not needed anyway — this CT doesn't need to accept inbound Tailscale SSH,
regular SSH over the tailnet IP already works. Dropped the flag:
```bash
tailscale up --hostname=linux-gh-runner
```

### 2. `tailscale up` blocks on browser auth
No auth key was used (deliberately — an authkey is a standing credential
that doesn't expire on its own; a one-time interactive approval is safer for
a single provisioning event). `tailscale up` prints a login URL and blocks
until the device is approved from a browser. Approved manually via
`https://login.tailscale.com/a/...`, then the command completed.

### 3. `gpg: command not found` adding the HashiCorp apt key
Ubuntu 24.04's minimal template doesn't ship `gpg`. Same repo-add steps as
`vault-setup.md` failed at the `gpg --dearmor` step until `apt install -y
gpg` ran first.

### 4. Vault token TTL capped below what was requested
Asked for a 1-year token (`-ttl=8760h`); Vault capped it to **768h (32
days)** — the mount's `max_ttl` is lower than that. The token is renewable
(`token_renewable: true`). Automated the renewal — see "Vault Token Renewal"
below.

### 5. DNS broke again, later, after Tailscale started
The manual `/etc/resolv.conf` edit from provisioning didn't actually last.
Once real work started (installing Node, `apt install`), public DNS lookups
started failing — `Could not resolve host: archive.ubuntu.com`,
`deb.nodesource.com`, etc. `cat /etc/resolv.conf` showed:
```
# --- BEGIN PVE ---
search taile932d8.ts.net
nameserver 100.100.100.100
nameserver fd7a:115c:a1e0::53
# --- END PVE ---
```
Root cause: CT 111 was created without explicit `--nameserver`/
`--searchdomain` (unlike CT 108, which has `nameserver: 8.8.8.8` in its
`pct config`). Without that, Proxmox's own DNS injection (the `# --- BEGIN
PVE ---` block, regenerated on every container start) falls back to
whatever the **Proxmox host itself** resolves with — and the host's own
resolver is Tailscale's MagicDNS (`100.100.100.100`), since the host is on
the tailnet too. Editing `/etc/resolv.conf` inside the CT is pointless here;
Proxmox regenerates it from its own config on every boot. Real fix, from the
Proxmox host:
```bash
pct set 111 --nameserver 8.8.8.8 --searchdomain local
pct reboot 111   # config only applies at container start, not live
```
Confirmed after reboot: `/etc/resolv.conf` now shows `nameserver 8.8.8.8`,
public DNS resolves, and `tailscaled`/the runner service/the Vault renewal
timer all came back up on their own.

---

## GitHub Actions Runner Install

```bash
mkdir -p ~/actions-runner && cd ~/actions-runner
curl -o actions-runner-linux-x64.tar.gz -fsSL \
  https://github.com/actions/runner/releases/download/v2.328.0/actions-runner-linux-x64-2.328.0.tar.gz
tar xzf actions-runner-linux-x64.tar.gz

./config.sh --url https://github.com/tttaufiqqq/Animal-Shelter-Workshop \
  --token <registration-token-from-repo-Settings>Actions>Runners>New> \
  --unattended \
  --name linux-gh-runner \
  --labels self-hosted,linux,homelab,tailnet \
  --work _work

sudo ./svc.sh install linux-gh-runner
sudo ./svc.sh start
```

Registration tokens come from the repo's **Settings → Actions → Runners →
New self-hosted runner** page and are single-use, valid ~1 hour — never
stored anywhere after the `config.sh` run that consumes them.

Installed as a systemd service
(`actions.runner.tttaufiqqq-Animal-Shelter-Workshop.linux-gh-runner.service`)
running as `linux-gh-runner`, not root, so it survives reboots without a
login session.

### Baseline tooling installed on the runner

| Tool | Why |
|---|---|
| `git` | required by `actions/checkout` |
| `mysql` client | talks to the `shelter`/`animals` (MySQL) and `booking`/`reporting` (MariaDB) connections |
| `psql` client | talks to the `users` (PostgreSQL) connection |
| `jq` | parsing JSON in workflow steps |
| `vault` (v2.0.3, matching every other host in the lab) | pulling DB creds at job time — see below |

Deliberately **not** installed: PHP, Composer, Node, or any app-language
runtime. Those belong to whatever workflow file actually needs them, not the
base runner image — keeps this CT a generic runner rather than one coupled
to a specific app stack. Validated this holds up before committing to it:
manually installed Node 20 and ran `npx playwright install --with-deps
chromium` (needed for `Animal-Shelter-Workshop`'s Pest 4 browser tests) —
both worked, and a real headless Chromium launch actually rendered a page
with no sandbox/seccomp issues inside this unprivileged LXC. Removed both
again afterward; the workflow provisions them itself per-job via
`actions/setup-node`.

---

## Vault Integration — Scoped Token, Not the Root Token

Every other secret consumer in this lab (see `docs/07-vault/vault-setup.md`)
authenticates with the **root token**. That's fine for a human at a
terminal; it's too broad for a CI runner that executes whatever a workflow
file in the repo tells it to. This runner gets a purpose-built, read-only
policy instead:

```bash
# Run on linux-vault, using the root token
export VAULT_ADDR="http://192.168.0.110:8200"
export VAULT_TOKEN="<root-token>"

vault policy write gh-runner - <<'EOF'
path "secret/data/mysql" {
  capabilities = ["read"]
}
path "secret/data/mariadb" {
  capabilities = ["read"]
}
path "secret/data/postgres" {
  capabilities = ["read"]
}
EOF

vault token create -policy=gh-runner -orphan -ttl=8760h -display-name=linux-gh-runner
# capped to 768h (32 days) by the mount's max_ttl — see Issue 4 above
```

The resulting token can read exactly `secret/mysql`, `secret/mariadb`,
`secret/postgres` — nothing else. Verified:

```bash
$ vault kv get -field=host secret/mariadb
linux-mariadb.taufiq.lab
$ vault kv get secret/oracle
Code: 403. Errors: * 1 error occurred: * permission denied
$ vault kv get secret/minio
Code: 403. Errors: * 1 error occurred: * permission denied
```

Token is stored in `~/actions-runner/.env` on the runner (mode `600`,
readable only by `linux-gh-runner`), which the Actions runner service loads
into every job's environment automatically:

```
VAULT_ADDR=http://192.168.0.110:8200
VAULT_TOKEN=hvs.xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

A workflow step reads a secret with:
```bash
vault kv get -field=root_password secret/mariadb
```

### Vault Token Renewal

The token's 768h (32-day) TTL (Issue 4) is renewable but wasn't being
renewed by anything. Added a systemd timer on `linux-gh-runner`:

```bash
sudo tee /etc/systemd/system/vault-token-renew.service >/dev/null <<'EOF'
[Unit]
Description=Renew linux-gh-runner's scoped Vault token

[Service]
Type=oneshot
EnvironmentFile=/home/linux-gh-runner/actions-runner/.env
ExecStart=/usr/bin/vault token renew
EOF

sudo tee /etc/systemd/system/vault-token-renew.timer >/dev/null <<'EOF'
[Unit]
Description=Periodic renewal of linux-gh-runner's Vault token (768h max TTL)

[Timer]
OnBootSec=5min
OnUnitActiveSec=1d
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now vault-token-renew.timer
```

Runs daily — far more often than the 32-day TTL needs, but harmless, and
means any single missed run is never a problem. Verified the first manual
run renewed the token (`token_duration 767h40m10s`), and confirmed it
survives a full CT reboot (timer re-armed, next run scheduled).

---

## Reboot Test — 2026-07-19

`pct reboot 111` from the Proxmox host, run twice: once right after initial
setup, once again after the Issue 5 DNS fix (`pct set --nameserver`). Both
times, confirmed after boot with no manual steps:

- `tailscaled` active, reconnected on `100.72.6.40` with no re-authentication
- Runner systemd service active and polling GitHub again
- UFW active with the LAN/tailnet-only SSH rules intact
- `~/actions-runner/.env` (Vault token) intact
- (second reboot only) `/etc/resolv.conf` correctly shows `nameserver
  8.8.8.8`, public DNS resolves, `vault-token-renew.timer` re-armed

Full recovery both times, matching the bar set by `linux-vault`'s reboot
test.

---

## Notes

- CT chosen over VM — same reasoning as `linux-vault`/`linux-mongodb`: pure
  network/API workload, no dedicated kernel needed, and the host is still
  CPU-capped at 4 cores even after the RAM upgrade
- Repo (`Animal-Shelter-Workshop`) must stay **private** for as long as this
  runner is attached — a public repo + self-hosted runner is a known RCE
  vector via PRs
- Vault token is scoped read-only to `mysql`/`mariadb`/`postgres`, capped at
  768h by Vault's `max_ttl` — renewed automatically by a daily systemd timer
  (see "Vault Token Renewal" above)
- `linux-vault`'s `PasswordAuthentication yes` default, noticed while setting
  this up, has been fixed — disabled the same day, confirmed key-based SSH
  still works
- CT 111 needs explicit `nameserver`/`searchdomain` set via `pct set` (see
  Issue 5) — without it, Proxmox's DNS injection falls back to whatever the
  Proxmox host itself resolves with, which is Tailscale's MagicDNS here and
  doesn't forward public lookups
- DNS alias to add in dnsmasq on Proxmox host:
  `address=/linux-gh-runner.taufiq.lab/100.72.6.40`
- No `~/.ssh/config` alias exists yet for `linux-vault` or `linux-gh-runner`
  — connecting to either currently requires the raw Tailscale/LAN IP with an
  explicit `linux-vault@`/`linux-gh-runner@` user prefix
