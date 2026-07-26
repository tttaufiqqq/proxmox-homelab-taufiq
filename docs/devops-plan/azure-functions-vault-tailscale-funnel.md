<!-- Not yet sequenced into a numbered docs/ folder — lives here in
     docs/devops-plan/ until the full devops-practice-plan.md is complete.
     Date below is provisional (the date this actually happened); revisit
     once final sequencing/dating is decided. -->

# Stage 8, Step 3 — Azure Functions Reading Vault Through Tailscale Funnel

**Date:** 2026-07-26/27
**Repo the actual code/infra changes live in:** mostly outside any git repo
— Azure resources, `linux-vault`'s own config, and a local-only function
project. This write-up lives in the homelab meta-repo alongside the devops
practice plan it's a stage of (`devops-practice-plan.md`, Stage 8, Step 3).

## Why I built this

The plan's Lambda-equivalent goal for Azure needed a real function calling
back into the lab, not just a "hello world" running in isolation. The
interesting problem wasn't the function itself — it was that Vault only
ever talks to things on my Tailscale network, and an Azure Function runs
inside Azure's own infrastructure, nowhere near my tailnet. Something had
to bridge that gap before I could write a single line of function code.

## Flow

```
┌────────────────────────────────────┐
│  STAGE 8.3 — AZURE FUNCTION + VAULT │▏
└────────────────────────────────────┘▔▔

┌────────────────────────────────┐     done — new AppRole scoped to one
│ 1. Dedicated demo secret + role  │▏    dedicated demo secret, never a
└────────────────────────────────┘▔▔    real DB/Cloudinary/mail field
              │
              ▼
┌────────────────────────────────┐     done — one-time tailnet approval,
│ 2. Tailscale Funnel on Vault      │▏    then `tailscale funnel --bg 8200`,
└────────────────────────────────┘▔▔    confirmed via /v1/sys/health
              │
              ▼
┌────────────────────────────────┐     done — Consumption plan, Node.js,
│ 3. Function App created          │▏    its own small storage account
└────────────────────────────────┘▔▔
              │
              ▼
┌────────────────────────────────┐     done — AppRole login → read the
│ 4. Function code written+tested  │▏    secret, tested locally first
└────────────────────────────────┘▔▔
              │
              ▼
┌────────────────────────────────┐     first deploy 503'd everywhere —
│ 5. Deployed, hit a real bug      │▏    Node 24 not fully supported by
└────────────────────────────────┘▔▔    the host runtime yet; Node 22 fixed it
              │
              ▼
┌────────────────────────────────┐     done — HTTP 200, real secret
│ 6. Verified live                 │▏    content, fetched fresh every call
└────────────────────────────────┘▔▔
```

## What I built

### 1. A dedicated demo secret, not a real credential

I deliberately scoped this as demo scaffolding, the same way Stage 5's Vault
Injector proof used a throwaway `secret/k3s-demo` rather than the app's real
DB passwords. On `linux-vault`, using its own root token:

```
vault kv put secret/azure-function-demo \
  message='Hello from Vault, fetched by an Azure Function over Tailscale Funnel' \
  proof_date='2026-07-26'
```

New read-only policy, scoped to exactly that one path:

```hcl
path "secret/data/azure-function-demo" {
  capabilities = ["read"]
}
```

New AppRole bound to it (`azure-function-demo`), 1h token TTL / 24h
`secret_id` TTL — short-lived on purpose, this is a proof, not a standing
integration.

### 2. Tailscale Funnel, not a new tunnel technology

I didn't want to introduce Cloudflare Tunnel or anything new just for this —
Tailscale is already installed on every host in this lab, and Funnel is
Tailscale's own feature for exposing a tailnet service to the public
internet, TLS-terminated at Tailscale's edge.

First attempt: `tailscale funnel --bg 8200` on `linux-vault` — refused,
*"Funnel is not enabled on your tailnet"*, with a one-time approval link
tied to this specific node. I can't click through a web approval flow
myself, so I sent the user the link and they approved it directly.

Second attempt, after approval: refused again, this time for a local
permissions reason — *"Access denied: serve config denied"*, suggesting
either `sudo` every time or a one-time `tailscale set --operator=$USER`.
Used the lab's known shared sudo password for `linux-vault` to run that
once:

```
sudo tailscale set --operator=$(whoami)
tailscale funnel --bg 8200
```

Vault's API is now reachable at `https://linux-vault.taile932d8.ts.net`,
proxying to `http://127.0.0.1:8200` locally. Confirmed before wiring
anything to it:

```
curl -fsS https://linux-vault.taile932d8.ts.net/v1/sys/health
# {"initialized":true,"sealed":false, ...}
```

