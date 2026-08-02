# k3s → Real 5-Database Fleet Connectivity Plan

A staged plan to wire `Animal-Shelter-Workshop`'s k3s Deployment (`k8s/`,
Stage 5 of `devops-practice-plan.md`) to the real 5-connection database
fleet, replacing the demo-only `DBn_HOST` placeholders in
`asw-app-config`. This was the "later, harder step" both Stage 5's and
Stage 4's writeups explicitly deferred — see
`docs/19-devops-practice/05-k3s-single-node-deployment-and-vault-injector.md`'s
own "What carries forward" section, which used to say *"Wiring the app's
actual 5-connection DB credentials through the injector is future work,
not done here."* — now done, and that doc's own text reflects it.

**Result: executed.** All 5 connections are wired and verified live
(`allOnline: true` via `/api/database-status` through the k3s NodePort
Service), through the real Vault Agent Injector path, not a shortcut.
Verifying Stage 1 also surfaced and fixed a real, pre-existing firewall
gap affecting all 5 DB hosts — see the finding below.

Chosen over the docker-compose (Stage 4) route deliberately: `linux-k3s`
(CT 100) is already a stable, Tailscale-joined host, and the Vault Agent
Injector is already installed and proven against it. A docker-compose
route would run on an untailscaled Docker host (e.g. a laptop), needing a
throwaway Tailscale sidecar whose IP would have to be re-added to 5
firewalls every time it changes — real work with nothing durable to show
for it. This plan produces the actual, permanent wiring instead.

This plan touches the **sibling repo** `Animal-Shelter-Workshop` (local
path `C:\Users\taufi\Documents\Dev\Animal-Shelter-Workshop`) — its
`infrastructure/ansible/roles/db_firewall`, `k8s/*.yaml`, and Vault's live
API — not this repo directly.

---

## Flow

```
┌────────────────────────────────────┐
│   WIRE K3S → ALL 5 REAL DBS        │▏
└────────────────────────────────────┘▔▔

┌────────────────────────────────┐     add linux-k3s's Tailscale IP to
│ 1. Open the firewall             │▏    each of the 5 DB hosts' UFW rule
│    (db_firewall role, x5 hosts)  │▏    (currently only app-server's IP
└────────────────────────────────┘▔▔    is allowed)
              │
              ▼
┌────────────────────────────────┐     Deployment's pod template gets
│ 2. Wire Vault Agent Injector      │▏    the injector annotation, same
│    into the app's Deployment      │▏    AppRole the VM's Vault Agent
└────────────────────────────────┘▔▔    already uses — no plaintext k8s Secret
              │
              ▼
┌────────────────────────────────┐     e.g. 'users' first — set DBn_HOST
│ 3. Wire ONE connection            │▏    to its real Tailscale IP, password
│    (repeat x5, not all at once)  │▏    from Vault, redeploy
└────────────────────────────────┘▔▔
              │
              ▼
┌────────────────────────────────┐     hit /api/database-status, confirm
│ 4. Verify                        │▏    only that one connection flipped
│                                   │▏    to true, other 4 unaffected
└────────────────────────────────┘▔▔
              │
              ▼
        repeat 3→4 for the other 4 connections
              │
              ▼
┌────────────────────────────────┐     all 5 show connected:true —
│ 5. Done                          │▏    real production DB fleet, reached
│                                   │▏    from inside k3s
└────────────────────────────────┘▔▔
```

---

## Finding: the firewall was never actually enforcing per-source IPs at all

Read `infrastructure/ansible/roles/db_firewall/tasks/main.yml` and
`defaults/main.yml`: every one of the 5 DB hosts' UFW rules allows the DB
port from exactly one hardcoded IP, `app_server_tailscale_ip`
(`100.100.123.90`), plus separate SSH-only rules for the admin machine and
`linux-gh-runner`. There was no rule for `linux-k3s` (`100.109.241.125`),
so the plan was to add one before wiring k3s to the DB fleet.

