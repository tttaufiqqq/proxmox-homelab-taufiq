# MongoDB LXC Setup

**Container:** `linux-mongodb`, CT ID `108` (Ubuntu 24.04 LTS, unprivileged LXC)
**Local IP:** `192.168.0.108` (static)
**Tailscale IP:** `100.82.200.94` — joined 2026-07-17, `mongod` bound to it and reachable
on port 27017 over Tailscale as of the same day. DNS: `linux-mongodb.taufiq.lab` /
`mongodb.taufiq.lab`.
**Purpose:** First NoSQL engine in the lab. Document store for semi-structured data that
doesn't fit cleanly into the existing relational schemas, without forcing it into a
rigid table structure up front.

## Why This Exists

Every engine in this repo up to this point is relational (Oracle, MySQL, MariaDB,
PostgreSQL, SQL Server). MongoDB fills a different gap: data that's genuinely
document-shaped rather than tabular, where a rigid SQL schema would mean either
constant migrations or a lot of nullable columns as the shape of the data varies.

Also intentionally chosen as an **LXC container, not a VM**. The host is capped at
4 cores, and every full VM costs several hundred MB just for its own kernel and init
system before the actual workload starts. A CT running MongoDB directly gets the same
functionality for a fraction of the memory footprint, and given the plan is for this to
run persistently rather than on-demand like the other DB engines, that overhead
difference adds up.

---

## What's Installed

| Component | Version | Notes |
|---|---|---|
| MongoDB | 8.0.26 (`mongodb-org`) | Official repo, not Ubuntu's bundled version |
| mongosh | 2.9.2 | MongoDB shell, installed as a dependency of `mongodb-org` |
| mongodb-database-tools | 100.17.0 | `mongodump`/`mongorestore` etc., installed as a dependency |
| UFW | system default | Firewall, scoped to LAN for the DB port |

---

## Provisioning — 2026-07-14

CT `108` created via the Proxmox web UI: 1 core, 1024 MB RAM, 512 MB swap, 8 GB disk,
unprivileged, `ubuntu-24.04-standard` template, static IP `192.168.0.108/24`, gateway
`192.168.0.1`, DNS set to "use host settings" at creation time (later overridden — see
below).

Root SSH login was disabled after creating a dedicated `linux-mongodb` user with sudo
and the same SSH key already in use elsewhere in the lab, following the same pattern as
the rest of the inventory (no direct root SSH anywhere).

### What it took to get from "CT created" to "MongoDB actually running" — six real
issues, in the order they were hit:

1. **CT Templates dropdown was empty during `Create CT`.** Turned out to be a wrong
   location, not a bug — CT templates are downloaded from **`local (taufiq)` storage →
   CT Templates tab**, not from the Node-level **Disks** view (that's physical disk
   management, a completely different part of the UI that happens to sit nearby in the
   sidebar).

2. **Storage dropdown on the `Create CT → Disks` tab was empty**, even after the
   template was correctly selected. Root cause: the `local` storage pool didn't have
   **Container** enabled under its allowed **Content** types — ISO and CT Template
   content being enabled doesn't imply Container (disk image) content is. Fixed via
   **Datacenter → Storage → local → Edit → Content**, checking **Container**.

3. **Network tab rejected the IPv4 address** (`192.168.0.9`) until the CIDR suffix was
   added (`/24`). Also caught before finishing: the Gateway field was left blank on the
   first pass, which would have left the CT unable to route anywhere outside its own
   subnet. Final CT ID (`108`) and IP were also made to match (`192.168.0.108`) after an
   earlier attempt used a mismatched `.109`, to keep the inventory table's ID/IP
   convention consistent.

4. **`apt upgrade` interrupted mid-install (Ctrl+C).** Left `curl` and `gnupg` in a
   half-installed state — `apt` had listed them as "to be installed" but the process
   never completed, so subsequent commands failed with `curl: command not found` /
   `gpg: command not found` despite no error being reported at the time. Fix was just
   re-running the install and letting it finish uninterrupted.

