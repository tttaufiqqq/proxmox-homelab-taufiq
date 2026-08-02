# ArgoCD Instant Sync via GitHub Webhook Plan

A small, standalone polish item: today ArgoCD's automated sync polls
`Animal-Shelter-Workshop`'s `k8s/` path on a ~3 minute interval. A GitHub
webhook pointed at ArgoCD's own `/api/webhook` endpoint makes the sync
fire the moment a manifest-changing commit lands instead of waiting out
the poll. Purely a snappier-pipeline nice-to-have, not required for
correctness — `plans/06-k3s-multi-node-gitops-automation-plan.md`'s CI→
ArgoCD loop is already genuinely closed on the default polled sync alone.

**Where this came from:** originally sketched as plan 06's own Stage 5,
pulled out into its own plan once the rest of plan 06 was already done and
verified — no reason a nice-to-have should hold up finishing the plan it
was attached to.

**Order:** no hard dependency on plan 07 (production cutover) — can be
done before or after it, whenever convenient. Only real prerequisite is
plan 06 (the CI→ArgoCD polled loop has to exist first, so there's
something for the webhook to make instant).

This plan touches ArgoCD's config on `linux-k3s` and GitHub's webhook
settings for `Animal-Shelter-Workshop` — not this repo's code, not
`Animal-Shelter-Workshop`'s code either.

---

## What this involves

- A GitHub webhook on `Animal-Shelter-Workshop`, pointed at ArgoCD's
  `/api/webhook` endpoint, firing on `push` events.
- ArgoCD's API needs to be reachable from GitHub's webhook delivery
  infrastructure — today it's only reachable over the tailnet
  (`100.109.241.125`), not the public internet, so this plan's real work
  is deciding *how* that endpoint gets exposed (a Cloudflare Tunnel route
  alongside `asw-nginx`'s, similar to plan 06 Stage 5's pattern, is the
  most likely shape — avoids opening a new public port for something
  this narrow).
- A shared secret configured on both the GitHub webhook and ArgoCD's
  `argocd-secret`, so ArgoCD only accepts webhook payloads that are
  actually from GitHub, not an arbitrary POST to a guessable URL.

## Verification

- Time from a manifest-changing commit landing on `main` to ArgoCD's
  sync event firing: should drop from ~minutes (polling) to seconds
  (webhook).
- Confirm the polled sync still works as the fallback if the webhook
  delivery ever fails (ArgoCD's automated sync policy keeps polling
  regardless of whether a webhook is also configured) — this stays a
  strict improvement, not a replacement with a new single point of
  failure.
