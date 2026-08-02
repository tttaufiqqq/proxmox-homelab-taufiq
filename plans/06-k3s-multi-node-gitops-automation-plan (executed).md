# k3s Multi-Node Expansion & Fully-Automated GitOps CI/CD Plan

A staged plan to expand `linux-k3s` from one node to two, split `asw-app`'s
own two containers (`app`/php-fpm, `nginx`) across both nodes as separate
Deployments to prove a real cross-node workload split, and close the last
manual gap in the pipeline: today a code push still needs a human to
build/push a new image and bump `k8s/deployment.yaml`'s tag by hand before
ArgoCD has anything to sync. This plan makes that step automatic, so a
plain `git push` is genuinely the entire deploy trigger. Where ArgoCD and
the observability stack land node-wise is **not** decided here — that's
`plans/07-k3s-production-cutover-plan.md`'s call, made with real
production-cutover context.

**Order, decided while planning this:**
`plans/05-k3s-asw-db-connectivity-plan.md` first (k3s has to reach the
real DBs before any of this matters), **then this plan**, **then**
`plans/07-k3s-production-cutover-plan.md` (cutting real traffic over is
safest once both the data layer and the automation/node layout are
already proven, not before). This plan absorbed what used to be Stage 2
(teach CI to deploy to k3s) and Stage 3 (move `cloudflared` into k3s) from
the cutover plan's earlier draft — they belong here, not there, since
they're about the pipeline/topology, not the go-live moment itself.
Instant ArgoCD sync via webhook (originally sketched as this plan's own
Stage 5) was pulled back out into its own `plans/08-argocd-instant-sync-webhook-plan.md`
once this plan's other stages were already done — a nice-to-have polish
item, not something that needed to block finishing the rest of this plan.

