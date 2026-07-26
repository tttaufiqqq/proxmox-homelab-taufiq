<!-- Not yet sequenced into a numbered docs/ folder, lives here in
     docs/19-devops-practice/ until the full devops-practice-plan.md is complete.
     Date below is provisional (the date this actually happened); revisit
     once final sequencing/dating is decided. -->

# Stage 3, CI/CD: Per-Connection Smoke Test, Pre-Deploy Backup, Terraform Drift Check

**Date:** 2026-07-26
**Repo the actual code/infra changes live in:** `Animal-Shelter-Workshop`
(this write-up lives in the homelab meta-repo instead, alongside the devops
practice plan it's a stage of, see `devops-practice-plan.md`, Stage 3's
checklist)

## Why I built this

Stages 1 and 2 (same session) made Terraform and Ansible both real and
proven. `tests.yml`/`deploy.yml` already did more than Stage 3's original
scope asked for, path-based routing, Vault-at-runtime secrets, real smoke
tests, basic rollback, so what was left were three specific, named gaps:
`deploy-db` had no recovery path at all, Terraform drift was invisible
outside a local machine, and the smoke test could hide a partial DB outage
behind an aggregate pass. A fourth item (feeding deploy metrics into
observability) is blocked on Stage 6 and stays open.

## Flow

```
┌────────────────────────────────────┐
│         STAGE 3, CI/CD            │▏
└────────────────────────────────────┘▔▔

┌────────────────────────────────┐     done, db:refresh-status
│ 1. Per-connection smoke test     │▏    --fail-on-down, agent-verify.hcl
│    (fail loud, not aggregate)   │▏     updated, deploy.yml asserts exit code
└────────────────────────────────┘▔▔
              │
              ▼
┌────────────────────────────────┐     done, reuses existing php artisan
│ 2. Pre-deploy database backup    │▏    db:backup (not raw mysqldump/
│    before deploy-db runs        │▏     pg_dump, already tried, retired)
└────────────────────────────────┘▔▔
              │
              ▼
┌────────────────────────────────┐     done, new Vault path/policy/token,
│ 3. Terraform drift-check job     │▏    Terraform on linux-gh-runner,
│    (scheduled + manual)          │▏     scheduled workflow, plan-only
└────────────────────────────────┘▔▔
              │
              ▼
┌────────────────────────────────┐     found + fixed while wiring in #1/#2,
│ 4. Routing regex gap (bonus)     │▏    roles/ changes matched neither
│    roles/ never matched          │▏     regex since Stage 2's refactor
└────────────────────────────────┘▔▔
```

## What I built

### 1. Per-connection smoke test

`db:refresh-status` (`app/Console/Commands/RefreshDatabaseStatus.php`) gained
a `--fail-on-down` option: when passed, it prints one `DOWN: <connection>
(<module>)` line per offline connection and returns `Command::FAILURE`. The
plain, flag-less invocation the Laravel scheduler uses is completely
untouched, it must always return success, since it's a status-reporting
command, not a health gate (this is the exact behavior that caught a real
Vault Agent scheduler regression before).

`roles/vault_agent`'s `agent-verify.hcl` config (rendered for CD's
post-deploy health check) is the one place that opts into the new flag:
`migrate:status && db:refresh-status --fail-on-down && about
--only=environment`. A single connection going down now stops that `&&`
chain and makes the whole `vault agent` process exit non-zero.
`deploy.yml`'s two health-check steps (the main one in `deploy-app`, and the
one that re-verifies after `rollback`) now capture that exit code explicitly
and fail the step on it, instead of only ever trusting the `5/5 online`
substring, which stays as a second, independent signal.

Added 3 Pest tests (`tests/Unit/Console/Commands/RefreshDatabaseStatusTest.php`)
covering: plain invocation still exits 0 with a connection down (scheduler
behavior preserved), `--fail-on-down` exits 1 and prints the `DOWN:` line,
and `--fail-on-down` exits 0 when everything's healthy. Full local backend
suite (373 tests) run before pushing, all green.