Testing that assumption live turned up something bigger: a raw `nc -zv`
from `linux-k3s` to a DB port succeeded even with *no* matching UFW rule.
`iptables -L INPUT -n -v` on the DB host showed why — Tailscale's own
netfilter management inserts a `ts-input` chain at the very top of
`INPUT`, ahead of every `ufw-*` chain, and that chain unconditionally
`ACCEPT`s all traffic arriving on `tailscale0`. Since `ACCEPT` is terminal
in netfilter, ufw's `from_ip`-scoped rules never even got evaluated for
tailnet traffic. **Every DB host's UFW port restriction has been a no-op
since these hosts were provisioned** — any device on the tailnet, not
just `app-server`, could already reach every DB port directly. This
predates this plan entirely; it just happened to surface while verifying
Stage 1's premise.

Fixed by running `tailscale set --netfilter-mode=off` on all 5 DB hosts
(none of them advertise subnet routes, so nothing else depends on
Tailscale's netfilter management) — this hands `tailscale0` back to ufw
like any other interface, and it now actually enforces. Confirmed:
`linux-k3s` was blocked immediately after the switch (before its own
allow rule was added), `app-server` stayed reachable throughout, and
`tailscale ping` (mesh connectivity itself) was unaffected. Landed in
`infrastructure/ansible/roles/db_firewall/tasks/main.yml` as a new task
ahead of the existing UFW rules, alongside the `linux-k3s` allow rule
itself — same role, same change, applied to all 5 DB host playbooks.

## Prerequisite finding: use raw Tailscale IPs, not MagicDNS hostnames

`config/database.php`'s own connection defaults are already the plain
Tailscale IPs (`DB1_HOST` defaults to `100.78.124.25`, etc.) — only
`env-app.j2` overrides them with MagicDNS hostnames, and that's a
VM-specific trick reserved for the CT-migration hostname-reuse cutover
(see `asw-db-vms-to-ct-migration-plan.md`). For k3s, set the k8s
ConfigMap's `DBn_HOST` to the raw IP directly, sidestepping MagicDNS/
cluster-DNS resolution entirely — one less moving part.

## Prerequisite finding: php-fpm needs an entrypoint change to pick up injected secrets

The VM's existing pattern (`playbooks/tasks/vault-agent.yml`) runs
`vault agent -exec="php-fpm ..."`, so Vault Agent launches php-fpm itself
after rendering secrets, guaranteeing php-fpm's process environment
already has them. The Vault Agent Injector's default k8s pattern is
different — it's a sidecar that renders a secrets file into a shared
volume (e.g. `/vault/secrets/db.env`), but the `app` container's existing
entrypoint just execs `php-fpm` directly and never reads that file. A
rendered file that nothing sources is invisible to php-fpm.

Fix: add a thin entrypoint script to the Dockerfile
(`Animal-Shelter-Workshop/Dockerfile`) that sources the injector's
rendered file before exec'ing php-fpm, e.g.:
```sh
#!/bin/sh
set -a
[ -f /vault/secrets/db.env ] && . /vault/secrets/db.env
set +a
exec php-fpm
```
Use `vault.hashicorp.com/agent-inject-template` on the Deployment's pod
annotations to render one `db.env` file containing all 5 `DBn_PASSWORD`
lines (all 5 connections share one credential, `asw_secrets.db_password`,
per `env-app.j2`'s own comment — one Vault field, fanned into 5 identical
env var lines), rather than 5 separate injected files.

---

## Staged execution

**Stage 1 — Firewall.** In `infrastructure/ansible/roles/db_firewall/`,
added a `tailscale set --netfilter-mode=off` task ahead of the existing
UFW rules (see finding above — without it, ufw's rules on `tailscale0`
never actually run), plus a new allow rule for `linux-k3s`'s Tailscale IP
(`100.109.241.125`), alongside the existing `app_server_tailscale_ip`
rule — same task file, same role, applies to all 5 DB host playbooks
(`linux-mysql`, `linux-mysql-2`, `linux-mariadb`, `linux-mariadb-2`,
`linux-postgres`). Ran all 5 playbooks (4 via `ansible-playbook` from
WSL against `inventory-ip.yml`; `linux-mysql` applied by hand over SSH
instead, since WSL's own Tailscale identity isn't on the SSH allowlist
and got locked out by this very fix mid-run — a live demonstration that
the fix works). Verified: `sudo iptables -L INPUT -n` shows the
`ts-input` chain is gone on all 5 hosts, `sudo ufw status numbered` shows
the new `linux-k3s` rule on all 5, `nc -zv` from `linux-k3s` to each DB
port succeeds, and the same probe from an unlisted source now correctly
times out.

**Stage 2 — Vault wiring.** On `linux-vault` (already had
`auth/kubernetes/*` enabled from Stage 5's demo):
- Reused the existing `asw-deploy` policy (the same one the Ansible
  AppRole deploy already reads from `secret/data/animal-shelter-workshop`)
  rather than writing a new dedicated one — one real secret path, one
  policy, read by two different auth methods (AppRole for Ansible,
  Kubernetes auth for the cluster).
- `vault write auth/kubernetes/role/asw-app bound_service_account_names=asw-app
  bound_service_account_namespaces=default policies=asw-deploy ttl=1h`
- Added a real `ServiceAccount` named `asw-app` (`k8s/service-account.yaml`)
  — the Deployment used to run under the implicit `default` ServiceAccount
  — and set `serviceAccountName: asw-app` on the Deployment's pod spec.
- Added the injector annotations to `k8s/deployment.yaml`'s pod template:
  `vault.hashicorp.com/agent-inject-template-db.env` renders one file with
  `APP_KEY` plus all 5 `DBn_PASSWORD` lines (all 5 connections share one
  Vault field, `asw_secrets.db_password`, fanned into 5 identical env
  lines). For the entrypoint problem (see prerequisite finding above), the
  `app` container's `command`/`args` were overridden inline —
  `[". /vault/secrets/db.env && exec php-fpm"]` — instead of adding a
  separate entrypoint script to the Dockerfile; same effect, one less file.
- Verified: `kubectl exec deploy/asw-app -c app -- cat /vault/secrets/db.env`
  shows all 5 `DBn_PASSWORD=...` lines with the real `workshop_2_prod`
  value, not a demo string.

**Stage 3 — Wire all 5 connections.** `asw-app-config`'s `DBn_HOST`/
`DBn_PORT`/`DBn_DATABASE`/`DBn_USERNAME` (password comes from the injected
`db.env`, not the ConfigMap) are set to the real values for all 5
connections, applied via `kubectl apply` + `kubectl rollout status`, and
verified with `curl http://<node>:30080/api/database-status`. No
`php artisan migrate` was run against the real fleet as part of this —
the goal was reachability/credentials, not a schema change against live
(lab) data.

**Stage 4 — Done.** `/api/database-status` shows all 5
`{"connected": true}` through the k3s NodePort Service, confirmed live
during this plan's own verification pass. Stage 5's exploratory
scaffolding (`vault-demo` Pod/ServiceAccount, `secret/k3s-demo` path) is
still present — not yet cleaned up, left as a small follow-up rather than
blocking this plan.

---

## Verification summary

- `sudo ufw status numbered` on all 5 DB hosts shows the new
  `linux-k3s` rule, and `sudo iptables -L INPUT -n` confirms the
  Tailscale `ts-input` bypass chain is gone on all 5.
- `nc -zv` from `linux-k3s` to each DB port succeeds; the same probe from
  an unlisted tailnet source now correctly times out — ufw is enforcing
  for real, not just presenting rules that never run.
- `kubectl exec deploy/asw-app -c app -- cat /vault/secrets/db.env` shows
  real `workshop_2_prod` credentials, not a demo secret.
- `/api/database-status` shows `5/5` connected, `allOnline: true`,
  through the k3s NodePort Service.
- No `php artisan migrate` run against the real fleet during this plan.