**Result: executed, 2026-08-02.** All 6 stages done and verified live —
2-node cluster, `asw-app`/`asw-nginx` split across both nodes, a real
cross-node failover test, full CI→ArgoCD image-build-and-bump automation,
`cloudflared` migrated into the cluster on its own tunnel, and the whole
loop timed end to end (23m07s, zero manual steps). `app-server`'s power-off
— originally scoped to `plans/07-k3s-production-cutover-plan.md` — was
pulled forward into this session at the user's explicit request once
Stage 5's cloudflared cutover made it genuinely safe: `deploy.yml`'s
`deploy-app`/`rollback`/`no-rollback-target` jobs (which still deployed to
and smoke-tested `app-server` directly) were removed first, then
`app-server` (VM 101) was shut down — confirmed the public domain still
returns `200` with it off. Full narrative, what broke, and screenshots:
`docs/19-devops-practice/04-k3s-single-node-deployment-and-vault-injector.md`'s
"Continued" section. Two things found mid-execution and deliberately left
as tracked follow-ups rather than fixed inline: the pre-deploy DB backup
step lost its home (was tied to `app-server`'s own filesystem) and needs
re-homing; `Animal-Shelter-Workshop`'s separate `terraform-asw` MinIO
credential (unrelated Terraform state, not this plan's `terraform-homelab`
one) started failing its scheduled drift check independently.

This plan touches the sibling repo `Animal-Shelter-Workshop`
(`.github/workflows/deploy.yml`, `k8s/*.yaml`) and Proxmox/`linux-k3s`
directly (new CT, `k3s agent` join) — not this repo's code.

---

## Flow

```
┌────────────────────────────────────┐
│  K3S 2-NODE + FULL GITOPS AUTOMATION│▏
└────────────────────────────────────┘▔▔

┌────────────────────────────────┐     new CT, 1 core/1.5-2GB, joins as
│ 1. New CT, join as k3s agent     │▏    a k3s `agent` (worker only,
└────────────────────────────────┘▔▔    no control-plane role)
              │
              ▼
┌────────────────────────────────┐     split asw-app's own 2 containers
│ 2. Split asw-app across nodes    │▏    (app/php-fpm, nginx) into 2
└────────────────────────────────┘▔▔    Deployments, one node each
              │
              ▼
┌────────────────────────────────┐     kill a pod on node 2, confirm
│ 3. Real cross-node failover test │▏    real rescheduling across two
└────────────────────────────────┘▔▔    distinct machines, not just YAML
              │
              ▼
┌────────────────────────────────┐     new CI job: build BOTH images
│ 4. CI builds + bumps the tags     │▏    (app, nginx), push tagged with
└────────────────────────────────┘▔▔    commit SHA, commit bumps into k8s/
              │
              ▼
┌────────────────────────────────┐     cloudflared as its own Deployment
│ 5. cloudflared moves into k3s     │▏    inside the cluster, pointed at
└────────────────────────────────┘▔▔    asw-nginx's ClusterIP, own tunnel token
              │
              ▼
┌────────────────────────────────┐     git push → CI builds/bumps →
│ 6. Prove the full loop            │▏    ArgoCD syncs → new pod live,
└────────────────────────────────┘▔▔    zero manual kubectl/docker steps
```

---

## Why each stage is there

**Stage 1 — new CT, agent role, not another server.** A second k3s
`server` would mean running a second copy of the control plane/datastore
for no benefit at this scale (k3s's HA etcd mode needs an odd number ≥3
servers to make quorum meaningful anyway — see the "adding a second node"
discussion this plan grew out of). One `agent` node is the right shape:
pure extra workload capacity. Same "start small" sizing already used for
`linux-k3s` itself (1 core, 1.5-2GB), same capacity-check-first discipline
as every other CT in this homelab.

**Stage 2 — the split, and why it's not just tidiness.** `ArgoCD`'s and
the observability stack's node placement is **not decided here** — that
call moves to `plans/07-k3s-production-cutover-plan.md`, made with actual
production-cutover context instead of guessed at early. What *is* decided
here: `asw-app` today runs `app` (php-fpm) and `nginx` as two containers
sidecar-style in one Pod (`k8s/deployment.yaml`), sharing an `emptyDir` so
nginx can serve the static assets an initContainer copies in. That
same-Pod sharing is exactly what a real 2-node split has to break — so
this stage splits them into two separate Deployments, one per node,
talking over the network like any other two services would:

- `asw-app` (php-fpm) → node 1, its own **new** ClusterIP Service
  `asw-app-internal` on port 9000 (a new name, not a reuse of the old
  `asw-app` NodePort Service — reusing it would mean an in-place
  NodePort→ClusterIP type change, which `kubectl apply`/ArgoCD can't do
  cleanly; a fresh name lets ArgoCD prune the old one and create both new
  Services instead).
- `asw-nginx` → node 2, alongside `cloudflared` once Stage 5 lands. Takes
  over the public-facing NodePort role the old combined Service had,
  under its own name (`asw-nginx`, NodePort 30080). Its `fastcgi_pass` in
  `k8s/nginx-configmap.yaml` changes from `127.0.0.1:9000` (same-Pod
  shortcut) to `asw-app-internal.default.svc.cluster.local:9000`.
- The static-asset problem (nginx needs the Laravel-built `public/` dir,
  previously copied in by init­Container + shared `emptyDir`) is solved by
  **baking the assets into nginx's own image at build time** instead —
  Stage 4's CI job builds a second image (`asw-nginx`) with a build stage
  that `COPY`s `public/` straight in. No shared volume, no NFS/S3 mount,
  fully self-contained; a tag bump on either image is a normal GitOps diff.
- Use a `nodeSelector` on each Deployment to pin it to its node explicitly
  rather than relying on the scheduler happening to spread them out — the
  whole point is proving a *real* cross-node split (Stage 3), not one the
  scheduler could collapse back onto a single node.

Target architecture this stage builds toward:

```
┌──────────────────────────────────────────────────────┐
│  Proxmox host                                         │▏
│                                                         │▏
│  ┌───────────────────────┐  ┌───────────────────────┐ │▏
│  │  k3s NODE 1 (server)   │  │  k3s NODE 2 (agent)    │ │▏
│  │  control-plane          │  │  worker only            │ │▏
│  │                          │  │                          │ │▏
│  │  ┌──────────┐          │  │  ┌──────────┐          │ │▏
│  │  │ asw-app    │◄─────────┼──┼──┤ asw-nginx │          │ │▏
│  │  │ (php-fpm)  │  :9000   │  │  └──────────┘          │ │▏
│  │  └──────────┘          │  │  ┌──────────┐          │ │▏
│  │                          │  │  │cloudflared│          │ │▏
│  │  (ArgoCD/observability   │  │  └──────────┘          │ │▏
│  │   node placement: TBD,   │  │                          │ │▏
│  │   see plan 07)           │  │                          │ │▏
│  └───────────────────────┘  └───────────────────────┘ │▏
└──────────────────────────────────────────────────────┘▔▔
```

Today, before this plan, both boxes collapse into one — everything
(ArgoCD, Prometheus/Grafana/Loki, `asw-app`'s app+nginx sidecar pair)
already runs on the single existing CT (`linux-k3s`). This stage is what
actually splits `asw-app` itself into the two-box picture above; ArgoCD
and observability stay wherever they already are until plan 07 decides.

**Stage 3 — prove real HA, not simulated HA.** Stage 5 of the original
devops-practice-plan already practiced taints/tolerations and draining,
but explicitly *on one node* (multi-node expansion was deferred, tracked
in that plan). With a real second node, killing a pod that's actually
running on node 2 and watching it reschedule (potentially onto node 1, if
node 2 is unreachable) is the real version of what was only simulated
before.

**Stage 4 — the actual automation gap.** Confirmed while sketching plan
07: `deploy.yml` today only runs Ansible against `app-server`; nothing
rebuilds the app image or touches `k8s/deployment.yaml` on a normal push.
New CI job builds **two** images now, not one — Stage 2's split means
`asw-app` and `asw-nginx` are separate Deployments with separate images:
- `asw-app`: same existing multi-stage `Dockerfile`, pushed to
  `docker.io/tttaufiqqq/animal-shelter-workshop` tagged with the **commit
  SHA** (not `latest` — ArgoCD needs an actual diff in git to have
  anything to sync).
- `asw-nginx`: new build stage/Dockerfile that starts from `nginx:alpine`
  and `COPY`s in the same commit's built `public/` assets (Stage 2's
  bake-in-the-image approach), pushed to
  `docker.io/tttaufiqqq/animal-shelter-workshop-nginx`, same commit-SHA
  tagging.

Then commit both tag bumps back into `k8s/deployment.yaml` and the new
`k8s/nginx-deployment.yaml` in one commit. Use the default `GITHUB_TOKEN`
with `permissions: contents: write` for that commit — no new PAT needed
unless branch protection on `main` blocks direct pushes, in which case
fall back to a scoped PAT.

**Stage 5 — `cloudflared` inside the cluster, absorbed from the old cutover
draft.** Belongs here because it's a topology/placement decision (which
node hosts it, how it reaches `asw-app`), not something specific to the
go-live moment. Own Deployment, pointed at
`http://asw-nginx.default.svc.cluster.local:80` — after Stage 2's split,
`nginx` is the actual HTTP front door (php-fpm never served port 80
directly), so this is the correct target, not `asw-app` (no NodePort
needed for an in-cluster caller). Tunnel token stored as a k8s Secret.
Scheduled onto node 2 alongside `asw-nginx` per Stage 2's split.

