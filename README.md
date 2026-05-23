# llm-inferencing — GCP Deployment

Deploys the `iii` distributed inference system across four private GCP VMs.
A Python worker loads `gemma-3-270m` and exposes inference over RPC.
A TypeScript worker bridges HTTP into that RPC. Everything lives in a private
subnet — only the nginx gateway has a public IP.

---

## Architecture

```
                          Internet
                             │
                    POST /v1/chat/completions
                             │
                ┌────────────▼──────────────┐
                │        gateway-vm          │  e2-micro · PUBLIC IP
                │       nginx :80            │
                └────────────┬──────────────┘
                             │ proxy → daemon-vm:3111
        ┌────────────────────────────────────────────────────┐
        │                VPC  10.0.0.0/16                    │
        │              Subnet 10.0.1.0/24                    │
        │                                                    │
        │  ┌─────────────────────────────────────────────┐   │
        │  │              iii-daemon-vm                   │   │
        │  │  e2-small · private only                     │   │
        │  │                                              │   │
        │  │  iii engine  :49134  (RPC WebSocket broker)  │   │
        │  │  iii-http    :3111   (HTTP → function router)│   │
        │  │  iii-state   SQLite  (/opt/iii/data/)        │   │
        │  │  iii-queue   builtin                         │   │
        │  └──────────┬──────────────────┬────────────────┘   │
        │             │  ws:49134        │  ws:49134           │
        │   ┌─────────▼────────┐  ┌──────▼────────────────┐   │
        │   │   caller-vm      │  │    inference-vm         │   │
        │   │   e2-micro       │  │    e2-standard-2        │   │
        │   │   Node.js / tsx  │  │    Python + torch       │   │
        │   │   caller-worker  │  │    inference-worker      │   │
        │   └──────────────────┘  └───────────────────────┘   │
        │                                                    │
        │   Cloud NAT — outbound internet only               │
        │   (pip install, npm install, HuggingFace download) │
        └────────────────────────────────────────────────────┘

Firewall:
  internet  → gateway-vm:80       ✓  nginx
  subnet    → daemon-vm:49134     ✓  RPC WebSocket (workers connect here)
  gateway   → daemon-vm:3111      ✓  iii-http (nginx proxies here)
  IAP range → all VMs:22          ✓  SSH via gcloud (no bastion needed)
  internet  → worker VMs          ✗  blocked
```

---

## How a request flows through the system

```
curl POST /v1/chat/completions { messages: [...] }
  → nginx (gateway-vm :80)
  → iii-http (daemon-vm :3111)
  → http::run_inference_over_http  [caller-worker on caller-vm]
  → iii.trigger('inference::get_response')  [RPC via engine :49134]
  → inference::get_response  [still on caller-worker]
  → iii.trigger('inference::run_inference')  [RPC via engine :49134]
  → run_inference_handler(payload)  [inference-worker on inference-vm]
  → gemma-3-270m generates text
  → result propagates back up the chain
  → JSON response to curl
```

No worker calls another worker directly. All calls go through the iii engine,
which routes them based on which worker currently has the function registered.

---

## Design decisions

**Cloud NAT instead of public IPs on worker VMs.**
Cloud NAT gives private VMs outbound internet (pip, npm, HuggingFace) without
accepting any inbound connections. The worker VMs are unreachable regardless of
what ports their processes bind to.

**iii daemon on its own VM, not co-located with a worker.**
The daemon is the single coordination point for all RPC routing. Keeping it
isolated means a worker crash cannot take down the broker. Workers reconnect
automatically (systemd `Restart=always`) and re-register their functions.

**config.yaml declares built-in workers only — not inference-worker or caller-worker.**
Per the iii docs: workers connect to the engine over WebSocket via `III_URL`.
`worker_path` in config.yaml is a local-development convenience that tells the
iii CLI to spawn the worker as a subprocess. In this deployment each worker runs
on its own VM and connects independently — no config entry is needed or correct.

