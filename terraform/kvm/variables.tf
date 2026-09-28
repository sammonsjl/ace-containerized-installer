variable "libvirt_uri" {
  type    = string
  default = "qemu:///system"
}

# "kvm" needs hardware virtualization -- /dev/kvm, i.e. VT-x/AMD-V enabled in
# the firmware. "qemu" is pure software emulation (TCG): it boots, but runs the
# control plane an order of magnitude slower. Only for proving the plumbing on
# a host without KVM.
variable "domain_type" {
  type    = string
  default = "kvm"
  validation {
    condition     = contains(["kvm", "qemu"], var.domain_type)
    error_message = "domain_type must be \"kvm\" or \"qemu\"."
  }
}

variable "vm_name" {
  type    = string
  default = "ace"
}

# A NAT network of its own rather than libvirt's "default": the VM gets a
# fixed address without depending on whatever subnet "default" was given, and
# destroying this root takes the network with it. Reachable from this host
# only.
variable "network_name" {
  type    = string
  default = "ace"
}

variable "network_cidr" {
  type    = string
  default = "192.168.145.0/24"
}

variable "ip" {
  description = "Static address inside network_cidr. Host .1 is libvirt's gateway and DNS."
  type        = string
  default     = "192.168.145.45"
}

# Fixed so cloud-init can match the NIC by it. 52:54:00 is QEMU's prefix.
variable "mac" {
  type    = string
  default = "52:54:00:ac:e0:45"
}

variable "pool_name" {
  type    = string
  default = "ace"
}

variable "pool_path" {
  type    = string
  default = "/var/lib/libvirt/images/ace"
}

# Rocky, not Fedora: roles/preflight asserts RedHat family, major version 9.
# The same pinned image as ../proxmox.
variable "rocky_image_url" {
  type    = string
  default = "https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base-9.8-20260525.0.x86_64.qcow2"
}

# Sized for a workstation, not a hypervisor: preflight's floor is 7000 MB, and
# the host has to keep running too. ../proxmox gives the same stack 16 GB / 8.
variable "memory_mb" {
  type    = number
  default = 8192
}

variable "vcpu" {
  type    = number
  default = 4
}

variable "disk_size_gb" {
  description = "Thin-provisioned; the images, pulp content and job artifacts grow into it."
  type        = number
  default     = 60
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
