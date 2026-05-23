#!/bin/bash
# startup-caller.sh — runs once at first boot on caller-vm
#
# What this script does:
#   1. Installs Node.js 20 LTS
#   2. Reads III_URL from GCP instance metadata
#   3. Writes package.json, tsconfig.json, worker.ts
#   4. Runs npm install
#   5. Creates and starts a systemd service
#
# The caller-worker does NOT need the iii CLI — only the daemon VM does.
# It connects to the engine via III_URL (WebSocket) using iii-sdk.

set -euo pipefail
exec > /var/log/startup-caller.log 2>&1

echo "=== [caller] startup begin: $(date) ==="

# ── 1. System dependencies ────────────────────────────────────────
apt-get update -qq
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y -qq nodejs git curl

echo "=== [caller] node: $(node --version), npm: $(npm --version) ==="

# ── 2. Read III_URL from GCP instance metadata ────────────────────
III_URL=$(curl -sf \
  -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/iii_url" \
  || echo "ws://localhost:49134")

echo "=== [caller] III_URL=${III_URL} ==="

# ── 3. Project layout ─────────────────────────────────────────────
mkdir -p /opt/iii/workers/caller-worker/src

# ── 4. package.json ───────────────────────────────────────────────
cat > /opt/iii/workers/caller-worker/package.json << 'EOF'
{
  "name": "caller-worker",
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "start": "tsx src/worker.ts"
  },
  "dependencies": {
    "iii-sdk": "0.11.0"
  },
  "devDependencies": {
    "@types/node": "^25.2.2",
    "tsx": "^4.0.0",
    "typescript": "^5.0.0"
  },
  "license": "Apache-2.0"
}
EOF

# ── 5. tsconfig.json ──────────────────────────────────────────────
cat > /opt/iii/workers/caller-worker/tsconfig.json << 'EOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "esModuleInterop": true,
    "strict": true,
    "skipLibCheck": true,
    "outDir": "./dist"
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist"]
}
EOF

# ── 6. worker.ts ─────────────────────────────────────────────────
# Taken verbatim from the source project (caller-worker/src/worker.ts)
# with no changes — the original code is correct.
cat > /opt/iii/workers/caller-worker/src/worker.ts << 'EOF'
import { Logger, registerWorker } from 'iii-sdk';

// III_URL is set in the systemd EnvironmentFile (/etc/iii/caller-worker.env)
// and injected via GCP instance metadata by Terraform.
// Per iii docs: this WebSocket URL is the only coupling between
// this worker and the engine it joins.
const iii = registerWorker(process.env.III_URL ?? 'ws://localhost:49134');
const logger = new Logger();

// Registered function 1: inference::get_response
// Calls inference::run_inference on inference-worker via iii RPC.
// The engine routes this call — caller-worker never talks to
// inference-worker directly.
iii.registerFunction(
  'inference::get_response',
  async (payload: { messages: Record<string, any> } & Record<string, any>) => {
    logger.info('inference::get_response called', payload);

    const result = await iii.trigger({
      function_id: 'inference::run_inference',
      payload,
      timeoutMs: 120000,
    });

    return {
      ...result,
      success: "Workers connected and interoperating.",
    };
  },
);

// Registered function 2: http::run_inference_over_http
// Bound to POST /v1/chat/completions by the HTTP trigger below.
// iii-http on the daemon receives the HTTP request and routes it here.
iii.registerFunction(
  'http::run_inference_over_http',
  async (payload: { body: { messages: Record<string, any> } & Record<string, any> }) => {
    const result = await iii.trigger({
      function_id: 'inference::get_response',
      payload: payload.body,
      timeoutMs: 120000,
    });
    logger.info("http::run_inference_over_http complete");
    return {
      status_code: 200,
      body: { result },
      headers: { 'Content-Type': 'application/json' },
    };
  },
);

// HTTP trigger: binds http::run_inference_over_http to POST /v1/chat/completions
// iii-http worker (running on daemon-vm) owns the HTTP socket on :3111.
// When a request arrives, iii-http fires this trigger and routes the
// invocation to this function via the engine.
iii.registerTrigger({
  type: 'http',
  function_id: 'http::run_inference_over_http',
  config: { api_path: '/v1/chat/completions', http_method: 'POST' },
});

logger.info('Caller worker started - listening for calls');
EOF

# ── 7. npm install ────────────────────────────────────────────────
cd /opt/iii/workers/caller-worker
npm install 2>&1
echo "=== [caller] npm install complete ==="

# ── 8. Environment file for systemd ──────────────────────────────
mkdir -p /etc/iii
cat > /etc/iii/caller-worker.env << EOF
III_URL=${III_URL}
NODE_ENV=production
EOF

# ── 9. systemd service ────────────────────────────────────────────
cat > /etc/systemd/system/caller-worker.service << 'EOF'
[Unit]
Description=iii caller worker (TypeScript / Node.js)
Documentation=https://iii.dev/docs
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/iii/workers/caller-worker
EnvironmentFile=/etc/iii/caller-worker.env
ExecStart=/usr/bin/node node_modules/.bin/tsx src/worker.ts
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=caller-worker

[Install]
WantedBy=multi-user.target
EOF

# ── 10. Enable and start ──────────────────────────────────────────
systemctl daemon-reload
systemctl enable caller-worker
systemctl start caller-worker

echo "=== [caller] caller-worker service started ==="
echo "=== [caller] startup complete: $(date) ==="