5. **`apt update` hung at `0% [Working]`**, which looked like a general connectivity
   problem but wasn't — `ping 8.8.8.8` worked fine, `ping google.com` didn't return at
   all. Root cause: `/etc/resolv.conf` had inherited the Proxmox host's DNS settings
   (`use host settings` on the Network tab), which pointed at Tailscale's MagicDNS
   resolver (`100.100.100.100`). The host is a Tailscale node and uses that resolver
   correctly; this CT was never joined to Tailscale, so that address was simply
   unreachable from inside it — DNS lookups silently failed while raw IP connectivity
   looked fine, which is what made it confusing at first. Fixed two ways: a manual
   `/etc/resolv.conf` override inside the CT for the immediate unblock (`8.8.8.8`,
   `1.1.1.1`), then the persistent fix at the Proxmox level —
   `pct set 108 --nameserver 8.8.8.8 --searchdomain local` — run from the **host** shell,
   not from inside the CT (`pct` doesn't exist inside the container itself, an easy mix-up
   when jumping between the Proxmox console and an SSH session to the CT in the same
   sitting).

6. **`mongod` failed to start with exit code 48** (`EXIT_NET_ERROR`) after the first
   `bindIp` edit. The config listed three addresses:
   `bindIp: 127.0.0.1,192.168.0.108,100.100.123.90` — the third being the Proxmox
   **host's** Tailscale IP, copied in from the plan to eventually expose MongoDB over
   Tailscale too. Since this CT isn't a Tailscale node (see issue 5), that address
   doesn't exist on any of its interfaces, and MongoDB refuses to start if it can't bind
   every address listed. Fixed by dropping the Tailscale IP from `bindIp` until the CT
   is actually joined to the tailnet as its own node — LAN-only access
   (`127.0.0.1,192.168.0.108`) is enough for now.

