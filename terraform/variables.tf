variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint, including scheme and port."
  type        = string
  default     = "https://192.168.1.2:8006"
}

variable "proxmox_api_token" {
  description = "Proxmox API token, `user@realm!tokenid=uuid`. Keep it out of the repo."
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification. A stock Proxmox install is self-signed, so this starts true."
  type        = bool
  default     = true
}

variable "proxmox_ssh_username" {
  description = "SSH user on the node. Needs write access to the snippets datastore."
  type        = string
  default     = "root"
}

variable "proxmox_ssh_password" {
  type      = string
  sensitive = true
  default   = ""
}

variable "proxmox_ssh_agent" {
  type    = bool
  default = false
}

variable "node_name" {
  description = "Proxmox node the VM is created on."
  type        = string
  default     = "lud"
}

variable "datastore_id" {
  type    = string
  default = "local-lvm"
}

variable "image_datastore_id" {
  description = "Datastore holding the downloaded cloud image. Must allow the `import` content type."
  type        = string
  default     = "local"
}

variable "snippet_datastore_id" {
  description = "Datastore holding cloud-init user-data. Must allow the `snippets` content type."
  type        = string
  default     = "local"
}

variable "bridge" {
  type    = string
  default = "vmbr0"
}

variable "gateway_ip" {
  type    = string
  default = "192.168.1.1"
}

variable "netmask" {
  type    = number
  default = 24
}

variable "dns_servers" {
  type    = list(string)
  default = ["192.168.1.1"]
}

# Rocky, not Fedora. roles/preflight asserts ansible_os_family == 'RedHat' and
# major version 9; Fedora fails both. Pinned rather than tracking
# Rocky-9-GenericCloud-Base.latest, which is a moving file.
variable "rocky_image_url" {
  type    = string
  default = "https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base-9.8-20260525.0.x86_64.qcow2"
}

variable "rocky_image_checksum" {
  type    = string
  default = "92c206cc6f790c61583247eefe87890f8828420662c17cacf247cec78ab4eec8"
}

variable "vm_id" {
  type    = number
  default = 145
}

variable "vm_name" {
  type    = string
  default = "ace"
}

variable "ip" {
  description = "Static address. .40-.44 stay free for the bare-metal estate."
  type        = string
  default     = "192.168.1.45"
}

# The whole control plane runs here: gateway + envoy, controller web/task/
# rsyslog, hub api/content/worker/web, eda api/daphne/worker/activation,
# receptor, postgres, two redis — plus an EE container per running job.
# preflight asserts 7000 MB as a floor; that floor is not a target.
variable "memory" {
  type    = number
  default = 16384
}

variable "vcpu" {
  type    = number
  default = 8
}

variable "disk_size_gb" {
  description = "Eight images, pulp content, and job artifacts."
  type        = number
  default     = 100
}

variable "guest_user" {
  description = "Rocky's cloud image default user."
  type        = string
  default     = "rocky"
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/ace_lab_ed25519.pub"
}