### 2. Pre-deploy database backup

`deploy-db` previously had no rollback *by design* (no sane automatic
reversal of an `apt install` or a UFW change), which the plan explicitly
calls out as correct, but it also had no fresh recovery point before
touching the 5 live DB hosts, relying entirely on whatever the nightly
02:00 `php artisan db:backup` scheduled run happened to leave, up to 24h
stale.

Rather than reinvent per-host `mysqldump`/`pg_dump`, this repo already
tried that (per-host, per-server backup timers) and deliberately retired it
in favor of one coordinated, checksummed, integrity-audited, Azure-synced
`db:backup` command (`docs/10-backups.md`), the fix reuses that exact
command. A new one-shot Vault Agent config, `agent-backup.hcl`
(`roles/vault_agent`), runs `php artisan db:backup` on app-server with real
Vault-sourced secrets, and `deploy.yml`'s `deploy-db` job now runs it as its
very first step, before `site.yml --limit databases` ever touches a DB
host. If the backup itself fails (a connection already down, or a dump
erroring), the step fails loud and the DB hosts are never provisioned,
matching the existing "fails loud, never silently proceeds" philosophy for
this job.

Verified live: manually invoked `vault agent -config=/etc/vault-agent/agent-backup.hcl`
on app-server, real dump of all 5 databases, integrity audit, Azure sync,
completed successfully in ~25 seconds.

### 3. Terraform drift-check job

New `.github/workflows/terraform-drift.yml`: `terraform plan` on a daily
schedule (03:00 UTC) plus manual `workflow_dispatch`, posting the result to
the run's job summary. It never applies, auto-`apply` can create/destroy
real VMs/CTs and was judged too destructive to automate unattended; this
job exists purely so drift doesn't sit invisible until someone remembers to
run `plan` locally.

Running `terraform plan` in CI needs the Proxmox hypervisor's own root SSH
password, API token, and the Tailscale/MinIO credentials, all previously
local-machine-only, in a gitignored `terraform.tfvars`. Rather than folding
these into `secret/asw-cd` (deploy.yml's existing Vault path for app-deploy
secrets), they got their own, deliberately separate home:

- New Vault path `secret/asw-terraform-cd`, holding every `terraform.tfvars`
  field plus the `terraform-asw` MinIO backend credentials.
- New read-only Vault policy `asw-terraform-cd`, scoped to that one path
  only. Verified directly: the resulting token can read
  `secret/asw-terraform-cd` and gets a clean 403 on both `secret/asw-cd` and
  `secret/animal-shelter-workshop`.
- A dedicated periodic token (`TF_VAULT_TOKEN`, 768h TTL), stored in
  `linux-gh-runner`'s `~/actions-runner/.env` alongside the existing
  `VAULT_TOKEN`, never merged with it, so a compromised app-deploy step
  can't reach hypervisor-root credentials and vice versa.
- A new `vault-tf-token-renew.timer`/`.service` pair (`playbooks/linux-gh-runner.yml`),
  mirroring the existing renewal timer but pointed at `TF_VAULT_TOKEN`
  specifically.
- Terraform itself installed on `linux-gh-runner` via the same HashiCorp
  apt repo already used for the `vault` client.

The workflow reads all fields as `TF_VAR_<name>` env vars (Terraform's own
override convention) plus `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` for
the MinIO backend, no `terraform.tfvars` file is ever written on the
runner. `terraform plan -detailed-exitcode` distinguishes "no drift" (0)
from "plan errored" (1) from "changes present" (2); only exit code 1 fails
the job, drift itself is reported, not treated as a CI failure.

Dry-ran the exact workflow logic by hand on `linux-gh-runner` before ever
touching CI (own git clone under `/tmp`, sourced `TF_VAULT_TOKEN`, ran
`init`/`plan`), matched the local Windows-machine test exactly: `Plan: 8 to
add, 0 to change, 0 to destroy` (the 4 test VMs from Stage 1's testing,
still declared in `vms.tf`'s locals map but torn down afterward, a
faithful "not yet applied" report, not spurious drift).

