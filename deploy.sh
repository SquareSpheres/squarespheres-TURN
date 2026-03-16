#!/usr/bin/env bash
# Usage:
#   ./deploy.sh              # full run: terraform → DNS → cloud-init → app
#   ./deploy.sh terraform    # provision droplet only, print IP, exit
#   ./deploy.sh bootstrap    # wait for cloud-init to finish (reads IP from terraform state)
#   ./deploy.sh app          # build + deploy React app only
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-all}"
# deploy user key — used for infrastructure operations
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
# app-deploy user key — used for CI/CD docker compose updates (restricted sudo)
APP_DEPLOY_KEY="${APP_DEPLOY_KEY:-$HOME/.ssh/id_ed25519_app_deploy}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
get_droplet_ip() {
  cd "$SCRIPT_DIR/terraform"
  terraform output -raw droplet_ip 2>/dev/null
}

get_turn_domain() {
  cd "$SCRIPT_DIR/terraform"
  terraform output -raw turn_domain 2>/dev/null
}

wait_for_ssh() {
  local ip="$1"
  local user="$2"
  echo "==> Waiting for SSH on $ip..."
  until ssh \
    -i "$SSH_KEY" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=5 \
    -o BatchMode=yes \
    "$user"@"$ip" true 2>/dev/null; do
    echo "    Not ready yet, retrying in 5 s..."
    sleep 5
  done
  echo "==> SSH is up."
}

wait_for_dns() {
  local domain="$1"
  local expected_ip="$2"
  echo "==> Waiting for DNS: $domain -> $expected_ip"
  until [ "$(dig +short "$domain" A | tail -1)" = "$expected_ip" ]; do
    echo "    DNS not propagated yet, checking again in 15 s..."
    sleep 15
  done
  echo "==> DNS resolved."
}

run_terraform() {
  echo "==> Terraform: initialising..."
  cd "$SCRIPT_DIR/terraform"
  terraform init -input=false
  echo "==> Terraform: planning..."
  terraform plan -input=false
  echo "==> Terraform: applying..."
  terraform apply -input=false -auto-approve
  local ip
  ip=$(terraform output -raw droplet_ip)
  echo ""
  echo "==> Droplet IP: $ip"
  cd "$SCRIPT_DIR"
  echo "$ip"
}

wait_for_cloud_init() {
  local ip="$1"
  echo "==> Waiting for cloud-init to finish on $ip..."
  wait_for_ssh "$ip" "deploy"
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new \
    deploy@"$ip" 'cloud-init status --wait && cloud-init status --long'
  echo "==> Cloud-init complete."
}

run_app_deploy() {
  local ip="$1"
  echo "==> Deploying app to $ip (user: app-deploy)..."

  # Write .env for docker compose (/opt/app is owned by app-deploy — no sudo needed)
  ssh -i "$APP_DEPLOY_KEY" -o StrictHostKeyChecking=accept-new app-deploy@"$ip" \
    "echo 'TURN_DOMAIN=$TURN_DOMAIN' > /opt/app/.env"

  # Sync app directory (excluding node_modules and local build artifacts)
  rsync -av --delete \
    --exclude 'node_modules/' \
    --exclude 'dist/' \
    --exclude '.env' \
    -e "ssh -i $APP_DEPLOY_KEY -o StrictHostKeyChecking=accept-new" \
    "$SCRIPT_DIR/app/" app-deploy@"$ip":/opt/app/

  # Build and start on the server
  ssh -i "$APP_DEPLOY_KEY" -o StrictHostKeyChecking=accept-new app-deploy@"$ip" \
    "sudo /usr/bin/docker compose -f /opt/app/docker-compose.yml up --build -d"

  echo "==> App deployed."
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------
case "$MODE" in

  terraform)
    DROPLET_IP=$(run_terraform | tail -1)
    TURN_DOMAIN=$(get_turn_domain)
    echo ""
    echo "DNS A record for '$TURN_DOMAIN' -> $DROPLET_IP created via Cloudflare."
    echo "Next: ./deploy.sh bootstrap"
    ;;

  bootstrap)
    DROPLET_IP=$(get_droplet_ip)
    TURN_DOMAIN=$(get_turn_domain)
    if [ -z "$DROPLET_IP" ]; then
      echo "ERROR: Run ./deploy.sh terraform first."
      exit 1
    fi
    wait_for_dns "$TURN_DOMAIN" "$DROPLET_IP"
    wait_for_cloud_init "$DROPLET_IP"
    echo "==> Done! Run ./deploy.sh app to deploy the frontend."
    ;;

  app)
    DROPLET_IP=$(get_droplet_ip)
    TURN_DOMAIN=$(get_turn_domain)
    if [ -z "$DROPLET_IP" ]; then
      echo "ERROR: could not read droplet IP from Terraform state. Run ./deploy.sh terraform first."
      exit 1
    fi
    echo "==> Using existing droplet IP: $DROPLET_IP"
    run_app_deploy "$DROPLET_IP"
    echo ""
    echo "==> Done! Browse to https://$TURN_DOMAIN"
    ;;

  all)
    DROPLET_IP=$(run_terraform | tail -1)
    TURN_DOMAIN=$(get_turn_domain)
    wait_for_dns "$TURN_DOMAIN" "$DROPLET_IP"
    wait_for_cloud_init "$DROPLET_IP"
    run_app_deploy "$DROPLET_IP"
    echo ""
    echo "==> Done!"
    echo "    Droplet IP : $DROPLET_IP"
    echo "    App        : https://$TURN_DOMAIN"
    ;;

  *)
    echo "Usage: $0 [terraform|bootstrap|app|all]"
    exit 1
    ;;

esac
