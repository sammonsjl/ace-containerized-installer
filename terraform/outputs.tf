output "ace_host" {
  description = "Where the control plane lives, and how to reach it."
  value = {
    name = var.vm_name
    ip   = var.ip
    user = var.guest_user
    url  = "https://${var.ip}"
  }
}
