# ACE containerized control plane — one podman host, on local KVM/libvirt.
# ../proxmox builds the same host on Proxmox VE; both render the shared
# ../cloud-init/user-data.yaml.tftpl, so the guest is identical and the same
# playbooks run against either (inventory/kvm.yml for this one).

locals {
  ssh_pubkey = trimspace(file(pathexpand(var.ssh_public_key_path)))
  prefix     = split("/", var.network_cidr)[1]
  gateway    = cidrhost(var.network_cidr, 1)
}

resource "libvirt_network" "ace" {
  name      = var.network_name
  autostart = true
  forward   = { mode = "nat" }
  ips = [{
    address = local.gateway
    prefix  = tonumber(local.prefix)
  }]
  dns = { enable = "yes" }
}

resource "libvirt_pool" "ace" {
  name   = var.pool_name
  type   = "dir"
  target = { path = var.pool_path }
  # qcow2 on a copy-on-write filesystem (btrfs) fragments badly; libvirt sets
  # the directory NOCOW when the filesystem supports it, and ignores it
  # otherwise.
  features = { cow = { state = "no" } }
}

resource "libvirt_volume" "rocky" {
  name   = "rocky-9.8-20260525.0.qcow2"
  pool   = libvirt_pool.ace.name
  target = { format = { type = "qcow2" } }
  create = { content = { url = var.rocky_image_url } }
}

# A copy-on-write overlay on the cloud image, grown to disk_size_gb. cloud-init
# growpart expands the root filesystem into it on first boot.
resource "libvirt_volume" "disk" {
  name     = "${var.vm_name}.qcow2"
  pool     = libvirt_pool.ace.name
  capacity = var.disk_size_gb * 1024 * 1024 * 1024
  target   = { format = { type = "qcow2" } }
  backing_store = {
    path   = libvirt_volume.rocky.path
    format = { type = "qcow2" }
  }
}

resource "libvirt_cloudinit_disk" "init" {
  name = "${var.vm_name}-cloudinit"
  user_data = templatefile("${path.module}/../cloud-init/user-data.yaml.tftpl", {
    hostname   = var.vm_name
    guest_user = var.guest_user
    ssh_pubkey = local.ssh_pubkey
    ip         = var.ip
  })
  meta_data = yamlencode({
    instance-id    = var.vm_name
    local-hostname = var.vm_name
  })
  # Proxmox writes the static address into its own cloud-init drive; here it
  # has to be spelled out. Matched by the MAC the domain is given below, so it
  # does not depend on the image's NIC naming. The default route is
  # 0.0.0.0/0, not "default": Rocky 9's cloud-init (24.4) rejects "default" as
  # an invalid address, discards the whole network config, and the NIC falls
  # back to DHCP -- which this network does not serve.
  network_config = yamlencode({
    version = 2
    ethernets = {
      eth0 = {
        match       = { macaddress = var.mac }
        set-name    = "eth0"
        addresses   = ["${var.ip}/${local.prefix}"]
        routes      = [{ to = "0.0.0.0/0", via = local.gateway }]
        nameservers = { addresses = [local.gateway] }
      }
    }
  })
}

resource "libvirt_volume" "init" {
  name   = "${var.vm_name}-cloudinit.iso"
  pool   = libvirt_pool.ace.name
  create = { content = { url = libvirt_cloudinit_disk.init.path } }
}

resource "libvirt_domain" "ace" {
  name        = var.vm_name
  type        = var.domain_type
  description = "ACE containerized control plane — rootless podman host"
  memory      = var.memory_mb
  memory_unit = "MiB"
  vcpu        = var.vcpu
  autostart   = true
  running     = true

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
  }

  # host-passthrough gives the guest the real CPU's features (x86-64-v3 and
  # up, which Rocky 9 userspace and the images want). Under TCG there is no
  # host CPU to pass through, so emulate the most capable model instead.
  cpu = var.domain_type == "kvm" ? { mode = "host-passthrough" } : { mode = "maximum" }

  # Not defaults here: a domain that does not ask for ACPI gets acpi=off, and
  # a q35 machine without it never gets past the BIOS.
  features = {
    acpi = true
    apic = {}
  }

  devices = {
    disks = [
      {
        source = { volume = { pool = libvirt_volume.disk.pool, volume = libvirt_volume.disk.name } }
        target = { bus = "virtio", dev = "vda" }
        driver = { type = "qcow2", discard = "unmap" }
      },
      {
        device = "cdrom"
        source = { volume = { pool = libvirt_volume.init.pool, volume = libvirt_volume.init.name } }
        target = { bus = "sata", dev = "sda" }
      },
    ]
    interfaces = [{
      type   = "network"
      model  = { type = "virtio" }
      mac    = { address = var.mac }
      source = { network = { network = libvirt_network.ace.name } }
    }]
    # `virsh console ace` -- the only way in if SSH never comes up. Everything
    # it prints (kernel, cloud-init) is also kept in the log file, readable
    # with sudo.
    consoles = [{
      target = { type = "serial", port = 0 }
      log    = { file = "/var/log/libvirt/qemu/${var.vm_name}-console.log", append = "on" }
    }]
    # Required even with no display attached: with no video device at all the
    # Rocky image never gets past the BIOS (tested -- the same disk boots the
    # moment any VGA is present).
    videos = [{ model = { type = "virtio", heads = 1, primary = "yes" } }]
    rngs   = [{ model = "virtio", backend = { random = "/dev/urandom" } }]
    # The port cloud-init's qemu-guest-agent listens on. Without it the agent
    # is installed but never starts; with it, `virsh domifaddr ace --source
    # agent` and clean `virsh shutdown` work.
    channels = [{
      source = { unix = { mode = "bind" } }
      target = { virt_io = { name = "org.qemu.guest_agent.0" } }
    }]
  }
}
