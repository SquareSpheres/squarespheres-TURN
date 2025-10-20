# squarespheres-TURN

Automated deployment of a production-ready [coturn](https://github.com/coturn/coturn) TURN/STUN server on DigitalOcean, with a React-based web diagnostic tool for testing WebRTC ICE connectivity.

## What it does

- Provisions a DigitalOcean droplet via **Terraform**
- Configures coturn, TLS (Let's Encrypt), firewall, SSH hardening, and fail2ban via **Ansible**
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
- [Ansible](https://docs.ansible.com/) >= 2.12 + `passlib` Python package
- [Docker](https://docs.docker.com/) (for local app builds)
- A DigitalOcean account and personal access token
- A domain name pointed at the droplet IP (required for TLS)
- Two SSH key pairs (see below)

## Quick start

### 1. SSH keys

```bash
# Infrastructure / Ansible operations
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519

# Restricted CI/CD app-deploy user (docker compose only)
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_app_deploy -N ""
```

### 2. Configure

```bash
# Root env (Terraform needs DO_TOKEN)
cp .env.example .env
# Edit .env: set DO_TOKEN and SSH_PUBLIC_KEY_PATH

# Terraform variables
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars: set do_token, ssh_public_key, region, droplet_size

# Ansible public variables
# Edit ansible/group_vars/all/vars.yml: set turn_realm, turn_domain, certbot_email, etc.

# Ansible secrets (gitignored)
cp ansible/group_vars/all/secrets.yml.example ansible/group_vars/all/secrets.yml
# Edit secrets.yml: set turn_static_secret and deploy_sudo_password hash
```

Generate the sudo password hash:

```bash
python3 -c "from passlib.hash import sha512_crypt; print(sha512_crypt.hash('yourpassword'))"
```

### 3. Deploy

```bash
./deploy.sh all
```

This runs the full pipeline:

| Stage | Command | What happens |
|-------|---------|-------------|
| 1 | `./deploy.sh terraform` | Creates droplet, outputs IP |
| — | *(manual)* | Point your DNS A record at the IP |
| 2 | `./deploy.sh ansible` | Installs coturn, TLS, Docker, hardens server |
| 3 | `./deploy.sh app` | Builds React app, deploys via rsync, starts Docker |

Or run stages individually if needed.

## Configuration reference

### `ansible/group_vars/all/vars.yml` (public)

| Key | Default | Description |
|-----|---------|-------------|
| `turn_realm` | `turn.squarespheres.com` | TURN realm |
| `turn_domain` | `turn.squarespheres.com` | FQDN for TLS cert |
| `certbot_email` | — | Let's Encrypt registration email |
| `turn_listening_port` | `3478` | Plain TURN/STUN port |
| `turn_tls_listening_port` | `5349` | TLS TURN port |
| `turn_min_port` / `turn_max_port` | `49152` / `65535` | UDP relay range |
| `app_deploy_path` | `/opt/app` | Server path for Docker app |

### `ansible/group_vars/all/secrets.yml` (gitignored)

| Key | Description |
|-----|-------------|
| `turn_static_secret` | Shared secret for HMAC-SHA1 credential generation |
| `deploy_sudo_password` | SHA-512 hash of the deploy user's sudo password |

### `terraform/terraform.tfvars` (gitignored)

| Key | Default | Description |
|-----|---------|-------------|
| `do_token` | — | DigitalOcean API token |
| `ssh_public_key` | — | SSH public key string |
| `region` | `fra1` | DigitalOcean region |
| `droplet_size` | `s-1vcpu-1gb` | Droplet size slug |
| `droplet_name` | `coturn-fra1` | Droplet hostname |

## Ports / firewall

| Port | Protocol | Purpose |
|------|----------|---------|
| 22 | TCP | SSH |
| 80 | TCP | HTTP (certbot renewal) |
| 443 | TCP | HTTPS (React app) |
| 3478 | TCP + UDP | TURN/STUN |
| 5349 | TCP + UDP | TURN/STUN over TLS |
| 49152–65535 | UDP | TURN relay range |

## Frontend diagnostic tool

The React app at `https://<your-domain>` tests TURN connectivity:

1. Generates time-limited credentials via HMAC-SHA1 (client-side, WebCrypto)
2. Creates a `RTCPeerConnection` with your TURN server
3. Gathers ICE candidates and reports:
   - **relay** — TURN is working
   - **srflx** — STUN reachable, but no relay (check credentials/secret)
   - **host-only** — Server unreachable (check ports/firewall)

### Local development

```bash
cd app
cp .env.example .env      # set TURN_DOMAIN
docker compose -f docker-compose.dev.yml up
# → http://localhost:5173 with hot reload
```

### Production build

```bash
docker compose up --build  # served on ports 80/443
```

## Project structure

```
.
├── deploy.sh                    # Orchestration: terraform → ansible → app
├── terraform/                   # DigitalOcean infrastructure
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
├── ansible/
│   ├── site.yml                 # Main playbook
│   ├── group_vars/all/
│   │   ├── vars.yml             # Public config
│   │   └── secrets.yml.example
│   └── roles/
│       ├── bootstrap/           # Users, SSH hardening, UFW, fail2ban
│       ├── coturn/              # TURN server install + config
│       ├── tls/                 # Let's Encrypt + renewal cron
│       └── docker/              # Docker + Docker Compose
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
| `deploy` | Ansible / infrastructure ops | Yes | Full (passwordless) |
| `app-deploy` | CI/CD docker compose deploys | Yes | Restricted (docker compose only) |
| `coturn` | TURN server process | No | No |