**e2-standard-2 for inference-vm.**
torch CPU build: ~1.5GB. gemma-3-270m Q8 weights: ~270MB. Activation memory
during inference: ~1-2GB. Peak total: ~4GB. e2-micro (1GB) and e2-small (2GB)
OOM-kill the process. The source project's `iii.worker.yaml` has `memory: 8192`
as a hint — e2-standard-2 (8GB) matches this.

**max_new_tokens patched 32000 → 512.**
At ~10 tokens/second on CPU, 32000 tokens = ~53 minutes per request — longer
than any HTTP timeout. 512 tokens gives a useful response in ~1 minute.

---

## Prerequisites

1. GCP account with billing enabled ($300 free credit is sufficient)
2. `gcloud` CLI installed and authenticated
3. Terraform >= 1.3 installed

```bash
# Authenticate
gcloud auth login
gcloud auth application-default login

# Enable required APIs (run once per project)
gcloud services enable \
  compute.googleapis.com \
  iap.googleapis.com \
  logging.googleapis.com \
  --project=YOUR_PROJECT_ID
```

---

## Deploy from scratch

### 1. Configure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set your project_id
```

### 2. Deploy

```bash
terraform init
terraform plan    # review what will be created
terraform apply   # type 'yes' — takes ~3 minutes
```

Terraform outputs the gateway public IP and a ready-made curl command.

### 3. Wait for workers

The inference-worker downloads ~270MB from HuggingFace on first boot.
Allow **8–10 minutes** after `terraform apply` before testing.

---

## Step-by-step testing

Test each layer independently. This isolates exactly where a failure is.

### Layer 1 — Network

```bash
# VPC exists
gcloud compute networks describe iii-vpc

# All 5 firewall rules present
gcloud compute firewall-rules list --filter="network=iii-vpc"
# Expected rules: allow-http-ingress, allow-iii-rpc, allow-iii-http,
#                 allow-iap-ssh, allow-internal

# Cloud NAT configured
gcloud compute routers nats describe iii-nat \
  --router=iii-router --region=us-central1
```

### Layer 2 — VMs booted

```bash
# All four VMs running
gcloud compute instances list

# Check startup script completed on each VM
gcloud compute ssh iii-daemon-vm --tunnel-through-iap --zone=us-central1-a \
  --command="tail -3 /var/log/startup-daemon.log"
# Expected last line: "=== [daemon] startup complete: ..."
```

### Layer 3 — iii engine up

```bash
gcloud compute ssh iii-daemon-vm --tunnel-through-iap --zone=us-central1-a

# On the VM:
systemctl status iii-engine          # should be: active (running)
ss -tlnp | grep -E '49134|3111'      # both ports must be listed
journalctl -u iii-engine -n 30       # check for errors
```

### Layer 4 — Workers connected

```bash
# inference-worker — wait for model load
gcloud compute ssh inference-vm --tunnel-through-iap --zone=us-central1-a \
  --command="journalctl -u inference-worker -n 40 --no-pager"
# Wait for: "Inference worker started - listening for calls"

# caller-worker
gcloud compute ssh caller-vm --tunnel-through-iap --zone=us-central1-a \
  --command="journalctl -u caller-worker -n 20 --no-pager"
# Wait for: "Caller worker started - listening for calls"
```

### Layer 5 — nginx health check

```bash
GATEWAY_IP=$(cd terraform && terraform output -raw gateway_external_ip)
curl http://$GATEWAY_IP/healthz
# Expected: ok
```

### Layer 6 — End-to-end inference

```bash
GATEWAY_IP=$(cd terraform && terraform output -raw gateway_external_ip)

curl -X POST http://$GATEWAY_IP/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "What is 2+2?"}]}' \
  --max-time 120
