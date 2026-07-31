# Why This Series Exists

- I was drawn to devops, and I want to break into it.
- Not just read about Terraform and Kubernetes, but actually run them
  against something real until they break and I have to fix them.

- [Animal Shelter Workshop](https://github.com/tttaufiqqq/Animal-Shelter-Workshop)
  had the potential to be exactly that something real.
- It's a genuinely big project: five modules covering a full shelter's
  workflow (stray reporting, rescue and caretaker check-in, vet and
  vaccination records, admin and adoption revenue reporting, and adopter
  booking), each with its own database connection across three engines, a
  real deployment pipeline, and a real Proxmox homelab underneath it,
  already more infrastructure than most tutorials ever touch.
- That size is exactly what made it useful here: five separate modules and
  five separate database connections meant there was always another piece
  of it that could be stretched to fit whatever the next devops stage
  needed, without running out of real surface area to practice on.
- So I picked it as the target, and planned a devops learning path around
  it (Terraform, Ansible, CI/CD, Docker, k3s, observability, GitOps, and a
  public cloud stretch goal) with Claude's help, working through it stage
  by stage.

- The plan itself lives in `plans/02-devops-practice-plan (executed).md`.
- This series is the writeup of actually doing it, stage by stage, in plan
  order, each doc written the same way every other doc in this repo is:
  what I built, why, what broke, how I found it, how I recovered.
- Some of it went in a different order than the plan originally laid out
  (the cloud stage, in particular, got pulled forward, gated by an Azure
  for Students credit with a real expiry date, not by curriculum order).
- The docs here are sequenced to match the plan's own structure regardless,
  not the order things actually happened in.

## What's in this series

Doc `01` covers the whole Terraform/IaC journey (Stage 1, in all its
iterations) — what was built, why, what broke, how it was found, and how
it was recovered, all in one place. Read that one first. Its full
narrative detail, stage by stage, previously lived across four separate
docs that are now folded into it rather than kept as separate reading.

| # | Doc | Stage |
|---|---|---|
| 01 | [Terraform: VM/CT creation, fleet import, and pipeline automation](01-terraform-vm-ct-creation-fleet-import-and-automation.md) | Stage 1, all iterations |
| 02 | [Ansible: roles, idempotency, Molecule, fleet expansion](02-ansible-roles-idempotency-molecule-vault-and-fleet-expansion.md) | Stage 2 |
| 03 | [CI/CD: per-connection smoke test, pre-deploy backup, drift check](03-ci-cd-per-connection-smoke-test-pre-deploy-backup-terraform-drift.md) | Stage 3 |
| 04 | [Docker: multi-stage build and compose](04-docker-multi-stage-build-and-compose.md) | Stage 4 |
| 05 | [k3s: single-node deployment and Vault injector](05-k3s-single-node-deployment-and-vault-injector.md) | Stage 5 |
| 06 | [Observability: Prometheus, Grafana, Loki, Alertmanager](06-observability-prometheus-grafana-loki-alertmanager.md) | Stage 6 |
| 07 | [GitOps: ArgoCD auto-sync and drift-revert](07-gitops-argocd-auto-sync-and-drift-revert.md) | Stage 7 |
| 08 | [Azure: offsite backup sync and budget guardrail](08-azure-cloud-backup-sync.md) | Stage 8, Steps 1-2 |
| 09 | [Azure: Functions reading Vault through Tailscale Funnel](09-azure-functions-vault-tailscale-funnel.md) | Stage 8, Step 3 |
| 10 | [Azure: Terraform talking to a second provider](10-terraform-azurerm-stretch-goal.md) | Stage 8, Step 4 (stretch) |
| 11 | [Terraform: bringing the rest of the fleet in](11-terraform-full-fleet-import.md) | Stage 1 (continued again) — full narrative detail behind doc 01 |
| 12 | [Terraform: proving CT creation, and the full loop end to end](12-terraform-ct-creation-and-full-loop-proof.md) | Stage 1 (continued once more) — full narrative detail behind doc 01 |
