#cloud-config

users:
  - name: deploy
    shell: /bin/bash
    groups: [sudo]
    lock_passwd: false
    passwd: "${deploy_sudo_password_hash}"
    ssh_authorized_keys:
      - "${deploy_pubkey}"

  - name: app-deploy
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - "${app_deploy_pubkey}"

write_files:
  # SSH hardening drop-in (avoids touching /etc/ssh/sshd_config directly)
  - path: /etc/ssh/sshd_config.d/99-hardening.conf
    permissions: "0644"
    content: |
      PermitRootLogin no
      PasswordAuthentication no
      PubkeyAuthentication yes
      ChallengeResponseAuthentication no
      MaxAuthTries 3
      LoginGraceTime 30
      X11Forwarding no

  # Sudoers for deploy (full sudo, password required)
  - path: /etc/sudoers.d/deploy
    permissions: "0440"
    content: "deploy ALL=(ALL) ALL\n"

  # Sudoers for app-deploy (passwordless, restricted to docker compose on /opt/app)
  - path: /etc/sudoers.d/app-deploy
    permissions: "0440"
    content: "app-deploy ALL=(ALL) NOPASSWD: /usr/bin/docker compose -f /opt/app/docker-compose.yml *\n"

  # turnserver.conf template - relay-ip placeholder filled by helper script
  - path: /etc/turnserver.conf.tpl
    permissions: "0600"
    content: |
      listening-port=${turn_listening_port}
      tls-listening-port=${turn_tls_listening_port}
      realm=${turn_realm}
      use-auth-secret
      static-auth-secret=${turn_static_secret}
      relay-ip=RELAY_IP_PLACEHOLDER
      external-ip=RELAY_IP_PLACEHOLDER
      min-port=${turn_min_port}
      max-port=${turn_max_port}
      no-multicast-peers
      denied-peer-ip=0.0.0.0-0.255.255.255
      denied-peer-ip=10.0.0.0-10.255.255.255
      denied-peer-ip=100.64.0.0-100.127.255.255
      denied-peer-ip=127.0.0.0-127.255.255.255
      denied-peer-ip=169.254.0.0-169.254.255.255
      denied-peer-ip=172.16.0.0-172.31.255.255
      denied-peer-ip=192.0.0.0-192.0.0.255
      denied-peer-ip=192.168.0.0-192.168.255.255
      denied-peer-ip=198.18.0.0-198.19.255.255
      denied-peer-ip=198.51.100.0-198.51.100.255
      denied-peer-ip=203.0.113.0-203.0.113.255
      denied-peer-ip=240.0.0.0-255.255.255.255
      log-file=/var/log/turnserver/turn.log
      simple-log

  # Helper: fetch IP from metadata API, assemble turnserver.conf (no TLS yet)
  - path: /usr/local/sbin/configure-turnserver.sh
    permissions: "0700"
    content: |
      #!/bin/bash
      set -euo pipefail
      RESERVED_IP=$(curl -sf http://169.254.169.254/metadata/v1/floating_ip/ipv4/ip_address 2>/dev/null)
      PUBLIC_IP=${RESERVED_IP:-$(curl -sf http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address)}
      sed "s/RELAY_IP_PLACEHOLDER/$PUBLIC_IP/g" /etc/turnserver.conf.tpl > /etc/turnserver.conf
      chown root:turnserver /etc/turnserver.conf
      chmod 640 /etc/turnserver.conf

  # Helper: append TLS cert lines to turnserver.conf after certbot runs
  - path: /usr/local/sbin/append-tls-to-turnserver.sh
    permissions: "0700"
    content: |
      #!/bin/bash
      set -euo pipefail
      DOMAIN="${turn_realm}"
      printf '\ncert=/etc/letsencrypt/live/%s/fullchain.pem\npkey=/etc/letsencrypt/live/%s/privkey.pem\n' \
        "$DOMAIN" "$DOMAIN" >> /etc/turnserver.conf

  # Certbot renewal cron (harmless until certs exist)
  - path: /etc/cron.d/certbot-renew
    permissions: "0644"
    content: |
      0 */12 * * * root certbot renew \
        --pre-hook 'cd /opt/app && /usr/bin/docker compose stop 2>/dev/null || true' \
        --post-hook 'cd /opt/app && /usr/bin/docker compose start 2>/dev/null || true; systemctl restart coturn' \
        >> /var/log/letsencrypt/renew.log 2>&1

runcmd:
  # 1. Base packages
  - apt-get update -y
  - apt-get install -y ufw sudo fail2ban

  # 2. SSH hardening
  - systemctl restart sshd

  # 3. UFW
  - ufw --force reset
  - ufw default deny incoming
  - ufw default allow outgoing
  - ufw allow 22/tcp
  - ufw allow 80/tcp
  - ufw allow 443/tcp
  - ufw allow ${turn_listening_port}/tcp
  - ufw allow ${turn_listening_port}/udp
  - ufw allow ${turn_tls_listening_port}/tcp
  - ufw allow ${turn_tls_listening_port}/udp
  - ufw allow ${turn_min_port}:${turn_max_port}/udp
  - ufw --force enable

  # 4. coturn - install, configure (no TLS yet), start
  - apt-get install -y coturn
  - sed -i 's/^#\?TURNSERVER_ENABLED.*/TURNSERVER_ENABLED=1/' /etc/default/coturn
  - mkdir -p /var/log/turnserver
  - chown turnserver:turnserver /var/log/turnserver
  - /usr/local/sbin/configure-turnserver.sh
  - systemctl enable coturn
  - systemctl start coturn

  # 5. TLS - stop coturn, get cert, set permissions, append cert paths, restart
  - systemctl stop coturn
  - apt-get install -y certbot dnsutils
  - >
    until [ "$(dig +short ${turn_realm} A | tail -1)" = "${reserved_ip}" ];
    do echo "Waiting for DNS to point to this IP..."; sleep 15; done
  - >
    certbot certonly --standalone
    -d ${turn_realm}
    --email ${certbot_email}
    --non-interactive
    --agree-tos
    ${certbot_staging ? "--staging" : ""}
  - groupadd -f ssl-cert
  - usermod -aG ssl-cert turnserver
  - chown -R root:ssl-cert /etc/letsencrypt/live/${turn_realm}
  - chmod 750 /etc/letsencrypt/live/${turn_realm}
  - chmod 640 /etc/letsencrypt/live/${turn_realm}/fullchain.pem
  - chmod 640 /etc/letsencrypt/live/${turn_realm}/privkey.pem
  - chown -R root:ssl-cert /etc/letsencrypt/archive/${turn_realm}
  - chmod -R 750 /etc/letsencrypt/archive/${turn_realm}
  - /usr/local/sbin/append-tls-to-turnserver.sh
  - systemctl start coturn

  # 6. Docker CE from official repo
  - apt-get install -y ca-certificates curl gnupg
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  - chmod a+r /etc/apt/keyrings/docker.asc
  - >
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc]
    https://download.docker.com/linux/ubuntu
    $(. /etc/os-release && echo $VERSION_CODENAME) stable"
    > /etc/apt/sources.list.d/docker.list
  - apt-get update -y
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  - apt-get remove -y --purge nginx nginx-common 2>/dev/null || true
  - systemctl enable docker
  - systemctl start docker

  # 7. App deploy directory
  - mkdir -p /opt/app
  - chown app-deploy:app-deploy /opt/app
  - chmod 755 /opt/app

  # 8. Cleanup - remove template file containing the static secret
  - rm -f /etc/turnserver.conf.tpl

final_message: "cloud-init bootstrap complete"