```

Takes 30–90 seconds. Sample response:

```json
{
  "result": {
    "result": "2 + 2 = 4",
    "success": "Workers connected and interoperating."
  }
}
```

### Layer 7 — Reproducibility

```bash
terraform destroy   # tears everything down (~2 min)
terraform apply     # rebuilds from scratch (~3 min + 8 min worker startup)
# Re-run the curl — must work identically
```

---

## Troubleshooting

**502 Bad Gateway from curl**
nginx is up but cannot reach iii-http on daemon-vm.
```bash
# Is the engine running and port 3111 listening?
gcloud compute ssh iii-daemon-vm --tunnel-through-iap --zone=us-central1-a \
  --command="systemctl status iii-engine && ss -tlnp | grep 3111"

# Does nginx have the correct daemon IP?
gcloud compute ssh gateway-vm --tunnel-through-iap --zone=us-central1-a \
  --command="grep proxy_pass /etc/nginx/sites-available/iii"

# Is the firewall rule in place?
gcloud compute firewall-rules describe allow-iii-http
```

**curl returns 200 but hangs for minutes then times out**
inference-worker is still loading the model. Check:
```bash
gcloud compute ssh inference-vm --tunnel-through-iap --zone=us-central1-a \
  --command="journalctl -u inference-worker -f"
# Wait for: "Inference worker started - listening for calls"
```

**Workers show "connection refused" in logs**
`III_URL` is wrong or the RPC firewall rule is missing.
```bash
# What III_URL did each worker get?
gcloud compute ssh caller-vm --tunnel-through-iap --zone=us-central1-a \
  --command="cat /etc/iii/caller-worker.env"

# Is port 49134 reachable from caller-vm?
gcloud compute ssh caller-vm --tunnel-through-iap --zone=us-central1-a \
  --command="curl -sv telnet://\$(grep III_URL /etc/iii/caller-worker.env | cut -d'/' -f3) 2>&1 | head -5"
```

**inference-vm OOM killed**
```bash
gcloud compute ssh inference-vm --tunnel-through-iap --zone=us-central1-a \
  --command="dmesg | grep -i 'killed process'"
# Fix: upgrade inference-vm to e2-standard-4 in vms.tf
```

---

## Production hardening

**Authentication.** The `/v1/chat/completions` endpoint has no auth. In production
add an `Authorization: Bearer <token>` check in nginx (`auth_request` module) or
put Cloud Armor in front of a Global HTTPS Load Balancer.

**TLS.** Currently plain HTTP. Add a Google-managed SSL certificate on a Global
HTTPS Load Balancer. Zero cost for the certificate itself.

**Single point of failure.** The iii daemon VM is the RPC broker. If the VM fails,
workers disconnect. `Restart=always` handles process crashes but not VM failure.
In production run the daemon in a Managed Instance Group with a health check, or
move to GKE where it can be rescheduled automatically.

**Secrets.** `III_URL` is passed as GCP instance metadata, readable by anyone with
VM access. In production store sensitive config in Secret Manager and grant the
service account `secretmanager.secretAccessor`.

**CORS.** `config.yaml` has `allowed_origins: ['*']`. Lock to specific origins
before public exposure.

---

## Scaling to a 100x larger model

A 270M parameter model runs on CPU with 8GB RAM. A 27B parameter model changes
every layer of this stack.

**Hardware.** You need a GPU — an A100 (80GB) or H100. GCP's `a2-highgpu-1g`
costs ~$3.67/hr. You'd provision it on-demand for inference and shut it down when
idle, rather than running it 24/7 like this deployment does.

**Inference server.** Replace the `transformers` generate loop with vLLM or TGI
(Text Generation Inference). These support continuous batching — multiple requests
processed simultaneously on one GPU. The current implementation processes one
request at a time and blocks the worker thread during generation.

**Model loading.** A 27B Q8 model is ~27GB on disk. Loading takes 3–5 minutes.
You would store weights on a persistent disk attached to the inference VM, or in
Cloud Storage with a warm-up script. You would never terminate the inference VM
between requests — cold-start time is too expensive.

**The iii architecture helps.** The RPC interface between caller-worker and
inference-worker is an abstraction boundary. You can replace the inference
implementation (bigger model, vLLM backend, batching) without changing the
caller-worker or the HTTP API contract. The routing layer stays the same.
