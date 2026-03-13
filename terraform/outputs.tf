output "droplet_ip" {
  description = "Public IPv4 address of the coturn droplet"
  value       = digitalocean_reserved_ip.coturn.ip_address
}

output "turn_domain" {
  description = "Full domain for the TURN server"
  value       = var.turn_domain
}

output "cloud_init_status_command" {
  value = "ssh deploy@${digitalocean_reserved_ip.coturn.ip_address} 'cloud-init status --wait'"
}
