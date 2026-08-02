# ArgoCD Instant Sync via GitHub Webhook

**Date:** 2026-08-02

## Why I built this

- Doc 07 wired ArgoCD to poll `Animal-Shelter-Workshop`'s `k8s/` path on
  its default ~3 minute interval — genuinely closed the CI→ArgoCD loop
  already, but every push still sat waiting out the poll before ArgoCD
  even noticed.
- `plans/08-argocd-instant-sync-webhook-plan.md` was pulled out of plan
  06 as its own standalone polish item once plan 06 itself was done — a
  nice-to-have shouldn't hold up finishing the plan it was attached to.
- Purely a snappier-pipeline improvement, not a correctness fix: the
  polled sync stays configured underneath as the fallback regardless.

## What I built

```
┌────────────────────────────────────┐
│  PLAN 08, ARGOCD INSTANT SYNC      │▏
└────────────────────────────────────┘▔▔

┌────────────────────────────────┐     done, random 40-char hex secret,
│ 1. Shared secret in argocd-secret│▏    patched live into the argocd
└────────────────────────────────┘▔▔    namespace, no restart needed
              │
              ▼
┌────────────────────────────────┐     done, new Cloudflare Tunnel
│ 2. Public route to argocd-server │▏    public hostname, same
└────────────────────────────────┘▔▔    k3s-asw-nginx tunnel as asw-nginx
              │
              ▼
┌────────────────────────────────┐     done, gh api, push event,
│ 3. GitHub webhook on the repo    │▏    same shared secret
└────────────────────────────────┘▔▔
              │
              ▼
┌────────────────────────────────┐     done, real push landed,
│ 4. Live end-to-end verification  │▏    ArgoCD's tracked revision
└────────────────────────────────┘▔▔    updated within ~9 seconds
```

### 1. Shared secret

- Generated with `openssl rand -hex 20`.
- Patched straight into the existing `argocd-secret` (namespace `argocd`)
  as `webhook.github.secret`:

```
kubectl -n argocd patch secret argocd-secret \
  -p '{"stringData":{"webhook.github.secret":"<generated hex>"}}'
```

- ArgoCD watches this secret live (informer, not a one-time read at
  startup) — no `argocd-server` restart needed, confirmed by the very
  next webhook delivery being accepted correctly.
- Without this, ArgoCD's `/api/webhook` endpoint would accept a POST from
  literally anyone who finds the URL; the secret is what makes it check
  the payload is actually signed by GitHub.

### 2. Public route through the existing Cloudflare Tunnel

- `argocd-server`'s `Service` was already `NodePort` from doc 07 (ports
  80/443 → container port 8080, self-signed cert), reachable in-cluster
  at `argocd-server.argocd.svc.cluster.local:443` regardless of which
  node ArgoCD's pods are actually pinned to (doc 13 pinned all 7 to
  `linux-k3s-3`) — Kubernetes `Service` networking routes correctly
  cluster-wide either way.
- Reused the same Cloudflare Tunnel as `asw-nginx` (`k3s-asw-nginx`,
  already running in-cluster per plan 06 Stage 5) rather than standing up
  a second tunnel — one more **Published application route** on the same
  tunnel, same pattern as everything else this homelab exposes publicly:

| Field | Value |
|---|---|
| Subdomain | `argocd-webhook` |
| Domain | `tttaufiqqq.com` |
| Path | *(blank — matches everything)* |
| Service type | `HTTPS` |
| Service URL | `argocd-server.argocd.svc.cluster.local:443` |
| No TLS Verify | **On** |

- **No TLS Verify** is required because ArgoCD's origin cert is
  self-signed (its SANs cover `argocd-server.argocd.svc.cluster.local`
  correctly, but the issuing CA isn't one `cloudflared` trusts by
  default) — without it the route 502'd even though DNS and the route
  itself were configured correctly.
- Confirms the same principle doc 07 already established for
  `asw-nginx`: exposing something publicly through this tunnel is just
  another hostname route, no new public port opened, no second tunnel to
  manage.

### 3. GitHub webhook

```
gh api repos/tttaufiqqq/Animal-Shelter-Workshop/hooks \
  -f name=web \
  -f "config[url]=https://argocd-webhook.tttaufiqqq.com/api/webhook" \
  -f "config[content_type]=json" \
  -f "config[secret]=<same generated hex>" \
  -F active=true \
  -f "events[]=push"
```

