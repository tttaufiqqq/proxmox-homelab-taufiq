variable "proxmox_endpoint" {
  description = "Proxmox API URL, e.g. https://192.168.1.10:8006"
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token — format: USER@REALM!TOKENID=UUID"
  type        = string
  sensitive   = true
}

variable "proxmox_ssh_user" {
  description = "SSH user for the Proxmox host (needed to upload cloud-init snippets)"
  type        = string
  default     = "root"
}

variable "proxmox_ssh_password" {
  description = "SSH password for the Proxmox host"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Proxmox node name (shown in Proxmox UI, e.g. 'pve')"
  type        = string
  default     = "pve"
}