### 4. Bonus fix: `roles/` never matched `deploy.yml`'s routing regex

Found while wiring items 1 and 2 above into `roles/vault_agent`: Stage 2's
roles refactor moved what used to be inline `playbooks/tasks/`/template
content into `roles/{vault_agent,mysql_family,postgres_db,db_firewall,
legacy_backup_cleanup}/`, but `deploy.yml`'s two path-based routing regexes
were never updated to match `roles/`. Confirmed live: pushing Stage 2's
roles refactor (`3ff44aa`) triggered `Tests #35` → `Deploy #13`, both green,
but `Deploy #13` ran `deploy-app` with `--tags deploy` only, silently
skipping the provision-tagged Vault Agent role entirely. Manually running
`app-server.yml --tags provision` afterward showed `changed=2` (the two new
configs this session added), proving they'd never actually reached
production via CD despite two green pipeline runs.

Fixed by adding `roles/` to both `INFRA_APP`/`INFRA_DB` regexes, a
roles-only change now conservatively widens both (no cheap way to tell
which target a given role affects from its path alone), same "when in
doubt, do the full thing" reasoning `deploy.yml` already uses for a failed
`git diff`.

## Verification

- Per-connection smoke test: 3 new Pest tests, full 373-test backend suite,
  all green before pushing.
- Pre-deploy backup: `agent-backup.hcl` invoked directly on app-server,
  real 5-database dump, integrity audit, Azure sync, success.
- `roles/vault_agent` changes: `app-server.yml --tags provision --limit
  app-server` run twice against production, `changed=2` then `changed=0`,
  confirming both the change and its idempotency.
- Terraform drift job: dry-ran the exact `init`/`plan` sequence by hand on
  `linux-gh-runner` with the real `TF_VAULT_TOKEN`, matched the local
  Windows-machine result exactly (`8 to add, 0 to change, 0 to destroy`,
  exit code 2).
- New Vault token scope: confirmed it reads `secret/asw-terraform-cd` and
  gets 403 on `secret/asw-cd` and `secret/animal-shelter-workshop`.
- `vault-tf-token-renew.service` manually triggered once, renewed
  successfully, correct policy (`asw-terraform-cd`) and 768h duration
  confirmed in the output.
- `linux-gh-runner` playbook (adds Terraform + the new timer): run twice,
  `changed=4` then `changed=0`.
- Pushed as `8cfd3b4`, `Tests #36` passed, then `Deploy #14` ran against
  production and succeeded end to end: `plan`, `deploy-db` (including the
  new **Pre-deploy database backup** step, followed by **Provision the 5
  database servers**), and `deploy-app` (including the **Smoke test, app
  health** step, now running with `--fail-on-down`) all green;
  `rollback`/`no-rollback-target` correctly skipped since nothing failed.
  This is also live proof the routing fix (item 4 below) works: `deploy-db`
  correctly ran at all for a push whose Ansible-side changes lived entirely
  under `roles/`, `templates/`, and `playbooks/` paths already covered by
  `INFRA_APP`, the fix's real test is the *next* roles-only push after
  this one, but the fact this run's own routing decision matched
  expectations (both jobs ran) confirms nothing regressed.

![GitHub Actions "All workflows" list, Deploy #14 (this Stage 3 push) and Deploy #13 both green with a checkmark, Tests #36 for commit 8cfd3b4 (Stage 3) and Tests #35 for commit 3ff44aa (Stage 2's roles refactor, the push that exposed the routing gap) also green, and "Terraform Drift Check" now listed in the left-hand workflow sidebar alongside Deploy and Tests, confirming the new workflow registered on GitHub](images/stage3-deploy-success.png)

### How to independently verify each item

Run Ansible commands from WSL, inside `infrastructure/ansible/`, with
`ANSIBLE_CONFIG=./ansible.cfg`. `<become password>` and the `VAULT_*_ID`
pairs are the same ones already in `CLAUDE.md` (gitignored) / WSL's
`~/.bashrc`.

**1. Per-connection smoke test**
```bash
php artisan test --filter=RefreshDatabaseStatusTest
```
Expect 3 passing tests. To see it fail loud for real, temporarily point a
connection's host/port at something unreachable (see the test file's
`forceShelterUnreachableForRefresh()` for the exact pattern) and run:
```bash
php artisan db:refresh-status --fail-on-down
```
Expect a `DOWN: shelter (Shelter Management)` line and a non-zero exit code.

