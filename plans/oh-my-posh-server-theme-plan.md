# Oh My Posh per-host color theme rollout plan

## Goal
I want every VM/CT to have its own distinct prompt color, so I know which
host I'm on just by looking at the prompt, for the whole session, not just
at the login banner like [`docs/17-custom-ssh-motd`](../docs/17-custom-ssh-motd/custom-ssh-motd-setup.md)
already gives me. The two aren't overlapping, they're complementary: MOTD
paints the banner once at login, this paints the prompt itself, which stays
on screen for every command I type afterward.

I'm reusing the accent-color-per-host mapping I already set up for MOTD, so
a host's identity color stays consistent in two places: the SSH banner and
the live prompt.

## Design decision: one shape, per-host color

My original draft of this plan assigned different theme families
(Tokyo Night / Neutral+coral / Synthwave) to tiers like "web", "database",
"staging". I dropped that. My homelab doesn't actually have a
dev to staging to production pipeline (per-host role is closer to my
reality: it's MySQL vs. MariaDB vs. Vault vs. app server, all roughly the
same trust tier), and tier-level theming would still lump 8 different DB
engines (mysql, mysql-2, mariadb, mariadb-2, postgres, oracle, mongodb,
sql-server) under one shared color, which defeats what I actually want:
each VM/CT having its own color.

Instead I'm going with one shared prompt shape/layout across the entire
fleet (same segments, same glyphs, same order everywhere), and only the
primary segment's background color changes per host. Same principle I used
for MOTD: one script, one `case "$HOST"` block, `ACCENT` is the only thing
that varies. I'm applying that to the prompt instead of the banner.

## Fleet + accent color (reused from MOTD, converted to hex)

Same table I already have in `docs/17-custom-ssh-motd`, so a host's MOTD
banner and its oh-my-posh prompt agree on its identity color. I converted
the xterm 256 codes to hex since oh-my-posh's JSON takes hex, not xterm
codes:

| SSH alias | Role | xterm code (MOTD) | Hex (this prompt) |
|---|---|---|---|
| `linux-app-server` | App server (nginx/Cloudflare Tunnel) | 208 | `#ff8700` |
| `linux-sql-server` | MSSQL | 129 | `#af00ff` |
| `spring-boot-app` | Spring Boot app | 34 | `#00af00` |
| `linux-mysql` | MySQL | 33 | `#0087ff` |
| `linux-mysql-2` | MySQL (split instance) | 45 | `#00d7ff` |
| `linux-mariadb` | MariaDB (real host `workshop-2`) | 94 | `#875f00` |
| `linux-mariadb-2` | MariaDB (split instance) | 130 | `#af5f00` |
| `linux-postgres` | PostgreSQL | 24 | `#005f87` |
| `linux-oracle-db` | Oracle | 196 | `#ff0000` |
| `linux-mongodb` | MongoDB | 46 | `#00ff00` |
| `linux-vault` | HashiCorp Vault | 99 | `#875fff` |
| `linux-mini-io` | MinIO | 220 | `#ffd700` |
| `linux-gh-runner` | GitHub Actions runner | 51 | `#00ffff` |
| `linux-k3s` | K3s (Kubernetes) | (new, not in MOTD table) | `#326ce5` |
| `linux-observability` | Observability stack (VLAN 80) | (new, not in MOTD table) | `#14b8a6` |
| `taufiq` | Proxmox VE host node | (new, not in MOTD table) | `#607d8b` |
| anything else | fallback | 15 | `#ffffff` |

`taufiq`, `linux-k3s`, and `linux-observability` aren't in my MOTD table
since they postdate that rollout (MOTD covered the original 13-host
fleet). `linux-k3s` gets the official Kubernetes blue, `linux-observability`
gets a teal distinct from every other host since it's the monitoring tier.
`taufiq` is a cool slate/blue-gray, distinct from every saturated guest
color, since it's the one host that's "management plane" rather than a
workload, the same distinction I already draw with VLAN 10 in the network
segmentation plan.

If I tweak any of these colors later, I need to update both this table and
`docs/17-custom-ssh-motd`'s `ACCENT=` case block together so the two stay
in sync, that's the whole point of reusing the mapping.

## Theme shape (shared by every host)

