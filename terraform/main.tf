terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}

provider "cloudflare" {
  api_token = var.cf_api_token
}

resource "digitalocean_ssh_key" "coturn" {
  name       = "${var.droplet_name}-key"
  public_key = var.ssh_public_key
}

resource "digitalocean_droplet" "coturn" {
  name     = var.droplet_name
  region   = var.region
  size     = var.droplet_size
  image    = "ubuntu-22-04-x64"
  ssh_keys = [digitalocean_ssh_key.coturn.fingerprint]

  user_data = templatefile("${path.module}/cloud-init.yml.tpl", {
    turn_realm                = var.turn_domain
    certbot_email             = var.certbot_email
    turn_listening_port       = var.turn_listening_port
    turn_tls_listening_port   = var.turn_tls_listening_port
    turn_min_port             = var.turn_min_port
    turn_max_port             = var.turn_max_port
    turn_static_secret        = var.turn_static_secret
    deploy_pubkey             = var.deploy_pubkey
    app_deploy_pubkey         = var.app_deploy_pubkey
    deploy_sudo_password_hash = var.deploy_sudo_password_hash
    reserved_ip               = digitalocean_reserved_ip.coturn.ip_address
    certbot_staging           = var.certbot_staging
  })
}

resource "digitalocean_reserved_ip" "coturn" {
  region = var.region
}

resource "digitalocean_reserved_ip_assignment" "coturn" {
  ip_address = digitalocean_reserved_ip.coturn.ip_address
  droplet_id = digitalocean_droplet.coturn.id
}

resource "cloudflare_record" "coturn" {
  zone_id = var.cf_zone_id
  # Cloudflare normalises the FQDN to just the subdomain ("turn") automatically.
  name    = var.turn_domain
  content = digitalocean_reserved_ip.coturn.ip_address
  type    = "A"
  ttl     = 60
  proxied = false
}

resource "digitalocean_firewall" "coturn" {
  name        = "${var.droplet_name}-fw"
  droplet_ids = [digitalocean_droplet.coturn.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.ssh_allowed_cidrs
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "3478"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "udp"
    port_range       = "3478"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "5349"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "udp"
    port_range       = "5349"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "udp"
    port_range       = "49152-65535"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "all"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "all"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
