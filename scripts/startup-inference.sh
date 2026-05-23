#!/bin/bash
# startup-inference.sh — runs once at first boot on inference-vm
#
# What this script does:
#   1. Installs Python and pip dependencies
#   2. Reads III_URL from GCP instance metadata (injected by Terraform)
#   3. Writes the patched inference_worker.py
#   4. Creates and starts a systemd service
#
# KEY CORRECTIONS from earlier version:
#   - worker_name fixed: "math-worker" → "inference-worker"
#     (was a leftover from the original math quickstart template)
#   - max_new_tokens patched: 32000 → 512
#     At ~10 tok/s on CPU, 32000 tokens = ~53 minutes per request.
#     512 tokens = ~1 minute. Useful for demo, won't timeout nginx.
#   - Worker connects via III_URL — does NOT need iii CLI installed.
#     Only the daemon VM runs the iii engine binary.

set -euo pipefail
exec > /var/log/startup-inference.log 2>&1

echo "=== [inference] startup begin: $(date) ==="

# ── 1. System dependencies ────────────────────────────────────────
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv curl git

echo "=== [inference] python: $(python3 --version) ==="

# ── 2. Read III_URL from GCP instance metadata ────────────────────
# Terraform sets this as instance metadata: iii_url = "ws://<daemon-ip>:49134"
# Per iii docs: "The connection string is the only coupling between
# a worker and the iii instance it joins."
III_URL=$(curl -sf \
  -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/iii_url" \
  || echo "ws://localhost:49134")

echo "=== [inference] III_URL=${III_URL} ==="

# ── 2b. Read HF_TOKEN from GCP instance metadata ─────────────────
HF_TOKEN=$(curl -sf \
  -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/hf_token" \
  || echo "")

echo "=== [inference] HF_TOKEN set: $([ -n "$HF_TOKEN" ] && echo yes || echo no) ==="

# ── 3. Project layout ─────────────────────────────────────────────
mkdir -p /opt/iii/workers/inference-worker

# ── 4. Python venv ────────────────────────────────────────────────
python3 -m venv /opt/iii/workers/inference-worker/.venv
source /opt/iii/workers/inference-worker/.venv/bin/activate

# ── 5. Python dependencies ────────────────────────────────────────
# torch CPU-only build — no GPU on this VM.
# CPU wheel is ~200MB vs ~2GB for CUDA — much faster to install.
pip install --upgrade pip -q
pip install torch --index-url https://download.pytorch.org/whl/cpu -q
pip install \
  "iii-sdk==0.11.0" \
  watchfiles \
  transformers \
  accelerate \
  gguf \
  -q

echo "=== [inference] pip install complete ==="

# ── 6. Write inference_worker.py ──────────────────────────────────
cat > /opt/iii/workers/inference-worker/inference_worker.py << 'PYEOF'
import os
from typing import Any, Dict
from iii import InitOptions, Logger, register_worker
from transformers import AutoModelForCausalLM, AutoTokenizer

# Connect to the iii engine via III_URL environment variable.
# III_URL is set from the systemd EnvironmentFile.
# Per iii docs: workers connect over WebSocket — this is the only
# coupling between this worker and the engine.
iii = register_worker(
    os.environ.get("III_URL", "ws://localhost:49134"),
    InitOptions(worker_name="inference-worker"),
    # CORRECTED: was "math-worker" (leftover from quickstart template)
    # worker_name is what appears in iii engine logs and console.
    # The function ID (inference::run_inference) is what routes calls.
)
logger = Logger()

model_id  = "ggml-org/gemma-3-270m-GGUF"
gguf_file = "gemma-3-270m-Q8_0.gguf"

# Model loads here on startup (~270MB download on first boot).
# This takes 3-5 minutes. The systemd service will appear to hang
# during this window — that is expected behaviour.
# Monitor with: journalctl -u inference-worker -f
logger.info("Loading model (first boot: 3-5 min download from HuggingFace)...")

tokenizer = AutoTokenizer.from_pretrained(model_id, gguf_file=gguf_file)
model     = AutoModelForCausalLM.from_pretrained(model_id, gguf_file=gguf_file)

tokenizer.chat_template = (
    "{{ bos_token }}"
    "{%- if messages[0]['role'] == 'system' -%}"
    "    {%- if messages[0]['content'] is string -%}"
    "        {%- set first_user_prefix = messages[0]['content'] + '\n' -%}"
    "    {%- else -%}"
    "        {%- set first_user_prefix = messages[0]['content'][0]['text'] + '\n' -%}"
    "    {%- endif -%}"
    "    {%- set loop_messages = messages[1:] -%}"
    "{%- else -%}"
    "    {%- set first_user_prefix = '' -%}"
    "    {%- set loop_messages = messages -%}"
    "{%- endif -%}"
    "{%- for message in loop_messages -%}"
    "    {%- if (message['role'] == 'user') != (loop.index0 % 2 == 0) -%}"
    "        {{ raise_exception('Conversation roles must alternate user/assistant/...') }}"
    "    {%- endif -%}"
    "    {%- if (message['role'] == 'assistant') -%}"
    "        {%- set role = 'model' -%}"
    "    {%- else -%}"
    "        {%- set role = message['role'] -%}"
    "    {%- endif -%}"
    "    {{ '<start_of_turn>' + role + '\n' + (first_user_prefix if loop.first else '') }}"
    "    {%- if message['content'] is string -%}"
    "        {{ message['content'] | trim }}"
    "    {%- elif message['content'] is iterable -%}"
    "        {%- for item in message['content'] -%}"
    "            {%- if item['type'] == 'image' -%}{{ '<start_of_image>' }}"
    "            {%- elif item['type'] == 'text' -%}{{ item['text'] | trim }}"
    "            {%- endif -%}"
    "        {%- endfor -%}"
    "    {%- else -%}"
    "        {{ raise_exception('Invalid content type') }}"
    "    {%- endif -%}"
    "    {{ '<end_of_turn>\n' }}"
    "{%- endfor -%}"
    "{%- if add_generation_prompt -%}{{ '<start_of_turn>model\n' }}{%- endif -%}"
)

def run_inference_handler(payload: Dict[str, Any]) -> Any:
    messages = payload.get("messages", [])
    logger.info(f"inference::run_inference called with {len(messages)} messages")

    text = tokenizer.apply_chat_template(
        messages, tokenize=False, add_generation_prompt=True
    )
    inputs = tokenizer(text, return_tensors="pt").to(model.device)

    # PATCHED: max_new_tokens 32000 → 512
    # Original value: ~53 minutes on CPU (32000 tokens ÷ ~10 tok/s).
    # 512 tokens: ~1 minute — useful response, won't timeout nginx.
    output = model.generate(
        **inputs,
        max_new_tokens=512,
        repetition_penalty=1.3,
        temperature=0.7,
        do_sample=True,
    )

    result = tokenizer.decode(
        output[0][inputs["input_ids"].shape[-1]:],
        skip_special_tokens=True
    )

    logger.info("inference::run_inference complete")
    return {"response": result}

iii.register_function("inference::run_inference", run_inference_handler)
logger.info("Inference worker started - listening for calls")
print("=== [inference] worker ready - listening for calls ===", flush=True)
PYEOF

echo "=== [inference] inference_worker.py written ==="

# ── 7. Environment file for systemd ──────────────────────────────
mkdir -p /etc/iii
cat > /etc/iii/inference-worker.env << EOF
III_URL=${III_URL}
HF_TOKEN=${HF_TOKEN}
PYTHONUNBUFFERED=1
EOF

# ── 8. systemd service ────────────────────────────────────────────
cat > /etc/systemd/system/inference-worker.service << 'EOF'
[Unit]
Description=iii inference worker (Python / gemma-3-270m)
Documentation=https://iii.dev/docs
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/iii/workers/inference-worker
EnvironmentFile=/etc/iii/inference-worker.env
ExecStart=/opt/iii/workers/inference-worker/.venv/bin/python inference_worker.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=inference-worker

# Model loading takes 3-5 min on first boot.
# Give it 10 min before systemd considers startup failed.
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF

# ── 9. Enable and start ───────────────────────────────────────────
systemctl daemon-reload
systemctl enable inference-worker
systemctl start inference-worker

echo "=== [inference] inference-worker service started ==="
echo "=== [inference] model loading — monitor: journalctl -u inference-worker -f ==="
echo "=== [inference] startup complete: $(date) ==="
