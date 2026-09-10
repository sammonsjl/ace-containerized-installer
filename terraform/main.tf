# ACE containerized control plane — one podman host.
#
# A separate root module from the bare-metal estate on purpose. That module's
# var.nodes map drives /etc/hosts and the NFS export list across all five of
# its VMs, so adding a sixth member there would rewrite cloud-init on every one
# of them. Two tracks, two states.

locals {
  ssh_pubkey = trimspace(file(pathexpand(var.ssh_public_key_path)))
}

resource "proxmox_download_file" "rocky" {
  node_name    = var.node_name
  content_type = "import"
  datastore_id = var.image_datastore_id

  url                = var.rocky_image_url
  file_name          = "ace-rocky-9.8-20260525.0.qcow2"
  checksum           = var.rocky_image_checksum
  checksum_algorithm = "sha256"

  overwrite      = false
  upload_timeout = 1800
}

resource "proxmox_virtual_environment_file" "user_data" {
  node_name    = var.node_name
  content_type = "snippets"
  datastore_id = var.snippet_datastore_id

  source_raw {
    file_name = "${var.vm_name}-user-data.yaml"
    data = templatefile("${path.module}/cloud-init/user-data.yaml.tftpl", {
      hostname   = var.vm_name
      guest_user = var.guest_user
      ssh_pubkey = local.ssh_pubkey
      ip         = var.ip
    })
  }
}

resource "proxmox_virtual_environment_vm" "ace" {
  node_name = var.node_name
  vm_id     = var.vm_id
  name      = var.vm_name
  tags      = ["ace", "containerized"]

  description = "ACE containerized control plane — rootless podman host"
  on_boot     = true

  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"
  bios          = "seabios"

  # Enabled, but the timeout is longer than the bare-metal estate's 5m: there
  # the agent was already in the image, here cloud-init has to install it
  # before it can answer, and the provider waits for that before it calls the
  # VM created.
  agent {
    enabled = true
    timeout = "15m"
  }

  stop_on_destroy = true

  cpu {
    cores = var.vcpu
    type  = "host"
  }

  memory {
    dedicated = var.memory
  }

  network_device {
    bridge = var.bridge
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    iothread     = true
    discard      = "on"
    ssd          = true
    size         = var.disk_size_gb
    import_from  = proxmox_download_file.rocky.id
  }

  boot_order = ["scsi0"]

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = var.datastore_id
    interface    = "ide2"

    dns {
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        address = "${var.ip}/${var.netmask}"
        gateway = var.gateway_ip
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.user_data.id
  }

  lifecycle {
    # Same reasoning as the bare-metal module: the provider records the disk's
    # post-import size, and both import_from and user_data_file_id are
    # create-time inputs that Terraform would otherwise propose replacing a
    # running VM to deliver. Rebuild deliberately with `terraform taint`.
    ignore_changes = [
      disk[0].size,
      disk[0].import_from,
      initialization[0].user_data_file_id,
    ]
  }
}
