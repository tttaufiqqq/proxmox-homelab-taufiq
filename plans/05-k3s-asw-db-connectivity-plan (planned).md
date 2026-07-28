# k3s → Real 5-Database Fleet Connectivity Plan

A staged plan to wire `Animal-Shelter-Workshop`'s k3s Deployment (`k8s/`,
Stage 5 of `devops-practice-plan.md`) to the real 5-connection database
fleet, replacing the current `DB_CONNECTION=sqlite` placeholder in
`asw-app-config`. This is the "later, harder step" both Stage 5's and
Stage 4's writeups explicitly deferred — see
`docs/19-devops-practice/06-k3s-single-node-deployment-and-vault-injector.md`'s
own "What carries forward" section: *"Wiring the app's actual 5-connection
DB credentials through the injector is future work, not done here."*

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

## Prerequisite finding: firewall is IP-locked, not interface-locked

Read `infrastructure/ansible/roles/db_firewall/tasks/main.yml` and
`defaults/main.yml`: every one of the 5 DB hosts' UFW rules allows the DB
port from exactly one hardcoded IP, `app_server_tailscale_ip`
(`100.100.123.90`), plus separate SSH-only rules for the admin machine and
`linux-gh-runner`. There is **no existing rule for `linux-k3s`**
(`100.109.241.125`) — without Stage 1 below, every connection attempt from
inside the cluster gets refused at the firewall regardless of Tailscale
reachability.

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
add a new allow rule (copy of the existing app-server one) for
`linux-k3s`'s Tailscale IP (`100.109.241.125`), alongside the existing
`app_server_tailscale_ip` rule — same task file, same role, applies to
all 5 DB host playbooks (`linux-mysql`, `linux-mysql-2`, `linux-mariadb`,
`linux-mariadb-2`, `linux-postgres`) in one change. Re-run each of the 5
playbooks (`ansible-playbook playbooks/linux-mysql.yml` etc.) to apply.
Verify: `ssh <db-host> "sudo ufw status numbered"` shows a new rule for
`100.109.241.125` on each of the 5 hosts, and the existing app-server rule
is untouched.

**Stage 2 — Vault wiring.** On `linux-vault` (already has
`auth/kubernetes/*` enabled from Stage 5's demo):
- Write a new policy scoped to the real secret path, read-only:
  `vault policy write asw-k8s-db asw-k8s-db-policy.hcl` (grants `read` on
  `secret/data/animal-shelter-workshop`, not the broader `asw-deploy`
  AppRole's scope, kept least-privilege same as every other Vault policy
  in this homelab).
- `vault write auth/kubernetes/role/asw-k8s-db bound_service_account_names=asw-app
  bound_service_account_namespaces=default policies=asw-k8s-db ttl=1h`
- Add a real `ServiceAccount` named `asw-app` to `k8s/` (the Deployment
  currently runs under the implicit `default` ServiceAccount — needs to
  be explicit so the Vault k8s role can bind to it by name), and set
  `serviceAccountName: asw-app` on the Deployment's pod spec.
- Add the injector annotations + entrypoint fix (see prerequisite finding
  above) to `k8s/deployment.yaml`.
- Verify: `kubectl exec deploy/asw-app -c app -- cat /vault/secrets/db.env`
  shows all 5 `DBn_PASSWORD=...` lines with the real value, not a demo
  string.

**Stage 3 — Wire one connection, verify, repeat.** Starting with `users`
(DB5, Postgres — it's `DB_CONNECTION`'s default and hosts the migrations
ledger, so proving it first validates the riskiest one early): update
`asw-app-config`'s `DB5_HOST`/`DB5_PORT`/`DB5_DATABASE`/`DB5_USERNAME` to
the real values (password comes from the injected `db.env`, not the
ConfigMap), `kubectl apply` + `kubectl rollout status`, then check
`curl http://<node>:30080/api/database-status` — expect only `users:
{"connected": true}` to flip, the other 4 unchanged. Repeat for
`shelter` (DB2), `animals` (DB3), `booking` (DB4), `reporting` (DB1), one
at a time, same verify step after each. **Never run `php artisan
migrate`** as part of this — the goal is reachability/credentials, not a
schema change against live (lab) data.

**Stage 4 — Done.** `/api/database-status` shows all 5
`{"connected": true}` through the k3s NodePort Service. Optionally clean
up Stage 5's exploratory scaffolding (`vault-demo` Pod/ServiceAccount,
`secret/k3s-demo` path) now that the real wiring supersedes it — per this
homelab's usual discipline of not leaving throwaway proof-of-concept
objects lying around once the real thing exists.

---

## Verification summary

- `sudo ufw status numbered` on all 5 DB hosts shows the new
  `linux-k3s` rule.
- `kubectl exec deploy/asw-app -c app -- cat /vault/secrets/db.env` shows
  real credentials, not the demo secret.
- `/api/database-status` progresses one connection at a time from `0/5`
  to `5/5 online`, each step confirming exactly one flip and zero
  regressions on the others.
- No `php artisan migrate` run against the real fleet during this plan.
