# SSH Config Alias Coverage — Closing the Gap

**Author:** Taufiq
**Date:** 24 July 2026
**Scope:** Every VM/CT in the fleet gets a short SSH alias, not just most of them.

---

## What I Built

Added `Host` blocks in `~/.ssh/config` for the three guests that didn't have one: `spring-boot-app`, `linux-mongodb`, and `linux-mini-io`. Every one of the 13 VMs/CTs, plus the Proxmox host itself, now has a short alias resolving through `*.taufiq.lab` DNS, same pattern as every other entry already in the file:

```
Host spring-boot-app spring-boot-app.taufiq.lab 100.120.243.96
    HostName spring-boot-app.taufiq.lab
    User spring-boot-app

Host linux-mongodb linux-mongodb.taufiq.lab 100.82.200.94
    HostName linux-mongodb.taufiq.lab
    User linux-mongodb

Host linux-mini-io linux-mini-io.taufiq.lab 100.73.172.85
    HostName linux-mini-io.taufiq.lab
    User linux-mini-io
```

## Why I Built It

Found the gap by accident — trying to SSH to `spring-boot-app` and `app-server` by DNS name during the network segmentation work, and discovering `app-server` only had a working alias under `linux-app-server` (its `app-server.taufiq.lab` DNS record itself doesn't even resolve — a pre-existing stale-alias gap already flagged in `docs/02-dns/dns-setup.md` §12). Checking the actual config file turned up two more gaps that had nothing to do with DNS at all: `linux-mongodb` and `linux-mini-io` had valid DNS records but no SSH alias had ever been written for them. Fixed all three at once rather than patching them as I happened to trip over each one individually.

---

## What Broke, How I Found It, and How I Recovered

### 1. Didn't know the login username for two of the three

**Broke:** Guessing at `linux-mini-io`'s username — tried `mini-io`, `minio`, and `taufiq` — got `Permission denied (publickey,password)` on every attempt.

**Found it:** Every other CT/VM added to this config in the last few sessions (`linux-vault`, `linux-gh-runner`, `linux-mysql-2`, `linux-mariadb-2`) uses its own hostname as the login username. Tried that pattern directly instead of guessing.

**Recovered:** `linux-mongodb@100.82.200.94` and `linux-mini-io@100.73.172.85` both worked on the first try once tested against the actual pattern instead of guessing — confirmed via `whoami` returning the expected username on each.

### 2. `spring-boot-app`'s alias failed with "Host key verification failed" on first use

**Broke:** `ssh spring-boot-app` (using the freshly-added alias) failed immediately with `Host key verification failed` — not even a yes/no prompt, an outright failure.

**Found it:** The config's wildcard block (`Host *.taufiq.lab`, setting `StrictHostKeyChecking no`) only matches when the *typed* destination itself ends in `.taufiq.lab` — a bare short alias like `spring-boot-app` doesn't match that pattern, so it doesn't inherit the auto-accept. This is the exact same quirk already documented in `docs/02-dns/dns-setup.md` §12b for `linux-vault` and `linux-gh-runner`'s first connections; it had just never come up for `spring-boot-app` before because nothing had connected to it by that alias yet.

**Recovered:** Connected once via the full FQDN (`ssh spring-boot-app.taufiq.lab`), which *does* match the wildcard and silently accepted/cached the host key. The short alias worked cleanly immediately after:
```
$ ssh spring-boot-app.taufiq.lab "whoami && hostname"
Warning: Permanently added 'spring-boot-app.taufiq.lab' (ED25519) to the list of known hosts.
spring-boot-app
spring-boot-app

$ ssh spring-boot-app "whoami && hostname"
spring-boot-app
spring-boot-app
```

`linux-mongodb` and `linux-mini-io` didn't hit this at all — both connected cleanly on the very first try, presumably because something had already reached them by their `.taufiq.lab` name before.

---

## Where Things Stand

All 13 VMs/CTs plus the Proxmox host have a working SSH alias, verified end-to-end (not just "config looks right" — each one was actually connected to and confirmed with `whoami`/`hostname`). This is a local `~/.ssh/config` change only, not part of this git repo, so there's nothing to commit for it — this doc is the record of it instead.

Independently re-confirmed from my own terminal afterward — `ssh spring-boot-app` logs straight in (full MOTD banner, no host-key prompt), and re-running the network segmentation isolation checks from there reproduced the exact same results as the plan doc's Proof section (Oracle allowed, MySQL blocked, Management blocked, internet allowed):

![ssh spring-boot-app logging in cleanly and reproducing the exact same isolation test results independently](images/proof-alias-and-isolation-independently-verified.png)

Still-open, pre-existing item unrelated to this fix: `app-server.taufiq.lab` itself still doesn't resolve (only the `linux-app-server` / `app.taufiq.lab` forms work) — tracked in `docs/02-dns/dns-setup.md` §12, not touched here.