### 3. The Function App itself

Installed both `az` CLI and Azure Functions Core Tools this session (neither
existed on this machine before). Created via CLI rather than the portal,
reusing the same resource group and region as Stage 8's earlier work:

```
az functionapp create --name asw-vault-demo-func \
  --resource-group homelab-stage8 --storage-account aswfuncstaufiq \
  --consumption-plan-location southeastasia \
  --runtime node --runtime-version 24 --functions-version 4 --os-type Linux
```

(The `--runtime-version 24` choice here is exactly what broke later — see
below.)

### 4. The function code

Node.js v4 programming model, one HTTP-triggered function
(`src/functions/VaultDemo.js`): reads `VAULT_ADDR`/`VAULT_ROLE_ID`/
`VAULT_SECRET_ID` from its app settings (never hardcoded), POSTs to
`/v1/auth/approle/login` for a client token, GETs
`/v1/secret/data/azure-function-demo` with it, returns the fields as JSON.
Used Node's built-in `fetch` — no extra HTTP client dependency needed.

Tested locally first with `func start` and a separate, throwaway
`secret_id` generated just for that (AppRole allows multiple valid
`secret_id`s at once) — confirmed the whole auth-then-read flow worked
before ever touching the real deployed app.

## What broke, how I found it, how I recovered

### The first deploy 503'd on every single endpoint — including Kudu

**What broke:** `func azure functionapp publish` completed ("Deployment
completed successfully"), but then failed to sync triggers:
```
Error calling sync triggers (BadRequest).
```
Every subsequent request — the function's own URL, the site root, even
`/admin/host/status` and the Kudu/SCM management site — returned a flat
`503 Service Unavailable`. Not a code-level 500, a whole-site failure.

**How I found it:** patient polling (up to several minutes) ruled out a
slow cold start. Deleting and recreating the entire Function App from
scratch reproduced the identical failure on a brand-new resource — which
ruled out "this specific instance got into a bad state" and pointed at
something structural instead. `az monitor activity-log list` on the
resource group showed the real error, which none of the surface-level
messages had shown: every `Sync Web Apps Function Triggers` call was
failing with
```
"Encountered an error (InternalServerError) from host runtime."
```
— the Functions host process itself was crashing on startup, not just
failing to report its triggers.

**How I recovered:** `az functionapp list-runtimes --os linux` showed Node
24 as a valid, listed option — and `az functionapp create` had actively
recommended it, warning that Node 20 was EOL. But "listed as installable"
and "the Function host runtime actually works with it yet" turned out to
be two different things. Switched to Node 22 (the actual current LTS):
```
az functionapp config set --linux-fx-version "Node|22"
```
Redeployed the exact same, unchanged function code. Trigger sync succeeded
immediately this time, no errors, function responded correctly on the
first request. The bug was entirely in the platform/runtime pairing, never
in my code.

## Verification

Live, repeated, not cached:
```
curl https://asw-vault-demo-func.azurewebsites.net/api/VaultDemo
# HTTP 200
# {"source":"HashiCorp Vault, via Tailscale Funnel",
#  "message":"Hello from Vault, fetched by an Azure Function over Tailscale Funnel",
#  "proof_date":"2026-07-26",
#  "fetched_at":"2026-07-26T16:52:40.484Z"}
```
`fetched_at` changes on every call — confirms this is a live round-trip to
Vault on each request, not a value baked in at deploy time.

## Where things live

| Piece | Location |
|---|---|
| Vault secret (demo only) | `secret/azure-function-demo` on `linux-vault` |
| Vault policy + AppRole | `azure-function-demo` (both), on `linux-vault` |
| Tailscale Funnel | Enabled on `linux-vault`, proxying `:8200` → `https://linux-vault.taile932d8.ts.net` |
| Function App | `asw-vault-demo-func`, resource group `homelab-stage8`, Consumption plan, Node 22 Linux |
| Backing storage account | `aswfuncstaufiq` (`homelab-stage8`) |
| Function source | Local-only scratch project (not committed to any repo — this is a throwaway proof, not a maintained app) |
| This write-up | `proxmox-homelab-taufiq/docs/devops-plan/azure-functions-vault-tailscale-funnel.md` |

## Not yet done

- No screenshot captured this session — everything was verified via CLI
  and `curl`. Worth a portal screenshot of the Function App's Overview
  page + a live invocation in the Azure portal's own test console, if a
  visual record is wanted later.
- `secret_id`s generated during iteration (one for local testing, one for
  the first, since-deleted Function App instance) are still technically
  valid until their 24h TTL expires — harmless (AppRole allows multiple
  live `secret_id`s and the policy is read-only to one demo path), not
  worth manually revoking.
