# These 3 hosts are genuinely shared homelab infrastructure, not specific to
# any one project — moved here from Animal-Shelter-Workshop's Terraform
# (which is scoped to that project only, per devops-practice-plan.md) once
# that stopped being the right home for them. `linux-observability` monitors
# the whole 12-host fleet, `linux-mini-io` is general-purpose S3 storage
# (also used by Library-System-EDP) and now hosts this very config's own
# state backend, and `linux-k3s` is homelab-level compute. All 3 were
# adopted via `terraform import`, never created fresh, and were already
# proven zero-drift once in their old location — these blocks are copied
# verbatim from there, not rebuilt. Full story:
# docs/20-homelab-terraform/homelab-terraform-split.md
#
# Do not `terraform destroy` any of these.

resource "proxmox_virtual_environment_container" "linux_k3s" {
  node_name     = var.proxmox_node
  vm_id         = 100
  unprivileged  = true
  started       = false
  start_on_boot = true

  cpu {
    cores = 1
  }

  memory {
    dedicated = 3072
    swap      = 768
  }

  disk {
    datastore_id = "local"
    size         = 8
  }

  network_interface {
    name     = "eth0"
    bridge   = "vmbr0"
    vlan_id  = 30
    firewall = true
  }

  initialization {
    hostname = "linux-k3s"

    dns {
      servers = ["8.8.8.8"]
    }

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  console {
    enabled   = true
    tty_count = 2
    type      = "tty"
  }

  features {
    nesting = true
    keyctl  = true
  }

  operating_system {
    template_file_id = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
    type              = "ubuntu"
  }

  lifecycle {
    ignore_changes = [operating_system]
  }

  timeout_clone  = 1800
  timeout_create = 1800
  timeout_delete = 60
  timeout_update = 1800
}

resource "proxmox_virtual_environment_container" "linux_k3s_2" {
  # k3s agent node (worker only, no control-plane role) — see
  # plans/06-k3s-multi-node-gitops-automation-plan.md Stage 1. Same
  # "start small" sizing discipline as linux_k3s itself.
  node_name     = var.proxmox_node
  vm_id         = 118
  unprivileged  = true
  started       = true
  start_on_boot = true

  cpu {
    cores = 1
  }

  memory {
    dedicated = 2048
    swap      = 768
  }

  disk {
    datastore_id = "local"
    size         = 8
  }

  network_interface {
    name     = "eth0"
    bridge   = "vmbr0"
    vlan_id  = 30
    firewall = true
  }

  initialization {
    hostname = "linux-k3s-2"

    dns {
      servers = ["8.8.8.8"]
    }

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  console {
    enabled   = true
    tty_count = 2
    type      = "tty"
  }

  features {
    # keyctl deliberately omitted here — the automation API token can't set
    # feature flags other than nesting on container create (HTTP 403,
    # "changing feature flags (except nesting) is only allowed for
    # root@pam"). Added post-creation via `pct set` over root SSH instead
    # (not restricted the same way), matching linux_k3s's own real config.
    nesting = true
  }

  operating_system {
    template_file_id = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
    type              = "ubuntu"
  }

  lifecycle {
    ignore_changes = [operating_system, features]
  }

  timeout_clone  = 1800
  timeout_create = 1800
  timeout_delete = 60
  timeout_update = 1800
}

resource "proxmox_virtual_environment_container" "linux_k3s_3" {
  # k3s agent node, dedicated to ArgoCD/observability tooling — see
  # plans/07-k3s-production-cutover-plan.md Stage 1. Same "start small"
  # sizing discipline as linux_k3s_2 itself.
  node_name     = var.proxmox_node
  vm_id         = 119
  unprivileged  = true
  started       = true
  start_on_boot = true

  cpu {
    cores = 1
  }

  memory {
    dedicated = 2048
    swap      = 768
  }

  disk {
    datastore_id = "local"
    size         = 8
  }

  network_interface {
    name     = "eth0"
    bridge   = "vmbr0"
    vlan_id  = 30
    firewall = true
  }

  initialization {
    hostname = "linux-k3s-3"

    dns {
      servers = ["8.8.8.8"]
    }

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  console {
    enabled   = true
    tty_count = 2
    type      = "tty"
  }

  features {
    # keyctl deliberately omitted — same automation-API restriction as
    # linux_k3s_2; added post-creation via `pct set` over root SSH.
    nesting = true
  }

  operating_system {
    template_file_id = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
    type              = "ubuntu"
  }

  lifecycle {
    ignore_changes = [operating_system, features]
  }

  timeout_clone  = 1800
  timeout_create = 1800
  timeout_delete = 60
  timeout_update = 1800
}

resource "proxmox_virtual_environment_container" "linux_observability" {
  node_name     = var.proxmox_node
  vm_id         = 114
  unprivileged  = true
  started       = true
  start_on_boot = true

  cpu {
    cores = 1
  }

  memory {
    dedicated = 1536
    swap      = 512
  }

  disk {
    datastore_id = "local"
    size         = 8
  }

  network_interface {
    name    = "eth0"
    bridge  = "vmbr0"
    vlan_id = 80
  }

  initialization {
    hostname = "linux-observability"

    dns {
      servers = ["8.8.8.8"]
    }

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  console {
    enabled   = true
    tty_count = 2
    type      = "tty"
  }

  features {
    nesting = true
    keyctl  = true
  }

  operating_system {
    template_file_id = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
    type              = "ubuntu"
  }

  lifecycle {
    ignore_changes = [operating_system]
  }

  timeout_clone  = 1800
  timeout_create = 1800
  timeout_delete = 60
  timeout_update = 1800
}

resource "proxmox_virtual_environment_container" "linux_mongodb" {
  node_name     = var.proxmox_node
  vm_id         = 108
  unprivileged  = true
  started       = false
  start_on_boot = true

  cpu {
    cores = 1
  }

  memory {
    dedicated = 1024
    swap      = 512
  }

  disk {
    datastore_id = "local"
    size         = 8
  }

  network_interface {
    name     = "eth0"
    bridge   = "vmbr0"
    vlan_id  = 20
    firewall = true
  }

  initialization {
    hostname = "linux-mongodb"

    dns {
      domain  = "local"
      servers = ["8.8.8.8"]
    }

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  console {
    enabled   = true
    tty_count = 2
    type      = "tty"
  }

  features {
    nesting = true
  }

  operating_system {
    template_file_id = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
    type              = "ubuntu"
  }

  lifecycle {
    ignore_changes = [operating_system]
  }

  timeout_clone  = 1800
  timeout_create = 1800
  timeout_delete = 60
  timeout_update = 1800
}

resource "proxmox_virtual_environment_vm" "linux_mini_io" {
  name          = "linux-mini-io"
  vm_id         = 109
  node_name     = var.proxmox_node
  started       = true
  on_boot       = true
  scsi_hardware = "virtio-scsi-single"

  operating_system {
    type = "l26"
  }

  cpu {
    cores = 2
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 4096
  }

  disk {
    datastore_id = "local"
    size         = 18
    interface    = "scsi0"
    file_format  = "qcow2"
    iothread     = true
  }

  disk {
    datastore_id = "local"
    size         = 32
    interface    = "scsi1"
    file_format  = "qcow2"
    iothread     = true
  }

  cdrom {
    file_id   = "local:iso/ubuntu-22.04.5-live-server-amd64.iso"
    interface = "ide2"
  }

  network_device {
    bridge   = "vmbr0"
    model    = "virtio"
    vlan_id  = 30
    firewall = true
  }
}
