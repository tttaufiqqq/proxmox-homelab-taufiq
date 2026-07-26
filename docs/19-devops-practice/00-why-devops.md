# Why This Series Exists

I was drawn to devops, and I want to break into it. Not just read about
Terraform and Kubernetes, but actually run them against something real
until they break and I have to fix them.

[Animal Shelter Workshop](https://github.com/tttaufiqqq/Animal-Shelter-Workshop)
had the potential to be exactly that something real. It's a genuinely big
project, five modules covering a full shelter's workflow (stray reporting,
rescue and caretaker check-in, vet and vaccination records, admin and
adoption revenue reporting, and adopter booking), each with its own
database connection across three engines, a real deployment pipeline, and
a real Proxmox homelab underneath it, already more infrastructure than
most tutorials ever touch. That size is exactly what made it useful here:
five separate modules and five separate database connections meant there
was always another piece of it that could be stretched to fit whatever the
next devops stage needed, without running out of real surface area to
practice on. So I picked it as the target, and planned a devops learning
path around it (Terraform, Ansible, CI/CD, Docker, k3s, observability,
GitOps, and a public cloud stretch goal) with Claude's help, working
through it stage by stage.

The plan itself lives in `plans/devops-practice-plan.md`. This series is
the writeup of actually doing it, stage by stage, in plan order, each doc
written the same way every other doc in this repo is: what I built, why,
what broke, how I found it, how I recovered. Some of it went in a
different order than the plan originally laid out (the cloud stage, in
particular, got pulled forward, gated by an Azure for Students credit with
a real expiry date, not by curriculum order). The docs here are sequenced
to match the plan's own structure regardless, not the order things actually
happened in.

## What's in this series

| # | Doc | Stage |
|---|---|---|
| 01 | Terraform: proving the base loop | Stage 1 |
| 02 | Terraform: state backend, container import, module | Stage 1 (continued) |
| 03 | Ansible: roles, idempotency, Molecule, fleet expansion | Stage 2 |
| 04 | CI/CD: per-connection smoke test, pre-deploy backup, drift check | Stage 3 |
| 05 | Docker: multi-stage build and compose | Stage 4 |
| 06 | k3s: single-node deployment and Vault injector | Stage 5 |
| 07 | Observability: Prometheus, Grafana, Loki, Alertmanager | Stage 6 |
| 08 | GitOps: ArgoCD auto-sync and drift-revert | Stage 7 |
| 09 | Azure: offsite backup sync and budget guardrail | Stage 8, Steps 1-2 |
| 10 | Azure: Functions reading Vault through Tailscale Funnel | Stage 8, Step 3 |
| 11 | Azure: Terraform talking to a second provider | Stage 8, Step 4 (stretch) |
