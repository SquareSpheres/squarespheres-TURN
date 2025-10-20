output "droplet_ip" {
  description = "Public IPv4 address of the coturn droplet"
  value       = digitalocean_droplet.coturn.ipv4_address
}
