variable "do_token" {
  description = "DigitalOcean API token"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key to install on the droplet"
  type        = string
  sensitive   = true
}

variable "droplet_name" {
  description = "Name of the droplet"
  type        = string
  default     = "coturn-fra1"
}

variable "region" {
  description = "DigitalOcean region"
  type        = string
  default     = "fra1"
}

variable "droplet_size" {
  description = "DigitalOcean droplet size slug"
  type        = string
  default     = "s-1vcpu-1gb"
}

variable "cf_api_token" {
  description = "Cloudflare API token (Edit zone DNS permission)"
  type        = string
  sensitive   = true
}

variable "cf_zone_id" {
  description = "Cloudflare Zone ID for the domain"
  type        = string
  sensitive   = true
}

variable "turn_domain" {
  description = "Full domain for the TURN server (e.g. 'turn.example.com')"
  type        = string
}

variable "deploy_pubkey" {
  description = "SSH public key for the deploy user"
  type        = string
  sensitive   = true
}

variable "app_deploy_pubkey" {
  description = "SSH public key for the app-deploy user (CI/CD)"
  type        = string
  sensitive   = true
}

variable "turn_static_secret" {
  description = "HMAC-SHA1 static auth secret for coturn"
  type        = string
  sensitive   = true
}

variable "deploy_sudo_password_hash" {
  description = "SHA-512 hashed password for the deploy user (/etc/shadow format)"
  type        = string
  sensitive   = true
}

variable "ssh_allowed_cidrs" {
  description = "List of CIDRs allowed to reach SSH port 22 (e.g. your home IP: [\"1.2.3.4/32\"])"
  type        = list(string)
}

variable "certbot_email" {
  description = "Email for Let's Encrypt notifications"
  type        = string
  default     = ""
}

variable "certbot_staging" {
  description = "Use Let's Encrypt staging environment (higher rate limits, untrusted cert)"
  type        = bool
  default     = false
}

variable "turn_listening_port" {
  type    = number
  default = 3478
}

variable "turn_tls_listening_port" {
  type    = number
  default = 5349
}

variable "turn_min_port" {
  type    = number
  default = 49152
}

variable "turn_max_port" {
  type    = number
  default = 65535
}