I asked Claude web for some visual options and picked "Variant 3, rounded
pill segments" as the one shape every host shares (rounded capsule
segments instead of sharp powerline arrows, that's the most distinct shape
compared to a plain terminal). The other two variants it suggested (Tokyo
Night arrows, dark neutral + coral) aren't used, this plan isn't going back
to per-tier shapes.

One template, `theme.omp.json`, with a single placeholder color for the
identity segment. Segments:

- Session (left, fixed purple `#7c3aed`, rounded pill): `user@host`, so the
  hostname text is still there as a fallback even though color is the
  primary signal, same "don't rely on text alone, but don't remove it
  either" approach I took with figlet in MOTD. Fixed color, not per-host,
  same purple everywhere.
- Path (the identity segment, rounded pill, background is `__ACCENT__`,
  this host's color from the table above): current working directory. This
  is the only segment that changes per host.
- Git (fixed mint green `#2dd4a7`, rounded pill, only renders inside a git
  repo): branch/status, kept as a fixed color on purpose so it never
  competes with the host color.
- Exit code (right-aligned, rounded pill, green on success, red on nonzero
  exit): the one segment that's dynamic per-command rather than per-host.

Rounded pill shape comes from giving every segment `"style": "diamond"`
with `` / `` (the Nerd Font rounded-cap glyphs) as its leading/
trailing diamond, instead of the sharp `` powerline arrow.

```json
{
  "$schema": "https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes/schema.json",
  "version": 2,
  "final_space": true,
  "blocks": [
    {
      "type": "prompt",
      "alignment": "left",
      "segments": [
        {
          "type": "session",
          "style": "diamond",
          "leading_diamond": "",
          "trailing_diamond": "",
          "foreground": "#ffffff",
          "background": "#7c3aed",
          "template": " {{ .UserName }}@{{ .HostName }} "
        },
        {
          "type": "path",
          "style": "diamond",
          "leading_diamond": "",
          "trailing_diamond": "",
          "foreground": "#000000",
          "background": "__ACCENT__",
          "template": "  {{ .Path }} "
        },
        {
          "type": "git",
          "style": "diamond",
          "leading_diamond": "",
          "trailing_diamond": "",
          "foreground": "#000000",
          "background": "#2dd4a7",
          "template": " {{ .HEAD }} "
        }
      ]
    },
    {
      "type": "prompt",
      "alignment": "right",
      "segments": [
        {
          "type": "exit",
          "style": "diamond",
          "leading_diamond": "",
          "trailing_diamond": "",
          "foreground": "#ffffff",
          "background": "#2e7d32",
          "background_templates": ["{{ if gt .Code 0 }}#c62828{{ end }}"],
          "template": " {{ if gt .Code 0 }}{{ else }}{{ end }} "
        }
      ]
    }
  ]
}
```

The glyphs/schema fields above are my best-effort draft. I need to validate
them against whatever oh-my-posh version actually installs in Step 1 below
and adjust, same spirit as MOTD's Step 2 telling me to match `case`
patterns against real `hostname`/`systemctl` output instead of trusting the
doc blindly.

## File location (per server)

Just one file now, not three. The per-host color is baked in at deploy
time rather than chosen from a set of theme files:

```
~/.config/oh-my-posh/theme.omp.json
```

## Deployment mechanism: Ansible template (per-host color substitution)

Mirrors `docs/17-custom-ssh-motd` Step 5 Option B (`motd.yml`), which I
already have prior art for.

`templates/theme.omp.json.j2`, same JSON as above, `__ACCENT__` replaced
with `{{ oh_my_posh_accent }}`.

`host_vars/<alias>.yml` (one per host) or a single `group_vars/all.yml`
lookup table, either way I set `oh_my_posh_accent` from the table above,
e.g.:

```yaml
# host_vars/linux-mysql.yml
oh_my_posh_accent: "#0087ff"
```

`oh-my-posh.yml`:

```yaml
- hosts: all
  tasks:
    - name: Install oh-my-posh
      shell: curl -s https://ohmyposh.dev/install.sh | bash -s
      args:
        creates: /usr/local/bin/oh-my-posh

    - name: Create themes directory
      file:
        path: ~/.config/oh-my-posh
        state: directory

    - name: Render this host's theme with its accent color
      template:
        src: theme.omp.json.j2
        dest: ~/.config/oh-my-posh/theme.omp.json

    - name: Wire it into .bashrc
      lineinfile:
        path: ~/.bashrc
        line: 'eval "$(oh-my-posh init bash --config ~/.config/oh-my-posh/theme.omp.json)"'
        create: true
```

I run it the same skip-what's-off way as `motd.yml`:

```bash
ansible-playbook -i inventory.ini oh-my-posh.yml --limit all:!offline_hosts
```

### Quick-loop fallback (no Ansible)

If I'm rolling out to just one or two hosts that happen to be up, same
pattern as MOTD's Option A, I generate the file locally with the right
color substituted in, then `scp` it over:

```bash
for host in linux-app-server linux-mysql linux-vault; do  # etc.
  if ! ssh -o ConnectTimeout=3 -o BatchMode=yes "$host" true 2>/dev/null; then
    echo "SKIP: $host unreachable"; continue
  fi
  # generate /tmp/theme-$host.omp.json locally with that host's __ACCENT__ substituted
  scp "/tmp/theme-$host.omp.json" "$host:~/.config/oh-my-posh/theme.omp.json" \
    && echo "DONE: $host"
done
```

## Known risk: `linux-oracle-db`

Same host that needed special handling for MOTD (Notes items 10-11 in
`docs/17-custom-ssh-motd`):
- No sudo, so installer/config steps need `su -`, not `sudo`.
- Tailscale's local DNS stub `SERVFAIL`s on non-tailnet domains, so
  `curl https://ohmyposh.dev/install.sh` will likely fail exactly like
  `apt`/`dnf` did for figlet. The same workaround should apply: fetch the
  oh-my-posh binary on a peer host with working DNS and copy it over
  directly, or temporarily add `nameserver 1.1.1.1` and revert after
  (already root-caused in that doc's Notes item 11, this is the same
  tailnet-wide gap, not a new problem).
- `linux-vault` may hit the same DNS gap.

## Proxmox host node (`taufiq`)

In scope. It keeps `fastfetch` exactly as-is (that's my login-splash
equivalent of MOTD there, unaffected by this plan) and additionally gets
its own oh-my-posh prompt using the same shared template and its own
accent color (`#607d8b`, from the table above), the same "MOTD for the
banner, oh-my-posh for the prompt" split I'm giving the guest fleet.

One quirk carries over from the fastfetch addendum in
`docs/17-custom-ssh-motd`: on this host specifically, `.bashrc` gets
sourced even for non-interactive scripted `ssh taufiq "some command"`
invocations (I confirmed that there, it's not standard bash behavior, my
guest fleet's `.bashrc` doesn't have this problem, only `taufiq` does).
That's why fastfetch's line there is wrapped in an interactive-shell guard.
The oh-my-posh `eval` line needs the same guard on this host, or every
scripted SSH command against `taufiq` (including any Ansible run) prints a
colored prompt frame into otherwise-clean output:

```bash
# Append to /root/.bashrc, same guard fastfetch already uses there
case $- in
    *i*) eval "$(oh-my-posh init bash --config ~/.config/oh-my-posh/theme.omp.json)" ;;
esac
```

Install itself should be simpler than the guest fleet. Proxmox VE is
Debian-based, so I don't expect the Oracle-Linux-style sudo/DNS problems,
the plain `curl | bash` install should just work.

## Open decisions

- Client-side Windows Terminal already runs oh-my-posh with Tokyo Night
  locally, that's unrelated to this plan (it's my local pwsh prompt, not
  an SSH session prompt) and doesn't need to change.
