# Network Segmentation — Execution Write-Up

**Author:** Taufiq
**Date:** 24 July 2026
**Scope:** Turning [`homelab-network-segmentation-execution-plan.md`](../../plans/homelab-network-segmentation-execution-plan.md) from a design doc into a running network — OPNsense install, per-VLAN DHCP, firewall rules, and every real thing that broke along the way.

---

## What I Built

Split the lab from one flat `192.168.0.0/24` network into 8 VLANs behind a dedicated OPNsense router VM:

- **VM 200 (`opnsense`)** — 4 vCPU, 4GB RAM, 20GB disk, one untagged WAN NIC (on the existing flat LAN) plus 8 tagged VLAN NICs (10/20/30/40/50/60/70/80).
- **Per-VLAN static IP + Kea DHCP** with static MAC reservations for every VM/CT — no guest has a manually-typed static IP; every address is a central reservation keyed to a MAC, same as the plan's original dnsmasq idea, just implemented on OPNsense instead.
- **Firewall rules**: specific app-to-app rules (Spring Boot → Oracle on 1521), a general "internet access, not other VLANs" rule per active VLAN (using OPNsense's destination-invert match against `10.0.0.0/8`), and a DNS-to-OPNsense-itself rule that turned out to be necessary and non-obvious (see below).
- **All 13 VMs/CTs re-tagged** onto their correct VLAN and reboot-tested one at a time.

Full design reasoning (why OPNsense, why these VLAN numbers, why Tailscale stays exempt, etc.) lives in the plan doc's "Decisions I Made, and Why" section — this doc is specifically the *build log*, not the design rationale.

## Why I Built It

The lab was one flat network, meaning any VM could reach any other VM regardless of trust level — a compromised personal/test project (`app-server`) sat on the same broadcast domain as production-adjacent database hosts. The goal was to stop that kind of lateral movement without losing general internet access (needed for things like `linux-gh-runner` polling GitHub, or `app-server`'s Cloudflare Tunnel) and without touching how Tailscale-based admin access already worked.

---

## What Broke, How I Found It, and How I Recovered

### 1. The OPNsense installer ISO was silently truncated

**Broke:** Booting the freshly-uploaded ISO threw this repeatedly and never got past it:
```
g_vfs_done(): iso9660/OPNSENSE_INSTALL[READ(offset=...,length=2048)]error = 5
```

**Found it:** First guess was a known Proxmox/QEMU quirk with BSD ISOs on the emulated IDE CD-ROM controller, so I moved the ISO from IDE to SATA. The *exact same* offsets failed again afterward — identical failures on two different controllers ruled out an emulation bug entirely. Downloaded the image fresh, directly on the Proxmox host (bypassing the original Windows browser download), and checksummed it against OPNsense's officially published SHA256 before decompressing. The verified file was **2,101,714,944 bytes**; the one already sitting in Proxmox's ISO storage was only **1,843,724,288 bytes** — short by ~258MB. The original download had been truncated, not corrupted in transit.

**Recovered:** Swapped the verified file into place, refreshed the VM's disk metadata, rebooted — read cleanly past the point that used to fail.

![ISO9660 read error persisting after switching IDE to SATA](images/01-iso-read-error.png)
![Clean live boot after replacing the truncated ISO](images/02-live-boot-success.png)

### 2. Installer refused to proceed at 2GB RAM

**Broke:** bsdinstall's UFS step warned that copying the live filesystem to disk wants at least 3000MB, with only `[Proceed anyway]` or `[Cancel]`.

**Found it:** Straightforward warning dialog, no digging required.

**Recovered:** Stopped the VM (safe — nothing had been written to disk yet), bumped RAM from 2GB to 4GB, reinstalled without the warning.

![bsdinstall RAM warning at 2GB](images/03-ram-warning.png)

### 3. LAN interface kept defaulting to DHCP instead of static

**Broke:** At the console's "Configure IPv4 address LAN interface via DHCP?" prompt, muscle memory typed `y` twice in a row instead of `n` — leaving LAN trying to DHCP on a network with no DHCP server yet, instead of the static `10.0.10.1/24` the plan called for.

**Found it:** Visible immediately in the console's own confirmation output each time.

**Recovered:** Went through the console's interface-IP wizard a third time, deliberately slower, confirming each individual prompt before moving to the next, landing on the correct static config.

![Correctly installed system showing LAN at 10.0.10.1/24](images/04-installed-lan-correct.png)

### 4. Kea DHCP got accidentally enabled on WAN

**Broke:** Clicking "Select All" while picking which interfaces Kea DHCP should serve also selected WAN — which would have started handing out DHCP leases onto the existing home LAN, directly conflicting with the home router's own DHCP.

**Found it:** Reviewed the selected-interfaces list before applying and spotted WAN sitting in there alongside the VLANs.

**Recovered:** Unchecked WAN, kept only LAN + the 7 VLAN interfaces, applied.

![WAN mistakenly included in Kea's interface list](images/05-kea-wan-included-mistake.png)
![WAN correctly excluded, only VLAN interfaces selected](images/06-kea-wan-excluded-fixed.png)

### 5. The firewall rule editor kept silently rejecting the destination port

**Broke:** Adding the Spring Boot → Oracle rule, the Destination Port field visibly showed `1521`, but Save kept failing with *"Please specify a valid portnumber, name, alias or range."* — including one detour where a stray edit ended up typed into the wrong field entirely.

**Found it:** Re-screenshotting after every single field change (rather than trusting that a visually-filled field was actually committed) eventually isolated the real cause: **Protocol was still set to `any`**, and OPNsense only accepts a Destination Port when Protocol is explicitly TCP or UDP — the error message was accurate the whole time, just easy to miss while chasing the port field itself.

**Recovered:** Set Protocol to `TCP` explicitly; the exact same port value that had been "invalid" for several attempts saved immediately.

![Port field showing "1521" but still failing validation](images/07-firewall-port-field-error.png)
![Same rule, Protocol set to TCP, saved with no errors](images/08-firewall-rule-fixed.png)

### 6. My own firewall rule design blocked OPNsense's own DNS resolver

**Broke:** After tagging every VM and applying the firewall rules, `linux-mysql` lost DNS resolution entirely (which in turn knocked its Tailscale offline, since Tailscale needs to resolve `controlplane.tailscale.com` to register) — even though plain ICMP ping to raw IPs worked fine.

**Found it:** `resolvectl status` on the VM showed its DNS server was `10.0.20.1` — OPNsense's own interface IP, exactly as the DHCP "auto collect option data" setting intended. The bug: my "internet access only" rule on each VLAN works by matching "destination is *not* in `10.0.0.0/8`" — and OPNsense's own interface addresses are *inside* `10.0.0.0/8`, so that same rule that correctly blocked cross-VLAN traffic was also, as a side effect, blocking every VM from reaching OPNsense's own resolver.

**Recovered:** Added one additional rule per VLAN — destination `This Firewall`, port 53, TCP/UDP — explicitly allowing DNS to OPNsense itself. This was a genuine gap in my rule design, not anything wrong on the VM side.

![tailscaled repeatedly failing to register, logs cut off mid-registration](images/09-tailscaled-registration-failing.png)
![Ping to a raw IP succeeds while DNS lookup times out — isolating it to a DNS-specific problem](images/10-ping-works-dns-fails.png)
![resolvectl confirming the DNS server is OPNsense's own interface IP](images/11-dns-server-is-opnsense.png)

### 7. Oracle's own host firewall blocked the DB port regardless of any VLAN rule

**Broke:** Even after every network-level fix, Spring Boot → Oracle on 1521 still failed with "No route to host" — including when tested from the fully-open Management VLAN, which has no restrictions at all.

**Found it:** That specific error pattern (ICMP works, a specific TCP port doesn't, from *any* source) is characteristic of the destination host's own firewall rejecting the connection, not a network-level block. Checked directly on the Oracle VM: `firewalld` was active, and the DB was confirmed actually listening on `0.0.0.0:1521` — so the network path and the service were both fine; only the VM's own host firewall was in the way.

**Recovered:** Added a `firewalld` rich rule on the Oracle VM directly, allowing `10.0.0.0/8` to reach port 1521/tcp, then reloaded.

![firewall-cmd rich-rule applied successfully on the Oracle VM's own console](images/12-oracle-firewalld-fixed.png)

### 8. `gh-runner` couldn't SSH into other VLANs — even with a correct OPNsense rule

**Broke:** SSH from `linux-gh-runner` (and even from the fully-open Management VLAN) to `linux-mysql` or `app-server` timed out, despite the specific OPNsense allow-rule for it being configured correctly.

**Found it:** `ufw status verbose` on both target VMs revealed SSH (and MySQL, for `linux-mysql`) was deliberately scoped to `tailscale0` only, from specifically named Tailscale IPs — a pre-existing security posture from before today, completely unrelated to the VLAN work.

**Recovered:** No fix needed. `linux-gh-runner`'s real CD path already runs over Tailscale, which bypasses VLAN routing entirely by design (this lab's Tailscale-stays-everywhere decision) — so nothing was actually at risk. The OPNsense rule for LAN-based SSH access stays in place as harmless defense-in-depth; it just isn't the path anything actually uses today.

![ufw on app-server restricting SSH to tailscale0 with named source IPs](images/13-ufw-app-server-tailscale-only.png)
![Same restriction on linux-mysql, plus a Tailscale-only MySQL rule](images/14-ufw-mysql-tailscale-only.png)

---

## Where Things Stand

All 13 VMs/CTs are tagged onto their correct VLAN, booted, and confirmed reachable at their reserved IPs. Firewall rules for the 3 active VLANs (20/30/40) are in place and tested end-to-end: DB tier isolated from Personal, Personal blocked from reaching App/Secrets and DB, the one specific Spring Boot → Oracle path works, internet access works everywhere it should, and Management stays unreachable from every VLAN except the Proxmox host itself. VLANs 50/60/70/80 stay reserved and ruleless until something actually gets deployed there.

Independently reproduced afterward from my own terminal, not the same SSH
session the original tests ran from — same results both times:

![app-server's own terminal reproducing the exact same VLAN 40 isolation results](images/15-app-server-isolation-verified-by-user.png)
![spring-boot-app's own terminal reproducing the exact same VLAN 30 isolation results](images/16-spring-boot-app-isolation-verified-by-user.png)

Full step-by-step execution log (commands run, exact config) lives in [`homelab-network-segmentation-execution-plan.md`](../../plans/homelab-network-segmentation-execution-plan.md)'s Execution Log section — this doc is the narrative version of the same work.