The gap this closes:

```
┌────────────────────────────────────┐
│         TODAY                      │▏
└────────────────────────────────────┘▔▔

  animal-shelter-workshop.tttaufiqqq.com
              │  (Cloudflare edge, outbound-only tunnel)
              ▼
┌─────────────────────────┐
│   app-server (VM 101)    │▏   cloudflared.service (systemd)
│   cloudflared → :80      │▏   → local nginx on same VM
└─────────────────────────┘▔▔

  k3s, meanwhile: asw-nginx's Service is only a NodePort —
  reachable inside the tailnet, no path from the public internet at all

┌────────────────────────────────────┐
│      AFTER THIS STAGE               │▏
└────────────────────────────────────┘▔▔

  animal-shelter-workshop.tttaufiqqq.com
              │  (same tunnel mechanism, new host)
              ▼
┌─────────────────────────┐
│  cloudflared Deployment   │▏   runs INSIDE k3s (node 2),
│  → asw-nginx ClusterIP    │▏   no NodePort needed at all
└─────────────────────────┘▔▔
```

`app-server`'s own `cloudflared.service` gets stopped once this is live —
this is precisely what makes `app-server` safe to power off in plan 07,
since nothing left running still depends on it.

**Stage 6 — prove the whole loop end to end, once, for real.** A trivial
code change (e.g. a comment or a one-line template tweak), pushed to
`main`, with nothing run by hand afterward: tests → CI build/push/bump →
ArgoCD sync → new pod live. This is the actual deliverable — "fully
automated" isn't true until this has been watched happening once, not
assumed from the pieces existing.