One more near-miss worth recording even though it didn't cause an outage: after adding
a UFW rule for MongoDB's port and running `ufw enable`, `ufw status` showed **only** the
`27017/tcp` rule — no explicit allow for port 22. Since UFW's policy on this CT wasn't
confirmed to default-allow SSH, this was one reboot away from a self-inflicted lockout
(console access via Proxmox would've still worked as a fallback, but not ideal). Added
`sudo ufw allow 22/tcp` explicitly before treating the firewall as done — worth checking
first on any future CT before calling `ufw enable`, rather than after.

A smaller config bug during auth setup, separate from the six above: uncommenting
`security:` to enable authorization initially left the key itself still commented out
(`#security:`) while only the nested `authorization: enabled` line underneath it was
added — an orphaned line with no active parent key. `mongod` failed to start
(`ECONNREFUSED` on the expected port) until `security:` itself was uncommented.

### Tailscale join — 2026-07-17

`tailscale up` inside the CT failed with `failed to connect to local tailscaled ...
Got error: 503 Service Unavailable: no backend`, even though `tailscaled` itself showed
as `active` in systemd. Same root cause already hit and fixed on the Vault CT (see
[`docs/07-vault/vault-setup.md`, issue 6](../07-vault/vault-setup.md#6-tailscale-tun-device-missing)):
an unprivileged LXC container doesn't get `/dev/net/tun` by default, so `tailscaled`
starts but can't bring up its backend. Fixed the same way, from the Proxmox host:

```bash
echo 'lxc.cgroup2.devices.allow = c 10:200 rwm' >> /etc/pve/lxc/108.conf
echo 'lxc.mount.entry = /dev/net/tun dev/net/tun none bind,create=file' >> /etc/pve/lxc/108.conf
pct reboot 108
```

After reboot, `/dev/net/tun` existed inside the container and `tailscale up` produced a
normal login link instead of the 503. Authenticated via that link — CT now shows in
`tailscale status` as `linux-mongodb` at `100.82.200.94`.

### Binding mongod to Tailscale — same day

Joining the tailnet only makes the container itself reachable — `mongod` still needed
`net.bindIp` updated to include the new address, and UFW still needed a rule for it
(the existing `27017/tcp` allow was scoped to `192.168.0.0/24` only, which doesn't cover
Tailscale's `100.64.0.0/10` CGNAT range). Both applied on the Proxmox host via `pct exec`:

```bash
# bindIp
sed -i 's/bindIp: 127.0.0.1,192.168.0.108/bindIp: 127.0.0.1,192.168.0.108,100.82.200.94/' /etc/mongod.conf

# firewall — scoped to the tailscale0 interface rather than a CIDR range
ufw allow in on tailscale0 to any port 27017 proto tcp

systemctl restart mongod
```

Verified with `ss -tlnp | grep 27017` — `mongod` listening on `127.0.0.1`,
`192.168.0.108`, and `100.82.200.94` simultaneously — and a TCP test from the Windows
client to `100.82.200.94:27017` over Tailscale succeeded.

**Side effect of joining the tailnet:** `tailscaled` now manages `/etc/resolv.conf`
directly (`nameserver 100.100.100.100`, Tailscale's MagicDNS resolver), overriding the
manual `8.8.8.8`/`1.1.1.1` override applied earlier for issue 5. This is an upgrade, not
a regression — MagicDNS forwards both `taufiq.lab` (via the same Split DNS rule every
other node uses) and public lookups correctly, confirmed with `getent hosts
linux-oracle-db.taufiq.lab` and `getent hosts google.com` both resolving.

**Reboot test (hardening pass) — 2026-07-17:** `pct reboot 108` from the Proxmox host.
Confirmed after boot: `mongod` active and listening on all three bound addresses,
`tailscaled` active and reconnected without re-authentication, UFW active with both
rules, DNS resolution intact. Full recovery, no manual steps required.

---

## Final Working Config

`/etc/mongod.conf` (relevant sections):

```yaml
storage:
  dbPath: /var/lib/mongodb

net:
  port: 27017
  bindIp: 127.0.0.1,192.168.0.108,100.82.200.94

security:
  authorization: enabled
```

UFW:

```
27017/tcp                 ALLOW    192.168.0.0/24
22/tcp                    ALLOW    Anywhere
27017/tcp on tailscale0   ALLOW    Anywhere
```

DNS override at the Proxmox level (`pct config 108`):

```
nameserver: 8.8.8.8
searchdomain: local
```

---

## Users

| User | DB scope | Role | Purpose |
|---|---|---|---|
| `linux-mongodb` | `admin` | `root` | Full admin, used for user management and firewall/config verification |
| `development` | `glm_logs` (test database) | `readWrite` | Scoped, lower-privilege user for day-to-day/application use, no admin privileges |

> **Note:** passwords were deliberately kept identical across both users for this
> initial experimental setup, and were shared in plaintext during setup, so should be
> treated as already burned. Fine for the current lab-only, no-real-data stage; worth
> rotating to distinct, non-shared credentials per user before this holds anything
> that actually matters, so a leaked app-level credential doesn't also hand over root.

---

## DataGrip Connection

Added as a new MongoDB data source (`proxmox-linux-mongodb`) in DataGrip, alongside the
other relational connections — full screenshot and details in
[`docs/03-datagrip/datagrip-connectivity.md`](../03-datagrip/datagrip-connectivity.md#mongodb-linux-mongodb):

- **Host:** `192.168.0.108` (screenshot predates the Tailscale join — `linux-mongodb.taufiq.lab`
  and `100.82.200.94` both work now too)
- **Port:** `27017`
- **Database:** `glm_logs`
- **User / Password:** `development` / (see note above on shared credentials)
- **Driver:** MongoDB JDBC Driver 1.23 (JDBC4.2), auto-downloaded on first use

**Test Connection: Succeeded** — MongoDB 8.0.26.

---

## Not Done Yet

- **Per-service credential separation**, per the note under Users above.
- **Schema/collection conventions** — no documents have been written yet, this doc only
  covers getting the engine itself online and reachable.
