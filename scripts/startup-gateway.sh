#!/bin/bash
# startup-gateway.sh — runs once at first boot on gateway-vm
#
# What this script does:
#   1. Installs nginx
#   2. Reads daemon private IP from GCP instance metadata
#   3. Writes nginx config that proxies :80 → daemon-vm:3111
#   4. Starts nginx
#
# gateway-vm is the ONLY VM with a public IP.
# It has no iii SDK, no workers, no Python, no Node.js.
# Its sole job is to proxy HTTP requests into the private subnet.

set -euo pipefail
exec > /var/log/startup-gateway.log 2>&1

echo "=== [gateway] startup begin: $(date) ==="

# ── 1. Install nginx ──────────────────────────────────────────────
apt-get update -qq
apt-get install -y -qq nginx curl

# ── 2. Read daemon IP from GCP instance metadata ──────────────────
# Terraform injects daemon_internal_ip as instance metadata.
# We read it here to write the nginx proxy_pass directive.
DAEMON_IP=$(curl -sf \
  -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/daemon_internal_ip" \
  || echo "127.0.0.1")

echo "=== [gateway] daemon IP: ${DAEMON_IP} ==="

# ── 3. Write nginx config ─────────────────────────────────────────
# All traffic on :80 is proxied to iii-http on daemon-vm:3111.
#
# Why proxy_read_timeout 120s?
# inference can take up to 60s on CPU for 512 tokens.
# nginx default timeout is 60s — would cut off valid responses.
# 120s gives a safe margin.
cat > /etc/nginx/sites-available/iii << EOF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass         http://${DAEMON_IP}:3111;
        proxy_http_version 1.1;

        # WebSocket upgrade headers (for any ws traffic on port 80)
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection 'upgrade';

        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;

        proxy_read_timeout  180s;
        proxy_connect_timeout 10s;
        proxy_send_timeout  180s;
    }

    # Health check — does not go to daemon
    location /healthz {
        return 200 'ok\n';
        add_header Content-Type text/plain;
    }
}
EOF

# ── 4. Enable site, disable default ──────────────────────────────
ln -sf /etc/nginx/sites-available/iii /etc/nginx/sites-enabled/iii
rm -f /etc/nginx/sites-enabled/default

# ── 5. Validate config ────────────────────────────────────────────
nginx -t
echo "=== [gateway] nginx config valid ==="

# ── 6. Start nginx ────────────────────────────────────────────────
systemctl enable nginx
systemctl restart nginx

echo "=== [gateway] nginx started ==="

# ── 7. Self-check ─────────────────────────────────────────────────
sleep 2
curl -sf http://localhost/healthz && \
  echo "=== [gateway] healthz OK ===" || \
  echo "=== [gateway] healthz FAILED — check nginx ==="

echo "=== [gateway] startup complete: $(date) ==="
