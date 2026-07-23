# Homelab Network Segmentation — Execution Plan

This is my blueprint for splitting my Proxmox homelab from one flat network into
properly segmented VLANs and subnets. Written down here so I (or anyone reading
my repo later) understands not just *what* I built, but *why* I made each call.

Current state: 1 physical Proxmox node ("taufiq"), 8 VMs, 5 CTs (13 guests
total, see the ID table in Execution Steps below — this grew from the
original 10 VMs / 1 CT count as the lab expanded), all on one flat network
today. This plan is designed to also work once I add a second physical
Proxmox node and a managed switch later, without needing a redesign.

---

## My Final VLAN / Subnet Table

| VLAN | Name | Subnet | What lives here |
|---|---|---|---|
| 10 | Management | `10.0.10.0/24` | Proxmox host UI, future cluster/corosync traffic |
| 20 | Database tier | `10.0.20.0/24` | All DB engines (MySQL, MariaDB, Postgres, Oracle, MongoDB, MSSQL), on any physical node |
| 30 | App / Secrets / Storage | `10.0.30.0/24` | Spring Boot app, Vault, MinIO, CI/CD runner |
| 40 | Personal / Misc | `10.0.40.0/24` | app-server (Animal Shelter Workshop) |
| 50 | *(reserved)* Ceph | `10.0.50.0/24` | Not used yet — for Ceph storage replication once I add node 2 |
| 60 | *(reserved)* DMZ | `10.0.60.0/24` | Not used yet — for any future public-facing service besides Spring Boot |
| 70 | *(reserved)* Media / Personal services | `10.0.70.0/24` | Not used yet — for Jellyfin or similar self-hosted apps |
| 80 | *(reserved)* Observability | `10.0.80.0/24` | Not used yet — for Prometheus/Grafana/Loki when I build that out |
| 999 | Native / dead-end | *(no subnet, no devices ever)* | Trunk port native VLAN — deliberately empty |

I numbered these 10/20/30 instead of 1/2/3 on purpose, so I can slot a new VLAN
in between two existing ones later (like a `15`) without renumbering everything
that already exists.

---

## Decisions I Made, and Why

### 1. VLANs + Subnets together, not just one
A VLAN alone isolates devices at the switch level but doesn't organize
addressing. A subnet alone organizes addressing but doesn't stop anything from
talking to anything else on the same flat switch. I need both: the VLAN
enforces the isolation, the subnet gives each isolated group its own address
range so my router can actually tell them apart and route between them
correctly.

