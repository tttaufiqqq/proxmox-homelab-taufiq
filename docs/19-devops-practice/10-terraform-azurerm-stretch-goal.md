<!-- Not yet sequenced into a numbered docs/ folder, lives here in
     docs/19-devops-practice/ until the full devops-practice-plan.md is complete.
     Date below is provisional (the date this actually happened); revisit
     once final sequencing/dating is decided. -->

# Terraform Talking to a Second Provider

**Date:** 2026-07-26/27
**Repo the actual code lives in:** `Animal-Shelter-Workshop`,
`infrastructure/terraform-azure/` (new directory, separate from Stage 1's
`infrastructure/terraform/` which targets Proxmox), this write-up lives in
the homelab meta-repo alongside the devops practice plan it's a stage of
(`devops-practice-plan.md`, Stage 8, Step 4, the plan's final item).

## Why I built this

- This is the last item in the entire devops-practice-plan.
- The point wasn't a new VM I actually need.
- It's proving the same Terraform skill (write config, `plan`, `apply`,
  verify, `destroy`) transfers to a completely different provider, the same
  way Stage 1 proved it for Proxmox.
- Same tool, different cloud, same discipline: prove it once, tear it down,
  don't let it become a second permanent environment.

## Flow

```
┌────────────────────────────────────┐
│  STAGE 8, STEP 4, TERRAFORM → AZURE (STRETCH) │▏
└────────────────────────────────────┘▔▔

┌────────────────────────────────┐     done, dedicated Service Principal,
│ 1. Auth: Service Principal        │▏    Contributor on the subscription,
└────────────────────────────────┘▔▔    created just for this
              │
              ▼
┌────────────────────────────────┐     done, RG, vnet/subnet, public IP,
│ 2. azurerm config written         │▏    NSG (SSH from one IP only), NIC,
└────────────────────────────────┘▔▔    one Linux VM, new separate directory
              │
              ▼
┌────────────────────────────────┐     hit twice, planned Standard_B1s/
│ 3. terraform apply                │▏    B2s both failed on regional
└────────────────────────────────┘▔▔    capacity; Standard_D2s_v3 worked
              │
              ▼
┌────────────────────────────────┐     done, real SSH, hostname matched,
│ 4. Proved it boots                │▏    "up 0 min" confirmed a fresh boot
└────────────────────────────────┘▔▔
              │
              ▼
┌────────────────────────────────┐     done, terraform destroy, then the
│ 5. Destroyed immediately          │▏    Service Principal deleted too,
└────────────────────────────────┘▔▔    nothing left running or billing
```

## What I built

A new, separate Terraform directory (not reusing Stage 1's Proxmox config
at all) using the `azurerm` provider:

- `azurerm_resource_group`, dedicated (`homelab-stage8-terraform-stretch`),
  separate from the `homelab-stage8` group Steps 1-3's Storage
  Account/Function App live in long-term, so this whole group could be
  created and destroyed as one clean unit
- `azurerm_virtual_network` + `azurerm_subnet`
- `azurerm_public_ip` (Standard SKU, static)
- `azurerm_network_security_group`, SSH allowed from exactly one IP (my
  current public IP), not "Internet", same least-privilege habit as every
  UFW rule elsewhere in this homelab
- `azurerm_network_interface` + the NSG association
- `azurerm_linux_virtual_machine`, Ubuntu 24.04, SSH key auth only
  (`disable_password_authentication = true`), reusing the same
  `iphone-11-taufiq` key used everywhere else in this lab

**Auth:**
- Dedicated Service Principal (`terraform-asw-stretch`), Contributor scoped
  to the whole subscription, created just for this, deleted again right
  after the destroy.
- Not stored anywhere; passed as `ARM_*` environment variables for the
  duration of the `apply`/`destroy` cycle only, never written to
  `terraform.tfvars` or committed.

## What broke, how I found it, how I recovered

### 1. Terraform's own AzureCLI authorizer hung indefinitely

**What broke:**
- `terraform plan`, authenticating via the AzureCLI authorizer (relying on
  my already-logged-in `az` session), never completed.
- No error, no progress, still running after 5+ minutes.

**How I found it:**
- Checked running processes directly, `terraform` was genuinely still
  alive, not crashed, but no `az` child process was visible and no output
  ever appeared.
- Long enough to rule out "just slow," short of tracing exactly why
  Terraform's subprocess invocation of `az.cmd` wasn't completing on this
  Windows setup.

**How I recovered:**
- Switched to a dedicated Service Principal
  (`ARM_CLIENT_ID`/`ARM_CLIENT_SECRET`/`ARM_TENANT_ID`/`ARM_SUBSCRIPTION_ID`
  env vars) instead of the CLI-based authorizer.
- More reliable for automation anyway, and closer to how Stage 1's own
  Proxmox provider authenticates (a dedicated token, not an interactive
  session).

### 2. The originally-planned VM size wasn't actually available

**What broke:**
- `terraform apply` failed creating the VM itself (all 7 other resources
  succeeded first):
```
SkuNotAvailable: Following SKUs have failed for Capacity Restrictions:
Standard_B1s ... currently not available in location 'southeastasia'
```

**How I found it:**
- Tried the next cheapest burstable alternative, `Standard_B2s`, identical
  failure, same capacity-restriction message.
- That ruled out "just this one SKU" and pointed at the whole B-series
  being capacity-constrained for this subscription in this region right
  now, not a config mistake on my end.

**How I recovered:**
- Switched to `Standard_D2s_v3` (a much more universally-available
  general-purpose size), applied cleanly, VM up in under a minute.
- Updated `variables.tf`'s default to match what actually works, with a
  comment explaining why it isn't the originally-planned B-series.

## Verification

```
$ terraform apply -var="vm_size=Standard_D2s_v3" -auto-approve
Apply complete! Resources: 8 added, 0 changed, 0 destroyed.
public_ip_address = "4.193.100.57"

$ ssh taufiq@4.193.100.57 "echo CONNECTED && hostname && uptime"
CONNECTED
asw-stretch-vm
 17:28:02 up 0 min,  1 user,  load average: 1.49, 0.39, 0.13
```

- Real SSH connection, correct hostname.
- "up 0 min" confirming a genuine fresh boot, not a cached/reused instance.

Torn down immediately after:
```
$ terraform destroy -auto-approve
Destroy complete! Resources: 8 destroyed.

$ az group exists --name homelab-stage8-terraform-stretch
false
```

- Service Principal deleted right after (`az ad sp delete`), nothing left
  behind, credential or resource.

## Where things live

| Piece | Path |
|---|---|
| Terraform config | `Animal-Shelter-Workshop/infrastructure/terraform-azure/` (`main.tf`, `variables.tf`, `vm.tf`, `outputs.tf`) |
| Example vars | `terraform.tfvars.example` (committed); real `terraform.tfvars` gitignored |
| This write-up | `proxmox-homelab-taufiq/docs/19-devops-practice/10-terraform-azurerm-stretch-goal.md` |

- Nothing Azure-side remains from this step — the resource group, VM, and
  Service Principal were all destroyed/deleted in this same session.
- Only the `.tf` code itself is left committed, same precedent as Stage 1's
  own 200-series test VMs (code stays, infrastructure doesn't).