- Exact glyphs/icons depend on the installed oh-my-posh schema version, I
  need to confirm during Step 1 on the first host and adjust the template
  once, then it applies to all.

## Execution order (confirmed)

Not a full-fleet push, staged based on the current Proxmox power state
snapshot (Datacenter > taufiq server view):

```
┌──────────────────────────────────────────────┐
│  OH-MY-POSH FLEET ROLLOUT — EXECUTION FLOW    │▏
└──────────────────────────────────────────────┘▔▔
                     │
                     ▼
┌──────────────────────────────────────────────┐
│ PHASE 1 — currently ACTIVE hosts (7)          │▏  k3s, mongodb, vault, gh-runner,
│                                                │▏  mysql-2, mariadb-2, observability
└──────────────────────────────────────────────┘▔▔
                     │
                     ▼
┌──────────────────────────────────────────────┐
│ Step 1 — customize Active Host #1 (k3s)       │▏  install oh-my-posh, deploy this
│                                                │▏  host's theme.omp.json, wire .bashrc
└──────────────────────────────────────────────┘▔▔
                     │
                     ▼
┌──────────────────────────────────────────────┐
│ STOP — you SSH in and check the prompt        │▏  I wait here, no further action
└──────────────────────────────────────────────┘▔▔
                     │  (you approve)
                     ▼
┌──────────────────────────────────────────────┐
│ Step 2 — customize Active Host #2 (mongodb)   │▏  same install/deploy steps
└──────────────────────────────────────────────┘▔▔
                     │
                     ▼
┌──────────────────────────────────────────────┐
│ STOP — you SSH in and check the prompt        │▏  second confirmation
└──────────────────────────────────────────────┘▔▔
                     │  (you approve both)
                     ▼
┌──────────────────────────────────────────────┐
│ Step 3 — remaining 5 active hosts             │▏  no more pauses, I proceed
│           customized autonomously             │▏  host-by-host on my own
└──────────────────────────────────────────────┘▔▔
                     │
                     ▼
┌──────────────────────────────────────────────┐
│ PHASE 2 — currently OFF hosts (8)             │▏  app-server, sql-server, spring-
│                                                │▏  boot-app, mysql, mariadb, postgres,
│                                                │▏  oracle-db, mini-io
└──────────────────────────────────────────────┘▔▔
                     │
                     ▼
┌──────────────────────────────────────────────┐
│ ⚠ CONFIRM — shut down all Phase 1 hosts       │▏  frees RAM for Phase 2, this is
│   (now customized and already approved)       │▏  a power-state change, ask first
└──────────────────────────────────────────────┘▔▔
                     │
                     ▼
┌──────────────────────────────────────────────┐
│ Step 4 — power on + customize each off-host,  │▏  one at a time; no per-host SSH
│           one at a time                       │▏  verification (already approved)
└──────────────────────────────────────────────┘▔▔
                     │
                     ▼
┌──────────────────────────────────────────────┐
│ Step 5 — power that host back down again      │▏  restores it to the "off" state
│           once customization is confirmed      │▏  it had in the image, matches
│           applied                              │▏  the MOTD rollout precedent
└──────────────────────────────────────────────┘▔▔
                     │
                     ▼
┌──────────────────────────────────────────────┐
│ Step 6 — power Phase 1 hosts back on          │▏  restores the original active/
│           once all of Phase 2 is done         │▏  inactive split from the image
└──────────────────────────────────────────────┘▔▔
```