### 2. Router VM will run OPNsense, not a plain Linux box
I originally planned a generic Linux VM running nftables as my router. I've
since decided the router VM will run **OPNsense** instead. Reasoning: OPNsense
gives me a proper firewall GUI, VPN support, and logging/reporting out of the
box, on top of doing the same inter-VLAN routing job. It's free with no
licensing catches (unlike pfSense Plus, which requires a paid subscription off
Netgate's own hardware), gets frequent updates, and has a cleaner interface for
someone learning this for the first time.

**This means my firewall rules live inside OPNsense's own rule engine (built on
FreeBSD's `pf`), not raw nftables.** I'm noting this here because nftables was
my original plan before I decided on OPNsense specifically as the router OS —
OPNsense supersedes that, I don't need to hand-write nftables rules on a
separate Linux router now.

### 3. Router VM must be a VM, not a CT
This isn't really a choice, it's a hardware fact: OPNsense is FreeBSD-based,
and Proxmox CTs (LXC) only support Linux, since containers share the host's
Linux kernel. There's no way to run a FreeBSD OS inside an LXC container. So
the router has to be a full VM regardless of which firewall OS I'd picked.

### 4. Native VLAN on trunk ports = 999, deliberately unused
This protects against VLAN hopping (double-tagging attacks), where a crafted
packet exploits a switch stripping the "native" untagged VLAN and exposes an
inner tag to a VLAN it shouldn't reach. If the native VLAN is a real VLAN with
real devices on it (like the default VLAN 1), that attack has somewhere to
land. If the native VLAN is a number nothing is ever assigned to, the attack
has nowhere to go.

### 5. Tailscale stays on every VM (accepted tradeoff)
Tailscale connects directly to a device over its own overlay tunnel,
completely bypassing my VLAN/firewall rules, since those only govern LAN
traffic. Technically this means my segmentation only protects against
LAN-based lateral movement, not anyone with tailnet access. Since this is my
personal experiment lab and I'm the only one with tailnet access, I've decided
to keep Tailscale on all VMs for convenience rather than restricting it to a
subset of services. This is a deliberate accepted tradeoff, not an oversight.

### 6. IPs assigned via DHCP reservations by MAC, not static config per VM
Rather than manually setting a static IP inside every single VM, I'm reserving
each VM's IP centrally, keyed to its MAC address. This gives me the same
reliability as static IPs (my firewall rules always match the right VM)
without having to touch each VM's own network config individually.

**Where that reservation lives changed since this decision was first written:**
I originally planned to keep it in dnsmasq. Decision 11 supersedes that —
the reservations now live in OPNsense's per-VLAN DHCP server instead, since
dnsmasq never actually did DHCP to begin with (it's Tailscale-DNS-only) and
OPNsense already needs to own DHCP for the new subnets anyway. The *goal*
here (MAC-based reservations over manual static IPs) hasn't changed, only
which service implements it.

### 7. Router VM is a known single point of failure — accepted for now
Every inter-VLAN packet passes through one router VM. If it goes down, VLANs
can't talk to each other, even though each VLAN's own internal traffic still
works. I'm accepting this for now since it's a lab, not something people
depend on staying up. This becomes worth solving with a redundant router VM
pair once I have a second physical node to actually place it on.

### 8. Observability gets its own VLAN (80), not shared with App/Secrets
If Prometheus/Grafana/Loki lived in the same VLAN as what they're monitoring,
a compromise of that VLAN could let an attacker tamper with or kill the very
logs that would reveal the compromise. Keeping monitoring in its own VLAN
means it stays intact even if something it's watching gets compromised.

### 9. Reserved VLANs (50, 60, 70, 80) created now, even though unused
I'm leaving gaps in the plan on purpose for things I know are coming later
(Ceph, a second public-facing service, media apps, monitoring), so that when
I actually build those, I'm just switching on an already-reserved VLAN number
instead of renumbering my whole existing network.

### 10. `linux-gh-runner` goes in VLAN 30, not its own tier
It's not a DB, not personal/misc, and its main job is deploying secrets-driven
app changes — it already talks to Vault (VLAN 30) for scoped CD credentials,
so it lives alongside Vault rather than getting a new VLAN carved out for a
single host. Its actual privilege (SSH to every fleet host for Ansible CD) is
handled as one narrow firewall exception, not by relocating it — see Firewall
Rule 7 and Known Limitations below.

### 11. DHCP for the new VLANs comes from OPNsense, not dnsmasq
My original draft had dnsmasq handing out per-VLAN DHCP leases. I've since
decided against that: dnsmasq today only does Tailscale-scoped DNS
(`*.taufiq.lab`) and has no DHCP directives at all, so bolting DHCP onto it
would be a new build, not a small edit. OPNsense already ships a full DHCP
server per interface, including static MAC-based mappings, which is the same
capability I wanted from dnsmasq in the first place — so each VLAN's DHCP now
lives on its own OPNsense interface instead. dnsmasq's job doesn't change at
all in this migration; it keeps resolving `*.taufiq.lab` over Tailscale
exactly as it does today. OPNsense's WAN NIC just joins the existing flat LAN
(`192.168.0.0/24`) as an untagged device and gets its own address from the
home router's DHCP, same as everything else does today.

### 12. Internal DNS (`taufiq.lab`) and public DNS (`tttaufiqqq.com`) stay separate
I considered pointing the lab's internal naming at my real Cloudflare domain
instead of the private `taufiq.lab` zone. Decided against it: `taufiq.lab`
only resolves over Tailscale split-DNS, so internal-only hosts (DBs, Vault,
the CD runner) aren't discoverable from the public internet even by hostname.
Putting the same names in Cloudflare's public zone would make that internal
structure enumerable by anyone, which works against the segmentation this
whole plan exists to build. `tttaufiqqq.com` stays reserved for whatever I
deliberately expose publicly (same pattern as
`animal-shelter-workshop.tttaufiqqq.com` via Cloudflare Tunnel today), not for
internal lab naming.

### 13. k3s doesn't get its own VLAN by default
A Kubernetes cluster isn't a trust tier, it's compute — what matters is what
runs on it, not the orchestrator itself (same logic as VLAN 30 already mixing
Spring Boot, Vault, and MinIO by trust tier, not by technology). Rather than
carve out a new VLAN for "k3s" the way I did for Ceph/DMZ/media/observability,
I'm treating its placement as inherited from its workloads: VLAN 60 (DMZ) if
the project ends up public-facing, VLAN 40 (Personal/Misc) if it stays
internal. Unlike the other reserved VLANs, there's no concrete workload to
reserve a number for yet, so I'm not adding one until the second project is
actually scoped.

---

## My Firewall Rules, in Plain English

Default policy: **everything is blocked unless I explicitly allow it.** I'd
rather discover I forgot to open something than discover I forgot to close
something.

1. The Spring Boot app (VLAN 30) is allowed to reach the specific DB engine it
   actually uses (Oracle, VLAN 20) on its normal database port. Nothing else.
2. The Spring Boot app is allowed to reach MinIO (VLAN 30, same VLAN) on its
   S3 API port.
3. Nothing from any VLAN is allowed to reach the Management VLAN (10), except
   me, directly from the Proxmox host itself. This protects the actual
   hypervisor control plane from anything happening inside any guest VM.
4. Nothing from VLAN 40 (Personal/Misc) is allowed to reach VLAN 20 (Databases)
   or VLAN 30 (App/Secrets) at all. These are side/test projects and have no
   legitimate reason to touch my real infrastructure.
5. Devices within the same VLAN can talk to each other freely (e.g., my DB
   VMs can all reach each other on VLAN 20), since they're the same trust
   tier already.
6. Any traffic that doesn't match an explicit allow rule above is dropped
   silently.
7. `linux-gh-runner` (VLAN 30) is allowed to reach every VLAN (20, 30, 40) on
   SSH (port 22) only, since its whole job is running Ansible CD across the
   fleet. This exception is scoped to that one host, not the whole VLAN — no
   other VLAN 30 device gets it.

(These rules get built and refined once I actually configure OPNsense — this
is the intended behavior I'm designing toward, not the final exhaustive rule
syntax.)

---

## Execution Steps

I'm doing this as a full stop-and-rebuild rather than a live migration, since
changing VLAN tags and bridge settings while VMs are actively passing traffic
risks a confusing partial outage anyway. Better to do it calmly with
everything off.

### Reference — every VM/CT ID (kept current with `README.md`)

| ID | Name | Type |
|---|---|---|
| 101 | app-server | VM |
| 102 | linux-sql-server | VM |
| 103 | spring-boot-app | VM |
| 104 | linux-mysql | VM |
| 105 | linux-mariadb | VM |
| 106 | linux-postgres | VM |
| 107 | linux-oracle-db | VM |
| 108 | linux-mongodb | CT |
| 109 | linux-mini-io | VM |
| 110 | linux-vault | CT |
| 111 | linux-gh-runner | CT |
| 112 | linux-mysql-2 | CT |
| 113 | linux-mariadb-2 | CT |

(Note: the original draft of this plan had a stale ID list — vmid 100 doesn't
exist and 108 is a CT, not a VM. Corrected below.)

### Step 1 — Shut down all VMs and CTs
Keep the Proxmox host itself running, just stop every guest.
```bash
# from the Proxmox host
for vmid in 101 102 103 104 105 106 107 109; do
  qm shutdown $vmid
done
for ctid in 108 110 111 112 113; do
  pct shutdown $ctid
done
```

### Step 2 — Make the bridge VLAN-aware
In the Proxmox UI: **Node → System → Network → vmbr0 → Edit → tick "VLAN
aware"**. Or via config:
```bash
nano /etc/network/interfaces
```
Ensure `vmbr0` has:
```
bridge-vlan-aware yes
bridge-vids 2-999
```
Apply with:
```bash
ifreload -a
```

### Step 3 — Leave dnsmasq alone; DHCP for the new VLANs lives in OPNsense
No dnsmasq edits in this step (see Decision 11) — dnsmasq keeps doing exactly
what it does today: Tailscale-only DNS for `*.taufiq.lab`, nothing else. Per-
VLAN DHCP is configured on the OPNsense VM instead, as part of Step 4 below.
This step exists in the plan only so the dependency is explicit: don't skip
straight to Step 5 assuming dnsmasq handles addressing, it doesn't.

### Step 4 — Create the OPNsense router VM
1. Download the OPNsense installer image from
   [opnsense.org/download](https://opnsense.org/download/) — pick the **DVD
   image**, `amd64`. It ships as a `.img.bz2`, not a classic `.iso`, but it
   uploads to Proxmox's ISO storage and boots in the VM's CD/DVD drive the
   same way. Upload it to Proxmox storage.
2. Create a new VM with:
   - **One untagged WAN NIC** on the existing flat LAN
     (`192.168.0.0/24`) — OPNsense gets its own address from the home
     router's DHCP, same as every other device today. This is how it reaches
     the internet.
   - **One tagged LAN NIC per VLAN** (10, 20, 30, 40 at minimum, plus the
     reserved ones if I want them ready), each tagged under **Hardware →
     Network Device → VLAN Tag**.
3. Install OPNsense following its installer prompts.
4. Boot it, access its web GUI once it has an IP on the Management VLAN.
5. In OPNsense, assign each tagged NIC to its VLAN (**Interfaces →
   Assignments**) and give it the `.1` address of that subnet (e.g.
   `10.0.20.1/24` for VLAN 20).
6. Enable OPNsense's DHCP server on each VLAN interface (**Services →
   DHCPv4 → [interface]**), with a static MAC-based mapping for every VM/CT
   that belongs on that VLAN — same reliability goal as the original
   dnsmasq-DHCP idea (Decision 6), just built on OPNsense instead (Decision
   11).
7. **Confirm the WAN interface has real internet access before moving to
   Step 5.** Nothing past this point works if OPNsense itself can't route
   out — this is the single point of failure from Decision 7, now live.

### Step 5 — Assign VLAN tags to each existing VM
For each VM/CT, in Proxmox: **Hardware → Network Device → Edit → VLAN Tag**,
set to the matching VLAN ID from the table below. Do this only after Step 4
is fully verified (OPNsense routing + DHCP live on every VLAN) — tagging a
guest NIC before that leaves it unable to reach anything, including the
internet.

| ID | VM/CT | New VLAN |
|---|---|---|
| 102 | linux-sql-server | 20 |
| 104 | linux-mysql | 20 |
| 105 | linux-mariadb | 20 |
| 106 | linux-postgres | 20 |
| 107 | linux-oracle-db | 20 |
| 108 | linux-mongodb (CT) | 20 |
| 112 | linux-mysql-2 (CT) | 20 |
| 113 | linux-mariadb-2 (CT) | 20 |
| 103 | spring-boot-app | 30 |
| 109 | linux-mini-io | 30 |
| 110 | linux-vault (CT) | 30 |
| 111 | linux-gh-runner (CT) | 30 |
| 101 | app-server | 40 |

### Step 6 — Boot VMs one at a time, confirm new IPs
```bash
qm start 104   # linux-mysql, for example
```
SSH in, confirm it picked up its reserved IP:
```bash
ip addr show
```
Repeat for each VM/CT, checking one before moving to the next rather than
booting everything simultaneously, so any misconfiguration is easy to isolate.

### Step 7 — Configure OPNsense firewall rules
In the OPNsense web GUI, set the default policy to block, then add the allow
rules from the "Firewall Rules, in Plain English" section above, one interface
(VLAN) at a time.

### Step 8 — Test inter-VLAN routing and isolation
```bash
# from spring-boot-app (VLAN 30), should succeed:
ping 10.0.20.5          # linux-oracle-db

# from app-server (VLAN 40), should FAIL (this is the point):
ping 10.0.20.5
ping 10.0.30.x          # any VLAN 30 device

# from any VLAN, should FAIL:
ping 10.0.10.x          # Management VLAN

# from linux-gh-runner (VLAN 30), SSH should succeed to any VLAN (its CD job):
ssh 10.0.20.5           # or any other fleet host, any VLAN
```

### Step 9 — Confirm Tailscale still works as expected on every VM
Since I decided to keep Tailscale everywhere, verify each VM is still
reachable via its Tailscale IP after the VLAN change, independent of the new
LAN segmentation.

---

## Known Limitations (Accepted On Purpose)

- **Tailscale bypasses all VLAN isolation.** Anyone with tailnet access (just
  me, currently) reaches every VM directly regardless of VLAN. Accepted since
  this is a personal lab.
- **The OPNsense router VM is a single point of failure.** If it goes down,
  no VLAN can reach any other VLAN. Accepted for now, revisit with a
  redundant router pair once a second physical node exists.
- **VLANs 50, 60, 70, 80 are reserved but empty.** No devices, no traffic,
  intentionally kept unused until Ceph, a second public-facing service, media
  apps, or the observability stack actually get built.
- **`linux-gh-runner`'s CD reach is a deliberate hole in default-deny.** It's
  allowed SSH to every VLAN so Ansible can converge the fleet — scoped to one
  host and one port, but still an exception to "nothing crosses VLANs
  without a specific reason." Accepted since CD needs it and the SSH key it
  uses is already scoped/revocable independently of my own admin key (see
  `docs/09-github-actions-runner/actions-runner-setup.md`).

---

## Future Expansion (Not Built Yet)

- **Second physical Proxmox node** — same VLAN numbers extend across a trunk
  port on the managed switch, new node joins the cluster via VLAN 10.
- **VLAN 50 activates** for Ceph once node 2 exists, kept off the main VLANs
  so replication traffic doesn't compete with app/DB traffic.
- **VLAN 80 activates** once Prometheus/Grafana/Loki are built, including
  shipping Proxmox host logs (via Promtail) off-box so they survive even if
  the host itself has issues.
- **New DB engines** (Redis, Neo4j, ClickHouse) join VLAN 20 regardless of
  which physical node they run on.
- **Jellyfin or similar** goes into VLAN 70, kept separate from Spring Boot
  since it would be a second internet-facing service.
- **k3s (second project, second physical node)** — no dedicated VLAN by
  default (Decision 13). Goes in VLAN 60 (DMZ) if the project ends up
  public-facing, or VLAN 40 (Personal/Misc) if it stays internal. Decided
  once the project itself is scoped.
- **Public DNS stays separate from the lab's internal DNS** (Decision 12).
  `taufiq.lab` keeps naming internal-only hosts; `tttaufiqqq.com` only gets a
  subdomain for whatever's deliberately made public, same pattern as
  `animal-shelter-workshop.tttaufiqqq.com` today.

---

## Execution Log — 24 July 2026

Started actually running this plan today. Writing this as I go, same as every
other doc in this repo — live, not cleaned up after the fact.

### Pre-flight: inspected the live host before touching anything
Before Step 1, checked the actual state of the Proxmox host rather than
trusting this doc. Found `vmbr0.20` (`10.0.20.1/24`) and `vmbr0.30`
(`10.0.30.1/24`) already configured directly on the host — my own leftover
experiment from when I first got the Proxmox box, before this plan existed.
These directly conflicted with Step 4 (OPNsense needs those same `.1`
addresses on its own interfaces), so I removed them: backed up
`/etc/network/interfaces` to `/etc/network/interfaces.bak-20260724-065055`,
deleted both blocks, applied with `ifreload -a`. `ip_forward` was already `0`
and nothing was tagged to use them, so this was inert cleanup, not a live
change.

Also re-checked the dnsmasq `0.0.0.0:53` listen flag raised earlier in
planning. Confirmed it's a false alarm: `ss` shows a wildcard bind, but that's
dnsmasq's normal behavior without `bind-interfaces` set — it still filters by
the `interface=tailscale0`/`interface=lo` directives already in the config.
Proved it live: `dig @192.168.0.10 proxmox.taufiq.lab` timed out, confirming
it doesn't actually answer on the LAN side. No dnsmasq change made.

### Step 1 — Shut down all VMs and CTs ✅
Only `linux-mini-io` (109) was actually running; everything else was already
off. `qm shutdown 109`, confirmed stopped. All 13 guests off.

### Step 2 — Make the bridge VLAN-aware ✅ (already done)
Already configured: `vmbr0` had `bridge-vlan-aware yes` and
`bridge-vids 2-4094` — wider than my draft's `2-999`, functionally a
superset, left as-is.

### Step 3 — dnsmasq ✅ (no-op, confirmed)
Per Decision 11, no dnsmasq changes needed for DHCP — confirmed live config
still matches that assumption (Tailscale-only DNS, no DHCP directives).

### Step 4 — Create the OPNsense router VM ⏳ in progress, handed off
Created VM 200 (`opnsense`) via `qm create`: 2 vCPU, 2GB RAM, 20GB disk
(`local:200/vm-200-disk-0.qcow2`), OPNsense 26.7 DVD ISO attached as boot
media (`boot=order=ide2;scsi0`), 9 NICs — one untagged WAN (net0) plus one
tagged NIC per VLAN, including the reserved ones (net1–net8 = VLAN
10/20/30/40/50/60/70/80). Booted it into the installer.

MAC-to-role table, for matching interfaces during OPNsense's own assignment
menu (it lists each interface's MAC):

| Interface | Role | MAC |
|---|---|---|
| net0 | WAN (untagged, flat LAN) | BC:24:11:48:F3:8A |
| net1 | VLAN 10 — Management | BC:24:11:34:7D:2C |
| net2 | VLAN 20 — Database | BC:24:11:43:C2:D9 |
| net3 | VLAN 30 — App/Secrets/Storage | BC:24:11:74:AE:18 |
| net4 | VLAN 40 — Personal/Misc | BC:24:11:84:00:24 |
| net5 | VLAN 50 — Ceph (reserved) | BC:24:11:88:DC:A9 |
| net6 | VLAN 60 — DMZ (reserved) | BC:24:11:24:70:8D |
| net7 | VLAN 70 — Media (reserved) | BC:24:11:91:BC:D3 |
| net8 | VLAN 80 — Observability (reserved) | BC:24:11:DF:45:00 |

**Stopped here on purpose.** Everything past this point needs a live
console/GUI session — the OPNsense text installer and its first-boot
interface-assignment menu both require interactive input that isn't safe to
drive blind over a non-interactive SSH session, especially the disk
partitioning step. Handoff:

1. Proxmox UI → VM 200 → Console — run the OPNsense installer onto the 20GB
   disk.
2. At the first-boot interface assignment prompt, match each `vtnetN` to its
   role using the MAC table above.
3. Once it has a management IP reachable on VLAN 10, finish Step 4.5–4.7
   (interface IPs, per-VLAN DHCP, confirm WAN has real internet) in the
   OPNsense web GUI.

Steps 5–9 (VLAN-tag every VM/CT, boot up, firewall rules, isolation testing,
Tailscale check) still to come once OPNsense is live.
