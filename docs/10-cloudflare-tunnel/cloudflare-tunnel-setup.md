# Cloudflare Tunnel — Public HTTPS for Animal-Shelter-Workshop

**Date:** 2026-07-19
**Host:** `app-server`, VM ID `101` (existing VM — no new Proxmox resource created)
**Domain:** `tttaufiqqq.com` (Cloudflare-managed)
**Public hostname:** `animal-shelter-workshop.tttaufiqqq.com`
**Serves:** [`Animal-Shelter-Workshop`](https://github.com/tttaufiqqq/Animal-Shelter-Workshop)

---

## Why This Exists

`Animal-Shelter-Workshop`'s own hardening docs
([`docs/09-production-hardening.md`](https://github.com/tttaufiqqq/Animal-Shelter-Workshop/blob/main/docs/09-production-hardening.md)
in that repo) originally planned TLS via nginx + Let's Encrypt/certbot — the standard approach,
requiring a public DNS A record, port 443 forwarded on the home router, and an Ansible-managed
renewal timer. That plan is still sound and still committed in that repo's
`infrastructure/ansible/`, but **wasn't used here**. Two things changed the calculus:

1. This project is a past coursework submission — no real users, no real adopter data, no real
   payments. The stakes that would normally justify certbot's extra rigor (protecting real PII in
   transit) don't apply.
2. A Cloudflare domain (`tttaufiqqq.com`) was already available, and this lab already uses
   Cloudflare Tunnel for `spring-boot-app`'s public access (see `docs/04-spring-boot/
   spring-boot-setup.md`) — reusing a pattern already proven here beats standing up a second,
   different TLS mechanism.

Cloudflare Tunnel wins on convenience specifically: **no router port-forwarding, no NAT/CGNAT
troubleshooting, no certificate to renew** — the tunnel daemon on `app-server` makes an outbound
connection to Cloudflare's edge, and Cloudflare terminates TLS with its own auto-managed
certificate. `app-server`'s nginx never needs to know HTTPS exists; it keeps serving plain HTTP
on `:80` exactly as before.

---

## What This Touches

Nothing new at the Proxmox level — no new VM/CT, no Terraform change. This is entirely a
Cloudflare dashboard action plus one new systemd service on the existing `app-server` VM (101):

| Component | Change |
|---|---|
| Cloudflare dashboard | New tunnel `animal-shelter-workshop`, one public hostname route |
| `app-server` (VM 101) | New `cloudflared` package + `cloudflared.service` (systemd, root-owned) |
| `app-server`'s nginx | Unchanged — still plain HTTP on `:80` |
| `app-server`'s `.env` | `APP_URL` updated to `https://animal-shelter-workshop.tttaufiqqq.com` |
| UFW / firewall | Unchanged — no new inbound rule needed, the tunnel is outbound-only |

---

## Setup

### 1. Create the tunnel (Cloudflare Zero Trust dashboard)

Networks → Tunnels → Create a tunnel → Cloudflared connector → name it
`animal-shelter-workshop`.

### 2. Install the connector on app-server

Dashboard gives an OS-specific install command. **First mistake made here**: the dashboard
defaults to whatever OS the browser is running on — this was caught before running anything,
since app-server is Ubuntu 24.04 (Debian-based), not the Windows laptop the dashboard was opened
from. Switched the "Select your device's operating system" dropdown to **Debian** before copying
the command.

```bash
# On app-server, as taufiq (has sudo)
sudo mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt-get update && sudo apt-get install cloudflared

sudo cloudflared service install <token-from-dashboard>
```

The token is a real credential ("anyone with access to this token will be able to run the
tunnel") — deliberately run directly by the machine's own operator over their own SSH session
rather than handed to an assistant/session that didn't need to see it. Installs as
`cloudflared.service`, running as root, enabled on boot; stores the token at
`/etc/cloudflared/token`.

### 3. Route the public hostname (same dashboard, different tab)

Tunnel → Route tunnel → Published applications:
- Subdomain: `animal-shelter-workshop`, Domain: `tttaufiqqq.com`
- Service Type: `HTTP`, URL: `localhost:80` (the placeholder shown is `localhost:8080` — easy to
  leave unedited by mistake; app-server's nginx is on `:80`, not `:8080`)

### 4. Point Laravel at its real public URL

`app-server`'s `.env` still had `APP_URL=http://localhost` from its original manual setup —
harmless for the homepage (which doesn't generate absolute URLs), but would have produced broken
`http://localhost/...` links anywhere the app builds an absolute URL (password reset emails,
redirects). Fixed directly:

```bash
sed -i 's|^APP_URL=.*|APP_URL=https://animal-shelter-workshop.tttaufiqqq.com|' .env
php artisan config:clear
```

---

## Issues Encountered

### 1. "Complete setup" not clicked — DNS record silently never created
After installing the connector and filling in the Published Applications form, a `curl` test to
the public hostname failed. First suspected a local DNS resolver problem (an `nslookup` against
the default resolver timed out entirely, pointing at a broken link-local address) — but querying
Cloudflare's own resolver directly (`nslookup animal-shelter-workshop.tttaufiqqq.com 1.1.1.1`)
returned **`Non-existent domain`**, a real, authoritative answer, not a local resolver hiccup. The
form's "Complete setup" button had been filled in but never actually clicked — the route (and the
DNS record it creates) was never saved. Confirmed the tunnel showed "Healthy" status only after
clicking it; DNS resolved and `curl` returned `200` immediately after.

**Lesson**: `cloudflared service install` succeeding and the tunnel showing connected in
`systemctl status` only proves the *connector* is up — it says nothing about whether a route
exists yet. Check the dashboard's tunnel list for a route count, or just try `nslookup <hostname>
1.1.1.1` directly rather than trusting the local machine's default resolver, which can fail for
unrelated reasons (see below) and produce a misleading "it's not working" signal.

### 2. Local Windows resolver timeout looked like a DNS propagation problem but wasn't
Testing from a separate Windows machine (not app-server), `nslookup` timed out against `Address:
fe80::1` — a link-local IPv6 address, not a real DNS server. This was a red herring from that
machine's own resolver setup (likely Tailscale-adjacent), unrelated to the actual Cloudflare DNS
record. Diagnosed by testing against `1.1.1.1` explicitly instead of the system default — isolates
"is the record real" from "can this specific machine's resolver reach it."

---

## Verification

```bash
# from any external machine
curl -sI https://animal-shelter-workshop.tttaufiqqq.com/
# HTTP/1.1 200 OK, Server: cloudflare, real Laravel session cookies set

curl -s https://animal-shelter-workshop.tttaufiqqq.com/ | grep -o '<title>.*</title>'
# <title>Welcome - Stray Animals Shelter</title>

curl -s https://animal-shelter-workshop.tttaufiqqq.com/login | grep -o '<title>.*</title>'
# <title>Login - Stray Animal Shelter</title>
```

Confirmed on `app-server` directly: `systemctl is-active cloudflared` → `active`, 4 registered
tunnel connections to nearby Cloudflare PoPs (Singapore, Kuala Lumpur), and
`php artisan tinker --execute="echo route('login');"` correctly resolves to the real HTTPS
hostname (proving `APP_URL` took effect, not just the homepage happening to work).

---

## Reboot Survivability (checked, not yet empirically tested)

Asked directly: does this setup survive `app-server` being shut down and turned back on? Checked
everything that matters, matching the bar set by `linux-vault`/`linux-gh-runner`'s reboot tests
elsewhere in this repo — but **couldn't perform an actual reboot** to confirm end-to-end the same
way those did (no sudo on this box from the session that checked this, and no direct Proxmox host
access to power-cycle the VM instead). What was verified instead, via config inspection:

```bash
systemctl is-enabled nginx        # enabled
systemctl is-enabled php8.3-fpm   # enabled
systemctl is-enabled cloudflared  # enabled
systemctl is-enabled tailscaled   # enabled
# all 4 also currently `active`, not just enabled — not a half-broken state
tailscale ip -4                   # 100.100.123.90 — a real, persisted Tailscale identity,
                                   # not a fresh/pending one that would need interactive
                                   # browser re-auth after reconnecting
ps aux | grep -E 'php artisan serve|node|npm'  # nothing — no stray foreground process
                                                # outside systemd that a reboot would lose
```

**No gaps found, nothing needed fixing.** All four services `nginx`/`php8.3-fpm`/`cloudflared`/
`tailscaled` are `enabled`, meaning systemd starts them automatically on boot with no manual
intervention; Tailscale's identity is already persisted (`/var/lib/tailscale/`), so it reconnects
on its own without needing re-approval from the admin console; and the app is served entirely
through nginx+php-fpm with nothing running manually outside systemd's management.

**Confidence is high but not proven** — recommend an actual `pct`/Proxmox-level shutdown + restart
of VM 101 the next time it's convenient, then re-checking `curl -sI
https://animal-shelter-workshop.tttaufiqqq.com/` and each service's `systemctl is-active` fresh
after boot, the same way `docs/09-github-actions-runner/actions-runner-setup.md`'s reboot test did
for CT 111.

## Notes / Known Gaps

- **`TrustProxies` is not configured** in the Laravel app (`bootstrap/app.php` has no
  `$middleware->trustProxies(...)` call). `APP_URL` being a static config value means `route()`/
  `url()` helpers already generate the correct `https://` links regardless, but anything that reads
  `$request->isSecure()` / `$request->getScheme()` directly would still see the request as plain
  HTTP (the connection from `cloudflared` to nginx to php-fpm genuinely is HTTP — only the
  browser-to-Cloudflare leg is HTTPS). Not fixed here — would mean editing the app's own code, and
  this repo's session deliberately avoided pushing that repo's pending commits to GitHub while
  another session was mid-work on its GitHub Actions runner setup. Tracked as a follow-up in
  `Animal-Shelter-Workshop`'s own `handoff.md`.
- **No HSTS header yet.** `Animal-Shelter-Workshop`'s planned nginx template adds
  `Strict-Transport-Security`, but since Cloudflare — not this app's nginx — terminates TLS here,
  HSTS needs to be turned on in Cloudflare's own dashboard (SSL/TLS → Edge Certificates → Always
  Use HTTPS / HTTP Strict Transport Security), not in application code. Not yet enabled.
- **This bypasses the certbot-based Ansible TLS automation** committed in
  `Animal-Shelter-Workshop`'s `infrastructure/ansible/playbooks/app-server.yml`. That automation
  still exists and still works for a scenario without Cloudflare in front — just not what's
  actually running on `app-server` right now. Worth a decision later if this project ever needs
  real users: Cloudflare Tunnel's simplicity was explicitly a trade against rigor that only matters
  once real data is at stake.
