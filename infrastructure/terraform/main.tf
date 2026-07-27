terraform {
  required_version = ">= 1.5"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }

  # State lives on the homelab's own self-hosted MinIO (linux-mini-io) — same
  # instance Animal-Shelter-Workshop's Terraform uses, but a separate bucket
  # and a separately-scoped credential (terraform-homelab, policy-restricted
  # to only this bucket), so a problem in one Terraform config's state can
  # never touch the other's. Same "scope the credential, not just the
  # network" reasoning used everywhere else in this homelab.
  backend "s3" {
    bucket = "homelab-infra-tfstate"
    key    = "terraform.tfstate"
    region = "us-east-1" # required by the backend, meaningless to MinIO

    endpoints = {
      s3 = "http://100.73.172.85:9000" # linux-mini-io, Tailscale IP
    }

    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}

provider "proxmox" {
  # e.g. https://192.168.1.10:8006 — Proxmox web UI URL
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token

  # Proxmox uses a self-signed cert by default
  insecure = true

  # bpg/proxmox needs SSH access to the node for some operations. By default
  # it resolves the node's address from Proxmox's own cluster config, which
  # is the node's LAN IP (10.0.10.2) — unreachable from a control node that
  # only has Tailscale connectivity to the host. Override it to the same
  # Tailscale IP used for the API endpoint. Same credentials as
  # Animal-Shelter-Workshop's Terraform (same automation identity, same
  # homelab — no reason to mint a second Proxmox-side token for this).
  ssh {
    agent    = false
    username = var.proxmox_ssh_user
    password = var.proxmox_ssh_password

    node {
      name    = var.proxmox_node
      address = "100.97.8.93"
    }
  }
}
