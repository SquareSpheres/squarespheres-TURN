# squarespheres-TURN

Automated deployment of a production-ready [coturn](https://github.com/coturn/coturn) TURN/STUN server on DigitalOcean, with a React-based web diagnostic tool for testing WebRTC ICE connectivity.

## What it does

- Provisions a DigitalOcean droplet via **Terraform**
- Bootstraps the server (users, SSH hardening, UFW, coturn, TLS, Docker) via **cloud-init** — runs once on first boot, no local dependencies
- Deploys a **React app** (served by nginx in Docker) that tests TURN connectivity using HMAC-SHA1 REST API credentials

## Architecture

```
Internet → nginx (443) → React SPA
                       → /api/... (optional proxy)

WebRTC clients → coturn
  - STUN:  turn.example.com:3478 / 5349
  - TURN:  turn.example.com:3478 / 5349 (TLS)
  - Relay: UDP 49152–65535
```

**Security model:** Coturn uses time-limited HMAC-SHA1 credentials derived from a shared static secret — no persistent user accounts. The React app generates credentials client-side via WebCrypto.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform) >= 1.0
- A DigitalOcean account and personal access token
- A Cloudflare account managing your domain (for automatic DNS)
- Two SSH key pairs (see below)

## Quick start

### 1. SSH keys

```bash
# Infrastructure operations
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519

# Restricted CI/CD app-deploy user (docker compose only)
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_app_deploy -N ""
```

### 2. Configure

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars with your values (see reference below)
```

Generate the deploy user's sudo password hash:

```bash
python3 -c "from passlib.hash import sha512_crypt; print(sha512_crypt.hash('yourpassword'))"
# or: mkpasswd -m sha-512
```

Generate the TURN static secret:

```bash
openssl rand -hex 32
```

### 3. Deploy

```bash
./deploy.sh
```

This runs the full pipeline:

| Stage | Command | What happens |
|-------|---------|-------------|
| 1 | `./deploy.sh terraform` | Creates droplet + reserved IP, sets Cloudflare DNS |
| 2 | `./deploy.sh bootstrap` | Waits for cloud-init to finish (3–6 min) |
| 3 | `./deploy.sh app` | Builds React app, deploys via rsync, starts Docker |

Or run stages individually if needed.

## Configuration reference

### `terraform/terraform.tfvars` (gitignored)

| Key | Default | Description |
|-----|---------|-------------|
| `do_token` | — | DigitalOcean API token |
| `ssh_public_key` | — | SSH public key installed on droplet (root access during bootstrap) |
| `deploy_pubkey` | — | SSH public key for the `deploy` user |
| `app_deploy_pubkey` | — | SSH public key for the `app-deploy` user |
| `turn_static_secret` | — | HMAC-SHA1 shared secret for coturn |
| `deploy_sudo_password_hash` | — | SHA-512 hashed password for the `deploy` user |
| `cf_api_token` | — | Cloudflare API token (Edit zone DNS) |
| `cf_zone_id` | — | Cloudflare Zone ID |
| `turn_domain` | — | FQDN for the TURN server (e.g. `turn.example.com`) |
| `certbot_email` | — | Let's Encrypt notification email |
| `certbot_staging` | `false` | Use Let's Encrypt staging (higher rate limits, untrusted cert) |
| `region` | `fra1` | DigitalOcean region |
| `droplet_size` | `s-1vcpu-1gb` | Droplet size slug |
| `droplet_name` | `coturn-fra1` | Droplet hostname |
| `turn_listening_port` | `3478` | Plain TURN/STUN port |
| `turn_tls_listening_port` | `5349` | TLS TURN port |
| `turn_min_port` | `49152` | UDP relay range start |
| `turn_max_port` | `65535` | UDP relay range end |

## Ports / firewall

| Port | Protocol | Purpose |
|------|----------|---------|
| 22 | TCP | SSH |
| 80 | TCP | HTTP (certbot standalone challenge) |
| 443 | TCP | HTTPS (React app) |
| 3478 | TCP + UDP | TURN/STUN |
| 5349 | TCP + UDP | TURN/STUN over TLS |
| 49152–65535 | UDP | TURN relay range |

## Monitoring cloud-init

After `./deploy.sh terraform`, cloud-init runs automatically on the droplet. To observe it:

```bash
# Wait for completion
ssh deploy@<ip> 'cloud-init status --wait'

# Check for errors
ssh deploy@<ip> 'cloud-init status --long'

# Full output log (requires sudo)
ssh -t deploy@<ip> 'sudo cat /var/log/cloud-init-output.log'
```

## Frontend diagnostic tool

The React app at `https://<your-domain>` tests TURN connectivity:

1. Generates time-limited credentials via HMAC-SHA1 (client-side, WebCrypto)
2. Creates a `RTCPeerConnection` with your TURN server
3. Gathers ICE candidates and reports:
   - **relay** — TURN is working
   - **srflx** — STUN reachable, but no relay (check credentials/secret)
   - **host-only** — Server unreachable (check ports/firewall)

> WebRTC traffic is not visible in the browser network inspector. Use `about:webrtc` (Firefox) or `chrome://webrtc-internals` (Chrome) to observe ICE gathering in detail.

### Local development

```bash
cd app
cp .env.example .env      # set TURN_DOMAIN
docker compose -f docker-compose.dev.yml up
# → http://localhost:5173 with hot reload
```

## Project structure

```
.
├── deploy.sh                    # Orchestration: terraform → bootstrap → app
├── terraform/
│   ├── main.tf                  # Droplet, reserved IP, Cloudflare DNS, firewall
│   ├── variables.tf
│   ├── outputs.tf
│   ├── cloud-init.yml.tpl       # Bootstrap: users, SSH, UFW, coturn, TLS, Docker
│   └── terraform.tfvars.example
└── app/
    ├── Dockerfile               # Multi-stage: Vite build → nginx
    ├── docker-compose.yml       # Production
    ├── docker-compose.dev.yml   # Development (hot reload)
    ├── nginx/
    │   └── default.conf.template
    └── frontend/                # React 18 + Vite
        └── src/components/IceTester.jsx
```

## Server users

| User | Purpose | SSH | Sudo |
|------|---------|-----|------|
| `deploy` | Infrastructure ops | Yes | Full (password required) |
| `app-deploy` | CI/CD docker compose deploys | Yes | Restricted to `docker compose` on `/opt/app` only |
| `turnserver` | TURN server process (created by coturn package) | No | No |