---

## The fully-automated CI/CD pipeline, in detail (Stage 4)

What "fully automated" actually means here: nothing between `git push` and
a new pod running should require a human to run `docker` or `kubectl` by
hand. ArgoCD's own polled sync (~3 min default) is the only sync path this
plan builds — an optional instant-sync-via-webhook upgrade is tracked
separately in `plans/08-argocd-instant-sync-webhook-plan.md`, not required
for this loop to already be genuinely closed:

```
┌────────────────────────────────────┐
│  git push (app code, main branch)  │▏
└────────────────────────────────────┘▔▔
              │
              ▼
┌────────────────────────────────┐     already exists — tests.yml
│  tests.yml                       │▏    must pass before anything
└────────────────────────────────┘▔▔    below is allowed to run
              │  success
              ▼
┌────────────────────────────────┐     NEW — Stage 4
│  CI: build BOTH images           │▏    app (existing Dockerfile) +
│  (Animal-Shelter-Workshop repo)  │▏    nginx (public/ COPY'd in fresh)
└────────────────────────────────┘▔▔
              │
              ▼
┌────────────────────────────────┐     both tagged with the COMMIT SHA,
│  docker push x2                  │▏    never `latest` — ArgoCD needs
│  → .../asw, .../asw-nginx         │▏    an actual new tag to see a diff
└────────────────────────────────┘▔▔
              │
              ▼
┌────────────────────────────────┐     sed/yq bump of `image:` in both
│  commit + push back to main       │▏    k8s/deployment.yaml AND
│  (bumps both k8s/*.yaml files)    │▏    nginx-deployment.yaml, one commit
└────────────────────────────────┘▔▔
              │
              ▼
              ┌────────────────────────────────┐
              │  ArgoCD polls git                │▏   git's image tag ≠
              │  (~3 min interval)                │▏   what's live in k3s
              └────────────────────────────────┘▔▔
                              │
                              ▼
              ┌────────────────────────────────┐     applied via ArgoCD's
              │  ArgoCD applies the new manifest  │▏   in-cluster API access
              └────────────────────────────────┘▔▔    (Application controller
                              │                        runs as a pod on node 1)
                              ▼
              ┌────────────────────────────────┐     new asw-app/asw-nginx
              │  k3s schedules the new pod(s)     │▏   pods come up on their
              │  (rolling update, old pod drains) │▏   own pinned nodes (Stage 2)
              └────────────────────────────────┘▔▔
                              │
                              ▼
              ┌────────────────────────────────┐     the actual proof —
              │  DONE — zero manual steps         │▏   Stage 6's verification
              └────────────────────────────────┘▔▔
```

The two things that make this loop closed rather than "mostly automatic":
tagging with the commit SHA (so there's always a real diff for ArgoCD to
find) and the CI job's own write-back permission (so the tag bump lands in
git without a human touching `k8s/deployment.yaml`). Miss either one and
the pipeline silently stalls at "image pushed, nothing deployed."

---

## Verification

- Stage 1: `kubectl get nodes -o wide` shows 2 `Ready` nodes, one
  `control-plane`, one plain worker.
- Stage 2: `kubectl get pods -o wide` shows `asw-app` (php-fpm) pods on
  node 1 only, `asw-nginx` pods on node 2 only; a request through
  `asw-nginx`'s Service still round-trips correctly to `asw-app` over the
  network (proves the `fastcgi_pass` change and the baked-in static
  assets both actually work cross-node, not just that the pods exist).
- Stage 3: `kubectl delete pod <pod-on-node-2>` (an `asw-nginx` or
  `cloudflared` pod), confirm a replacement appears (same node if
  healthy, elsewhere if not) within seconds, no manual intervention.
- Stage 4: a throwaway commit produces two new image tags in Docker Hub
  (`asw`, `asw-nginx`) *and* a matching commit bumping both
  `k8s/deployment.yaml` and `k8s/nginx-deployment.yaml`, all without any
  manual `docker`/`kubectl` command.
- Stage 5: `kubectl get pods -n <cloudflared-namespace> -o wide` shows it
  `Running` on node 2; the public domain resolves through it with
  `app-server`'s own `cloudflared.service` stopped.
- Stage 6: full loop timed and documented once, start (`git push`) to
  finish (new pod `Running`), zero manual steps in between.
