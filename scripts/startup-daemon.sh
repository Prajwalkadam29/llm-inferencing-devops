#!/bin/bash
# startup-daemon.sh — runs once at first boot on iii-daemon-vm
#
# What this script does:
#   1. Installs the iii engine using the official install script
#   2. Writes config.yaml (built-in workers only — NO worker_path entries)
#   3. Creates a systemd service that starts the engine
#
# KEY CORRECTION from earlier version:
#   - Install command is the real one from iii.dev/install
#   - Engine is started with: iii --config /opt/iii/config.yaml
#     NOT "iii start" (which doesn't exist)
#   - config.yaml does NOT include worker_path for inference-worker
#     or caller-worker. Per the iii docs, workers connect to the engine
#     over WebSocket via III_URL — the engine does not spawn them.
#     worker_path is a local-development convenience only.

set -euo pipefail
exec > /var/log/startup-daemon.log 2>&1

echo "=== [daemon] startup begin: $(date) ==="

# ── 1. System dependencies ────────────────────────────────────────
apt-get update -qq
apt-get install -y -qq curl git

echo "=== [daemon] system deps installed ==="

# ── 2. Install iii engine ─────────────────────────────────────────
# Startup scripts run before a full user environment is loaded.
# HOME and USER are unset — the iii install script needs HOME to
# decide where to place the binary. Set them explicitly before
# calling the installer.
export HOME=/root
export USER=root
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

# Official install command from https://iii.dev/install
# Installs the iii binary to /usr/local/bin (or ~/.local/bin).
# The script auto-detects the platform and downloads the correct binary.
curl -fsSL https://install.iii.dev/iii/main/install.sh | sh


# Verify install succeeded — fail fast if not
iii --version
echo "=== [daemon] iii installed: $(iii --version) ==="

# Symlink to /usr/local/bin so systemd and all users can find it
if [ -f "$HOME/.local/bin/iii" ] && [ ! -f "/usr/local/bin/iii" ]; then
  ln -sf "$HOME/.local/bin/iii" /usr/local/bin/iii
fi

if [ -f "$HOME/.local/bin/iii-init" ] && [ ! -f "/usr/local/bin/iii-init" ]; then
  ln -sf "$HOME/.local/bin/iii-init" /usr/local/bin/iii-init
fi

if [ -f "$HOME/.local/bin/iii-worker" ] && [ ! -f "/usr/local/bin/iii-worker" ]; then
  ln -sf "$HOME/.local/bin/iii-worker" /usr/local/bin/iii-worker
fi

# ── 3. Project directory ──────────────────────────────────────────
mkdir -p /opt/iii/data
mkdir -p /opt/iii/.iii

# ── 4. Write .iii/project.ini ─────────────────────────────────────
cat > /opt/iii/.iii/project.ini << 'EOF'
[project]
project_id=ae9213f8-bb31-411c-a121-d25172ac9820
project_name=llm-inferencing
source=quickstart
EOF

# ── 5. Write config.yaml ──────────────────────────────────────────
# IMPORTANT: This file declares ONLY the built-in engine workers.
# It does NOT declare inference-worker or caller-worker.
#
# Why? From the iii docs:
#   "Workers only need a WebSocket connection to the iii engine.
#    They can run locally, in the cloud, replicated in kubernetes,
#    or anywhere else."
#   "The connection string is the only coupling between a worker
#    and the iii instance it joins."
#
# inference-worker and caller-worker run on their own VMs and
# connect via III_URL=ws://<this-vm-ip>:49134. The engine registers
# them dynamically when they connect — no config entry needed.
#
# worker_path is only for local development where the iii CLI
# spawns worker processes as children of the engine process.
#
# iii-http host is 0.0.0.0 (not 127.0.0.1 like the original).
# nginx on gateway-vm reaches it via this VM's private IP,
# so it must bind on all interfaces, not just localhost.
# The firewall rule "allow-iii-http" restricts access to
# gateway-vm only — binding 0.0.0.0 is safe here.
cat > /opt/iii/config.yaml << 'EOF'
workers:
  - name: iii-observability
    config:
      enabled: true
      service_name: iii
      exporter: memory
      memory_max_spans: 10000
      metrics_enabled: true
      metrics_exporter: memory
      logs_enabled: true
      logs_exporter: memory
      logs_console_output: true
      sampling_ratio: 1.0

  - name: iii-queue
    config:
      adapter:
        name: builtin

  - name: iii-state
    config:
      adapter:
        name: kv
        config:
          store_method: file_based
          file_path: /opt/iii/data/state_store.db

  - name: iii-http
    config:
      port: 3111
      host: 0.0.0.0
      default_timeout: 120000
      concurrency_request_limit: 1024
      cors:
        allowed_origins:
          - '*'
        allowed_methods:
          - GET
          - POST
          - PUT
          - DELETE
          - OPTIONS
EOF

echo "=== [daemon] config.yaml written ==="

# ── 6. systemd service ────────────────────────────────────────────
# ExecStart uses: iii --config /opt/iii/config.yaml
# This is the correct command per iii.dev/install and the GitHub README.
# "iii start" does NOT exist — we confirmed this from the docs.
cat > /etc/systemd/system/iii-engine.service << 'EOF'
[Unit]
Description=iii engine daemon
Documentation=https://iii.dev/docs
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/iii
Environment="PATH=/root/.local/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=/usr/local/bin/iii --config /opt/iii/config.yaml
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=iii-engine

[Install]
WantedBy=multi-user.target
EOF

# ── 7. Enable and start ───────────────────────────────────────────
systemctl daemon-reload
systemctl enable iii-engine
systemctl start iii-engine

echo "=== [daemon] iii-engine service started ==="

# ── 8. Wait for ports to be ready ────────────────────────────────
# Port 49134: RPC WebSocket (workers connect here)
# Port 3111:  iii-http (nginx proxies here)
for port in 49134 3111; do
  echo "=== [daemon] waiting for port $port... ==="
  for i in $(seq 1 30); do
    if ss -tlnp | grep -q ":${port}"; then
      echo "=== [daemon] port $port UP (attempt $i) ==="
      break
    fi
    sleep 2
  done
done

echo "=== [daemon] startup complete: $(date) ==="