**Phase 1, currently active hosts, in this order:** `linux-k3s`,
`linux-mongodb`, `linux-vault`, `linux-gh-runner`, `linux-mysql-2`,
`linux-mariadb-2`, `linux-observability`.
- Host 1 (`linux-k3s`) and host 2 (`linux-mongodb`) get deployed, then I
  stop and wait for a live SSH check before continuing.
- Once both are approved, the remaining 5 active hosts get done without
  per-host verification.

**Phase 2, currently off hosts, in this order:** `linux-app-server`,
`linux-sql-server`, `spring-boot-app`, `linux-mysql`, `linux-mariadb`,
`linux-postgres`, `linux-oracle-db`, `linux-mini-io`.
- Before starting Phase 2, shut down all 7 Phase 1 hosts to free RAM
  (confirmed before doing it, it's a power-state change).
- Each Phase 2 host: power on, customize, then power back off again,
  restoring it to the "off" state it was in on the image, one host at a
  time. No per-host SSH verification needed here (already approved in
  Phase 1), only the power-cycling itself gets done carefully.
- Once every Phase 2 host is customized and back off, Phase 1 hosts get
  powered back on to restore the original active/inactive split.

Out of scope: `opnsense` (200, router/BSD appliance, no bash prompt to
theme) and `9000` (template, not a running host).

## Rollout status

Not started yet, tracked here as it happens, same table shape as
`docs/17-custom-ssh-motd`'s Rollout Status section.

| Host | Status |
|---|---|
| `linux-k3s` | Done, approved by live SSH check |
| `linux-mongodb` | Done, approved by live SSH check. Needed a `tailscaled` restart first, see Notes. |
| `linux-vault` | Done, colors verified programmatically (Phase 1, autonomous) |
| `linux-gh-runner` | Done, colors verified programmatically (Phase 1, autonomous) |
| `linux-mysql-2` | Done, colors verified programmatically (Phase 1, autonomous) |
| `linux-mariadb-2` | Done, colors verified programmatically (Phase 1, autonomous) |
| `linux-observability` | Done, colors verified programmatically (Phase 1, autonomous) |
| `linux-app-server` | Done, colors verified programmatically. Was already running by the time Phase 2 started (see Notes item 7), no power cycle needed. |
| `linux-mysql` | Done, colors verified programmatically. Was already running (see Notes item 7). |
| `linux-mariadb` | Done, colors verified programmatically. Was already running (see Notes item 7). |
| `linux-postgres` | Done, colors verified programmatically. Was already running (see Notes item 7). |
| `linux-mini-io` | Done, colors verified programmatically. Was already running (see Notes item 7). |
| `linux-sql-server` | Done, colors verified. Powered on, customized, powered back off (original state restored). |
| `spring-boot-app` | Done, colors verified. Powered on, customized, powered back off (needed a longer shutdown timeout, see Notes). |
| `linux-oracle-db` | Done, colors verified. Powered on, customized (binary copied from `linux-vault` over Tailscale, see Notes), powered back off. |
| `taufiq` | Pending (host node, own section above) |

## Notes (rollout findings so far)

1. **Neither `linux-k3s` nor `linux-mongodb` had passwordless sudo, and
   `unzip` (required by oh-my-posh's official `install.sh`) wasn't
   installed on either.** Rather than block on a sudo password, I skip the
   installer script entirely and pull the plain Linux binary directly from
   GitHub releases (`posh-linux-amd64`) into `~/.local/bin/oh-my-posh`, no
   root and no `unzip` needed. Using this method for the rest of the fleet
   too unless a host turns out to already have passwordless sudo.
2. **This Windows client can't resolve `*.taufiq.lab` hostnames right now**
   (`ssh linux-k3s` fails with "Could not resolve hostname"), same
   Tailscale/NRPT DNS quirk already documented in
   `docs/17-custom-ssh-motd` Notes item 7. Worked around it during this
   rollout by connecting directly via each host's Tailscale IP with
   `-F /dev/null` to bypass `~/.ssh/config`'s `HostName` override (which
   otherwise re-triggers the same broken DNS lookup even when connecting
   by IP, since the config matches on the IP and rewrites the target back
   to the hostname). Normal `ssh <alias>` should still work once the
   client-side DNS routing is fixed the same way as before
   (`tailscale set --accept-dns=false` then `--accept-dns=true`).
3. **`linux-mongodb` was completely unreachable over SSH** (TCP port 22
   timed out, no SYN-ACK, nothing logged in the container's `auth.log`)
   even though Tailscale reported it "active" with a recent handshake.
   Ruled out an OPNsense/VLAN-wide block first, by confirming two other
   active VLAN 20 (database tier) hosts, `linux-mysql-2` and
   `linux-mariadb-2`, were reachable fine the whole time. `sshd` and `ufw`
   inside the container both looked correctly configured
   (`22/tcp ALLOW Anywhere`, sshd listening on `0.0.0.0:22`), and
   `tailscale ping` succeeded via DERP relay, but `RxBytes` on this
   client's peer entry for it was almost zero, pointing at a stuck
   `tailscaled` specifically on that container. Fixed with
   `pct exec 108 -- systemctl restart tailscaled` from the Proxmox host,
   SSH worked immediately after.
4. **The first oh-my-posh theme file I wrote for `linux-mongodb` had
   silently empty `leading_diamond`/`trailing_diamond` fields** even though
   I intended the same rounded-cap glyphs as `linux-k3s`. Manually retyping
   the JSON in a fresh file lost the invisible Unicode characters; `cat -A`
   showed `linux-k3s`'s file correctly had `M-nM-^BM-6`/`M-nM-^BM-4`
   (U+E0B6/U+E0B4) while `linux-mongodb`'s had nothing between the quotes.
   Fixed it, and avoided repeating the mistake for every other host, by
   generating each host's file from a byte-exact copy of the known-good
   `linux-k3s` file via `sed`, substituting only the accent color hex,
   never retyping the JSON by hand again.
5. **`linux-k3s` and `linux-observability` had no custom SSH MOTD banner at
   all** (plain stock Ubuntu welcome message, not the figlet/role/stats
   banner from `docs/17-custom-ssh-motd`), since both postdate that
   rollout's original 13-host fleet. Extended the shared `99-custom` script
   with a case entry for each: `linux-k3s` (role "K3s (Kubernetes) Server",
   accent 63) and `linux-observability` (role "Observability Stack
   (Prometheus/Grafana/Loki)", accent 37, checking `prometheus`,
   `grafana-server`, and `loki`). Neither host had passwordless sudo either
   (needed for `apt install figlet` and writing to `/etc/update-motd.d/`),
   fixed by adding an `/etc/sudoers.d/<user>` NOPASSWD entry for each,
   done by the user directly rather than over a non-interactive session.
   Verified both by triggering a real login and reading `/run/motd.dynamic`
   directly, not just running the script by hand. Spot-checked the
   remaining active Phase 1 hosts (`linux-vault`, `linux-gh-runner`,
   `linux-mysql-2`, `linux-mariadb-2`) still had their existing MOTD script
   intact, unaffected by any of this.
6. **This Windows client's `*.taufiq.lab` DNS quirk (item 2 above) also
   affected the user's own terminal, not just this agent's SSH calls** —
   `ssh linux-observability` failed to resolve for the user directly.
   `nslookup` kept reporting failure even after the `tailscale set
   --accept-dns` toggle, which was misleading: `nslookup` doesn't reliably
   go through Windows' NRPT policy the way normal applications (including
   `ssh`) do, so it looked unfixed when it actually wasn't. Confirmed the
   real fix worked by testing with `ssh` itself, not `nslookup`.
7. **By the time Phase 2 started, the actual Proxmox power state no longer
   matched the plan's snapshot** — `qm list` showed `linux-app-server`,
   `linux-mysql`, `linux-mariadb`, `linux-postgres`, and `linux-mini-io` all
   already running, not off like in the original screenshot (only
   `linux-sql-server`, `spring-boot-app`, and `linux-oracle-db` were still
   actually off). Rather than force the original power-cycle plan onto
   hosts that were already up, customized those 5 directly with no power
   change, and kept the power-on/customize/power-off cycle for the 3 still
   genuinely off. All 7 Phase 1 hosts were left running throughout, no
   shutdown needed after all.
8. **`linux-postgres`'s first oh-my-posh binary download timed out**
   (`curl` exit 28), but a retry immediately after succeeded in well under
   a second, and every diagnostic (DNS, TLS handshake to `github.com`, the
   redirect chain to `release-assets.githubusercontent.com`) came back
   clean. Concluded it was a one-off transient hiccup, not an OPNsense
   block or a host-specific network gap like `linux-vault`/`linux-oracle-db`
   had during the MOTD rollout, no lasting fix needed.
9. **`spring-boot-app`'s graceful shutdown (`qm shutdown`) timed out on the
   first attempt** ("VM quit/powerdown failed - got timeout"), left running.
   A retry with an explicit longer `--timeout 60` succeeded. Likely just a
   slow-stopping Spring Boot service, not investigated further since the
   retry worked cleanly.
10. **`linux-oracle-db` hit the exact same tailnet-wide DNS gap documented
    in `docs/17-custom-ssh-motd` Notes item 11**, and still has no sudo at
    all for this SSH user. Since oh-my-posh's binary-only install needs no
    root, the only blocker was downloading it, worked around by copying
    the binary this rollout already fetched onto `linux-vault` straight
    across Tailscale (`scp` host-to-host) instead of touching this host's
    DNS or `su -`ing in to fix it, same "borrow it from a peer with working
    DNS" approach used for `figlet` there originally. Powered back off via
    `qm shutdown` from the Proxmox host itself, which doesn't need the
    guest's own sudo/root at all.