- `push` events only — ArgoCD's webhook handler only cares about the
  repo/branch/path already configured on the `Application` resource, it
  ignores everything else.
- GitHub's own `ping` delivery fired immediately on creation, `200 OK`.
- `argocd-server`'s own logs confirmed it parsed and validated the
  payload (`"msg":"Ignoring webhook event"` — the expected response to a
  `ping`, which doesn't match any tracked `Application`'s repo+revision):
  proof the shared secret matched on both ends, not just that the HTTP
  request landed.

### 4. Live end-to-end verification

- A real, deliberately no-op (comment-only) commit to
  `k8s/deployment.yaml`, pushed to `main` — same repo, same pipeline as
  every other push this project, confirmed with the user first since it
  still runs the real CI workflow.
- `ArgoCD`'s tracked `status.sync.revision` updated to match the new
  commit's full SHA within **~9 seconds** of the push landing, no manual
  `argocd.argoproj.io/refresh=hard` annotation needed (doc 07 section 3
  needed that manual nudge to see its own sync land quickly).
- No `OperationStarted`/`OperationCompleted` event pair fired for this
  particular commit — expected, since a YAML comment doesn't change the
  rendered manifest at all, so ArgoCD's diff found nothing to actually
  apply. The fast revision-tracking update is itself the proof the
  webhook triggered an immediate refresh; a manifest-changing commit
  would additionally show a real sync operation, same as doc 07's test.

## How to independently verify each item

| # | Command | Expected |
|---|---------|----------|
| 1 | `kubectl -n argocd get secret argocd-secret -o jsonpath='{.data.webhook\.github\.secret}' \| base64 -d` | the generated hex secret |
| 2 | `curl -sk -o /dev/null -w '%{http_code}\n' https://argocd-webhook.tttaufiqqq.com/api/webhook` | `400` (ArgoCD reachable, rejecting a bare GET — not `502`) |
| 3 | `gh api repos/tttaufiqqq/Animal-Shelter-Workshop/hooks` | one webhook, `config.url` = the tunnel hostname, `active: true` |
| 3 | `gh api repos/tttaufiqqq/Animal-Shelter-Workshop/hooks/<id>/deliveries` | most recent `ping` delivery, `status: OK`, `status_code: 200` |
| 4 | push a manifest-changing commit, then `kubectl -n argocd get application animal-shelter-workshop -o jsonpath='{.status.sync.revision}'` | matches the new commit's full SHA within seconds, not ~3 minutes |

## What still holds true from plan 08's own text

- The polled sync (`~3min` default) is untouched and still configured —
  this is a strict improvement, not a replacement with a new single point
  of failure. If webhook delivery ever fails (GitHub outage, tunnel
  down), ArgoCD still notices the drift on its own within the old
  timeframe.

## Worth flagging, not fixed this session

- The public route exposes ArgoCD's full API/UI (`argocd-webhook.
  tttaufiqqq.com`), not just `/api/webhook` specifically — Cloudflare
  Tunnel's path matching could narrow this to `^/api/webhook` only, which
  would be tighter. Left as full-service for now, consistent with this
  homelab's general practice-over-production-hardening stance (no real
  users or data at stake anywhere in this lab), but worth doing if this
  ever needs to look more production-representative.
- ArgoCD's admin UI is now reachable at the same hostname over the
  public internet, on top of already being reachable via
  `https://linux-k3s.taufiq.lab:30943` on the tailnet — same admin
  credential protects both.

## Where things live

- **The webhook shared secret:** `argocd-secret` (namespace `argocd`,
  `linux-k3s`), not committed anywhere — ArgoCD's own convention already
  established by doc 07 for `admin.password`/`server.secretkey`.
- **The Cloudflare Tunnel route:** `k3s-asw-nginx` tunnel, Cloudflare
  Zero Trust dashboard → **Tunnels & Mesh** → **Published application
  routes**, alongside the pre-existing `asw-nginx` route from doc 11 of
  the earlier series.
- **The GitHub webhook itself:** `Animal-Shelter-Workshop` repo settings
  → Webhooks, `id 660306987`, created via `gh api` rather than the
  GitHub UI.
