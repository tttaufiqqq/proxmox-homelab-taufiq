# k3s Multi-Node Expansion & Fully-Automated GitOps CI/CD Plan

A staged plan to expand `linux-k3s` from one node to two, put ArgoCD and
this node's cluster-management tooling on a dedicated control-plane node,
and close the last manual gap in the pipeline: today a code push still
needs a human to build/push a new image and bump `k8s/deployment.yaml`'s
tag by hand before ArgoCD has anything to sync. This plan makes that step
automatic, so a plain `git push` is genuinely the entire deploy trigger.

**Order, decided while planning this:**
`plans/05-k3s-asw-db-connectivity-plan.md` first (k3s has to reach the
real DBs before any of this matters), **then this plan**, **then**
`plans/07-k3s-production-cutover-plan.md` (cutting real traffic over is
safest once both the data layer and the automation/node layout are
already proven, not before). This plan absorbed what used to be Stage 2
(teach CI to deploy to k3s) and Stage 3 (move `cloudflared` into k3s) from
the cutover plan's earlier draft — they belong here, not there, since
they're about the pipeline/topology, not the go-live moment itself.

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
┌────────────────────────────────┐     node 1 (server) keeps ArgoCD +
│ 2. Split workload placement      │▏    Prometheus/Grafana/Loki; node 2
└────────────────────────────────┘▔▔    (agent) gets asw-app + cloudflared
              │
              ▼
┌────────────────────────────────┐     kill a pod on node 2, confirm
│ 3. Real cross-node failover test │▏    real rescheduling across two
└────────────────────────────────┘▔▔    distinct machines, not just YAML
              │
              ▼
┌────────────────────────────────┐     new CI job: build image, push
│ 4. CI builds + bumps the tag      │▏    tagged with the commit SHA,
└────────────────────────────────┘▔▔    commit the bump into k8s/
              │
              ▼
┌────────────────────────────────┐     optional: skip ArgoCD's ~3min
│ 5. Instant sync via webhook       │▏    poll, notify it the moment
└────────────────────────────────┘▔▔    the manifest commit lands
              │
              ▼
┌────────────────────────────────┐     cloudflared as its own Deployment
│ 6. cloudflared moves into k3s     │▏    inside the cluster, pointed at
└────────────────────────────────┘▔▔    asw-app's ClusterIP, own tunnel token
              │
              ▼
┌────────────────────────────────┐     git push → CI builds/bumps →
│ 7. Prove the full loop            │▏    ArgoCD syncs → new pod live,
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

**Stage 2 — the split, and why it's not just tidiness.** Node 1 (server)
keeps ArgoCD, Prometheus/Grafana/Loki/Alertmanager — cluster-management
tooling. Node 2 (agent) gets `asw-app` and (once Stage 6 lands)
`cloudflared` — the actual "serving the app" workloads. This isn't a
networking requirement (a `ClusterIP` Service is reachable from any node
via `kube-proxy` regardless of which node the pod lives on), it's resource
isolation: a crash-looping or CPU-heavy app pod on node 2 should never be
able to starve ArgoCD or the observability stack of the resources they
need to keep telling you what's wrong. Use a `nodeSelector` on the ArgoCD
and observability manifests to pin them to node 1 explicitly rather than
relying on the scheduler happening to spread them out.

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
New CI job: build (Stage 4's existing multi-stage `Dockerfile`), push to
`docker.io/tttaufiqqq/animal-shelter-workshop` tagged with the **commit
SHA** (not `latest` — ArgoCD needs an actual diff in git to have anything
to sync), then commit the tag bump back into `k8s/deployment.yaml`. Use
the default `GITHUB_TOKEN` with `permissions: contents: write` for that
commit — no new PAT needed unless branch protection on `main` blocks
direct pushes, in which case fall back to a scoped PAT.

**Stage 5 — instant vs. polled sync, optional.** ArgoCD's automated sync
polls git on an interval (~3 min default). A GitHub webhook pointed at
ArgoCD's API (`/api/webhook`) makes the sync fire the moment the tag-bump
commit lands instead of waiting out the poll — a nice-to-have for a snappy
pipeline, not required for correctness.

**Stage 6 — `cloudflared` inside the cluster, absorbed from the old cutover
draft.** Belongs here because it's a topology/placement decision (which
node hosts it, how it reaches `asw-app`), not something specific to the
go-live moment. Own Deployment, pointed at
`http://asw-app.default.svc.cluster.local:80` (no NodePort needed for an
in-cluster caller), tunnel token stored as a k8s Secret. Scheduled onto
node 2 alongside `asw-app` per Stage 2's split.

**Stage 7 — prove the whole loop end to end, once, for real.** A trivial
code change (e.g. a comment or a one-line template tweak), pushed to
`main`, with nothing run by hand afterward: tests → CI build/push/bump →
ArgoCD sync → new pod live. This is the actual deliverable — "fully
automated" isn't true until this has been watched happening once, not
assumed from the pieces existing.

---

## Verification

- Stage 1: `kubectl get nodes -o wide` shows 2 `Ready` nodes, one
  `control-plane`, one plain worker.
- Stage 2: `kubectl get pods -A -o wide` shows ArgoCD/observability pods
  on node 1 only, `asw-app` pods on node 2 only.
- Stage 3: `kubectl delete pod <asw-app-pod-on-node-2>`, confirm a
  replacement appears (same node if healthy, elsewhere if not) within
  seconds, no manual intervention.
- Stage 4: a throwaway commit produces a new image tag in Docker Hub
  *and* a matching commit bumping `k8s/deployment.yaml`, both without any
  manual `docker`/`kubectl` command.
- Stage 5 (if done): time from commit landing to ArgoCD's sync event —
  should drop from ~minutes (polling) to seconds (webhook).
- Stage 6: `kubectl get pods -n <cloudflared-namespace> -o wide` shows it
  `Running` on node 2; the public domain resolves through it with
  `app-server`'s own `cloudflared.service` stopped.
- Stage 7: full loop timed and documented once, start (`git push`) to
  finish (new pod `Running`), zero manual steps in between.