**2. Pre-deploy backup**
```bash
ssh linux-app-server "sudo -u taufiq vault agent -config=/etc/vault-agent/agent-backup.hcl"
```
Expect 5 "Dumping ..." lines, an integrity-audit line, an Azure sync
confirmation, and "Backup <run-id> completed successfully."

**3. Terraform drift check**
```bash
gh workflow run terraform-drift.yml --repo tttaufiqqq/Animal-Shelter-Workshop
gh run list --workflow=terraform-drift.yml --repo tttaufiqqq/Animal-Shelter-Workshop --limit 1
```
Open the run's summary, expect either "No drift detected" or a fenced
`terraform plan` block, never a red X (a red X means `terraform plan`
itself errored, which is the only case that fails the job).

**4. Routing fix**
```bash
grep -n "roles/" .github/workflows/deploy.yml
```
Expect `roles/` in both the `INFRA_APP` and `INFRA_DB` grep patterns.

### Screenshots

- **`images/stage3-deploy-success.png`**, added. Actions → "All workflows"
  list, captured right after `Deploy #14` (this stage's push, `8cfd3b4`)
  finished: both `Deploy #14` and the preceding `Deploy #13` show green
  checkmarks, `Tests #36` (`8cfd3b4`) and `Tests #35` (`3ff44aa`, Stage 2's
  roles refactor, the push that exposed the routing gap this stage fixed)
  are both green, and `Terraform Drift Check` is visible in the left-hand
  workflow sidebar alongside `Deploy` and `Tests`, confirming the new
  workflow file registered on GitHub as soon as it was pushed.
- **`images/stage3-drift-job-summary.png`**, still to add. After the drift
  workflow has run at least once (manual `workflow_dispatch` from the
  Actions tab is enough, no need to wait for 03:00 UTC): Actions tab →
  `Terraform Drift Check` → the run → screenshot its job summary panel
  (expect "No drift detected" or a fenced `terraform plan` block showing
  the `8 to add, 0 to change, 0 to destroy` result already confirmed by
  hand on `linux-gh-runner`).

## Where things live

| Piece | Path (in `Animal-Shelter-Workshop` unless noted) |
|---|---|
| `--fail-on-down` flag | `app/Console/Commands/RefreshDatabaseStatus.php` |
| New tests | `tests/Unit/Console/Commands/RefreshDatabaseStatusTest.php` |
| `agent-verify.hcl`/`agent-backup.hcl` configs | `infrastructure/ansible/roles/vault_agent/tasks/main.yml` |
| Health-check + pre-deploy-backup steps | `.github/workflows/deploy.yml` |
| Routing regex fix | `.github/workflows/deploy.yml` (`INFRA_APP`/`INFRA_DB`) |
| Terraform drift workflow | `.github/workflows/terraform-drift.yml` |
| Terraform + renewal timer on the runner | `infrastructure/ansible/playbooks/linux-gh-runner.yml` |
| New Vault path/policy/token | `secret/asw-terraform-cd` / `asw-terraform-cd` policy (Vault-side, not in git) |
| Design docs updated | `docs/07-terraform.md` (CI drift check section), `docs/12-cd.md` (backup + per-connection sections, routing table) |
| Gitignored ops notes | `CLAUDE.md` (`TF_VAULT_TOKEN` / `secret/asw-terraform-cd` section) |
| This write-up | `proxmox-homelab-taufiq/docs/19-devops-practice/04-ci-cd-per-connection-smoke-test-pre-deploy-backup-terraform-drift.md` (homelab meta-repo) |
