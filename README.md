# llm-inferencing: Distributed Inference on GCP

Deploys the `iii` quickstart project across four private GCP VMs using Terraform.
A Python worker loads `gemma-3-270m` (GGUF Q8) and exposes inference over RPC.
A TypeScript worker bridges HTTP requests into that RPC chain and returns JSON.
Everything runs inside a private subnet. Only the nginx gateway has a public IP.
Workers communicate exclusively through the iii engine over WebSocket RPC and are
never reachable from the public internet.

---

## Workers

| Worker | Language | Function | Does |
|---|---|---|---|
| `inference-worker` | Python | `inference::run_inference` | Loads `gemma-3-270m` (GGUF Q8) via `transformers`, applies the chat template to `messages`, and returns the decoded model output. |
| `caller-worker` | TypeScript | `inference::get_response` | Calls `inference::run_inference` with the incoming `messages` payload and returns the result. |
| `caller-worker` | TypeScript | `http::run_inference_over_http` | HTTP trigger bound to `POST /v1/chat/completions`; forwards the request body to `inference::get_response` and returns a JSON HTTP response. |

For more details on the iii framework: https://iii.dev/docs

---

## Architecture

```
                            Internet
                               |
                               | HTTP :80
                               |
                    +----------v----------+
                    |     gateway-vm      |
                    |     e2-micro        |
                    |     PUBLIC IP       |
                    |     nginx :80       |
                    +----------+---------+
                               |
                               | proxy_pass :3111
                               |
+----------------------------------------------------------------------+
|                      GCP us-central1-a                               |
|                   VPC: iii-vpc  Subnet: 10.0.1.0/24                  |
|                                                                      |
|                    +---------------------------+                     |
|                    |      iii-daemon-vm        |                     |
|                    |      e2-small             |                     |
|                    |      PRIVATE ONLY         |                     |
|                    |                           |                     |
|                    |  iii-http      :3111      |                     |
|                    |  RPC broker    :49134     |                     |
|                    |  iii-state     SQLite     |                     |
|                    |  iii-queue     builtin    |                     |
|                    +----------+----------------+                     |
|                               |                                      |
|              WebSocket :49134 | WebSocket :49134                     |
|               +---------------+---------------+                      |
|               |                               |                      |
|    +----------v----------+     +--------------v---------+            |
|    |     caller-vm       |     |      inference-vm      |            |
|    |     e2-micro        |     |      e2-standard-2     |            |
|    |     PRIVATE ONLY    |     |      PRIVATE ONLY      |            |
|    |                     |     |                        |            |
|    |  caller-worker      |     |  inference-worker      |            |
|    |  TypeScript/Node.js |     |  Python + torch        |            |
|    |                     |     |  gemma-3-270m GGUF Q8  |            |
|    +---------------------+     +------------------------+            |
|                                                                      |
|   Cloud NAT: outbound internet only                                  |
|   (pip install, npm install, HuggingFace model download)             |
+----------------------------------------------------------------------+

Firewall rules:
  internet  --> gateway-vm:80      ALLOW   (nginx entry point)
  subnet    --> daemon-vm:49134    ALLOW   (RPC WebSocket, workers connect here)
  gateway   --> daemon-vm:3111     ALLOW   (iii-http, nginx proxies here)
  IAP range --> all VMs:22         ALLOW   (SSH via gcloud, no bastion needed)
  internet  --> worker VMs         BLOCK   (no public IP, no inbound)
```

---

## Request Flow

```
curl POST /v1/chat/completions  {"messages": [...]}
  |
  +--> nginx (gateway-vm :80)
        |
        +--> iii-http (daemon-vm :3111)
              |
              +--> http::run_inference_over_http   [caller-worker, caller-vm]
                    |
                    +--> iii.trigger('inference::get_response')   [RPC via :49134]
                          |
                          +--> inference::get_response   [caller-worker, caller-vm]
                                |
                                +--> iii.trigger('inference::run_inference')   [RPC via :49134]
                                      |
                                      +--> run_inference_handler   [inference-worker, inference-vm]
                                            |
                                            +--> gemma-3-270m.generate()
                                            |
                                            +--> {"response": "<model output>"}
                                      <------
                                <------
                          <------
                    <------
              <------
        <------
  <------
{"result": {"response": "...", "success": "Workers connected and interoperating."}}
```

No worker calls another worker directly. All RPC calls go through the iii engine,
which routes them based on which worker has the function currently registered.

---

## VM Roles

| VM | Type | Public IP | Role |
|---|---|---|---|
| `gateway-vm` | e2-micro | Yes | nginx reverse proxy, only public entry point |
| `iii-daemon-vm` | e2-small | No | iii engine, RPC broker, HTTP handler, state, queue |
| `caller-vm` | e2-micro | No | TypeScript worker, HTTP to RPC bridge |
| `inference-vm` | e2-standard-2 | No | Python worker, loads and runs gemma-3-270m |

---

## API Reference

### `POST /v1/chat/completions`

**Request**

```json
{
  "messages": [
    { "role": "user", "content": "What is 2+2?" }
  ]
}
```

**Response**

```json
{
  "result": {
    "response": "2 + 2 = 4",
    "success": "Workers connected and interoperating."
  }
}
```

**curl command**

```bash
curl -X POST http://<GATEWAY_EXTERNAL_IP>/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "What is 2+2?"}]}' \
  --max-time 180
```

Replace `<GATEWAY_EXTERNAL_IP>` with the output of:

```bash
cd terraform && terraform output -raw gateway_external_ip
```

**Notes**
- First request takes 30 to 90 seconds (CPU inference on e2-standard-2)
- Subsequent requests are faster as the model stays loaded in memory
- `--max-time 180` is required since default curl timeout is too short for CPU inference

---

## Repository Structure

```
llm-inferencing-devops/
|-- terraform/
|   |-- main.tf               VPC, subnet, NAT, firewall rules, API enablement
|   |-- vms.tf                4 VM definitions, service account, IAM
|   |-- variables.tf          project_id, region, zone, hf_token
|   |-- outputs.tf            gateway IP, curl command, internal IPs
|   |-- terraform.tfvars      YOUR VALUES (gitignored, never commit)
|   +-- terraform.tfvars.example  template to copy
+-- scripts/
    |-- startup-daemon.sh     iii engine install, config.yaml, systemd
    |-- startup-gateway.sh    nginx install, proxy config, systemd
    |-- startup-caller.sh     Node.js install, caller-worker, systemd
    +-- startup-inference.sh  Python install, torch, model, systemd
```

---

## Prerequisites

1. GCP account with billing enabled ($300 free credit is sufficient)
2. `gcloud` CLI installed and authenticated
3. Terraform >= 1.3 installed
4. A HuggingFace account with a read token (free, speeds up model download)
   Get one at: https://huggingface.co/settings/tokens

```bash
gcloud auth login
gcloud auth application-default login
```

---

## Deploy From Scratch

### Step 1 -- Configure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
project_id = "your-gcp-project-id"
region     = "us-central1"
zone       = "us-central1-a"
hf_token   = "hf_your_token_here"
```

> Never commit `terraform.tfvars`. It is already in `.gitignore`.

### Step 2 -- Deploy

```bash
terraform init
terraform plan
terraform apply
```

Type `yes` when prompted. Takes approximately 3 minutes. Terraform outputs the
gateway public IP and a ready-made curl command.

### Step 3 -- Wait for Workers

Startup scripts run automatically in the background after `terraform apply`
completes.

| VM | Time | What is happening |
|---|---|---|
| `gateway-vm` | ~1 min | nginx install and config |
| `iii-daemon-vm` | ~2 min | iii engine install and service start |
| `caller-vm` | ~2 min | Node.js and npm install |
| `inference-vm` | ~8 min | Python, torch, and gemma-3-270m download (~270MB) |

Monitor each VM:

```bash
# Daemon
gcloud compute ssh iii-daemon-vm --tunnel-through-iap --zone=us-central1-a \
  --command="tail -3 /var/log/startup-daemon.log"
# Ready when: "=== [daemon] startup complete: ..."

# Gateway
gcloud compute ssh gateway-vm --tunnel-through-iap --zone=us-central1-a \
  --command="tail -3 /var/log/startup-gateway.log"
# Ready when: "=== [gateway] startup complete: ..."

# Caller
gcloud compute ssh caller-vm --tunnel-through-iap --zone=us-central1-a \
  --command="tail -3 /var/log/startup-caller.log"
# Ready when: "=== [caller] startup complete: ..."

# Inference (takes longest due to model download)
gcloud compute ssh inference-vm --tunnel-through-iap --zone=us-central1-a \
  --command="journalctl -u inference-worker --no-pager | tail -5"
# Ready when: "=== [inference] worker ready - listening for calls ==="
```

### Step 4 -- Test

```bash
GATEWAY_IP=$(terraform output -raw gateway_external_ip)

curl -X POST http://$GATEWAY_IP/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "What is 2+2?"}]}' \
  --max-time 180
```

Expected response:

```json
{
  "result": {
    "response": "2 + 2 = 4",
    "success": "Workers connected and interoperating."
  }
}
```

### Step 5 -- Tear Down

```bash
terraform destroy
```

Type `yes`. Deletes all VMs, VPC, firewall rules, and IAM resources.

---

## Layer-by-Layer Verification

Test each layer independently to isolate failures.

### Layer 1 -- Network

```bash
gcloud compute networks describe iii-vpc
gcloud compute firewall-rules list --filter="network=iii-vpc"
# Expected: allow-http-ingress, allow-iii-rpc, allow-iii-http,
#           allow-iap-ssh, allow-internal
```

### Layer 2 -- iii Engine

```bash
gcloud compute ssh iii-daemon-vm --tunnel-through-iap --zone=us-central1-a

# On the VM:
systemctl status iii-engine
ss -tlnp | grep -E '49134|3111'
# Both ports must show LISTEN
```

### Layer 3 -- Workers Connected

```bash
# Caller worker registered
gcloud compute ssh caller-vm --tunnel-through-iap --zone=us-central1-a \
  --command="journalctl -u caller-worker --no-pager | tail -5"
# Look for: "[iii] Worker registered with ID: ..."

# Inference worker ready
gcloud compute ssh inference-vm --tunnel-through-iap --zone=us-central1-a \
  --command="journalctl -u inference-worker --no-pager | tail -5"
# Look for: "=== [inference] worker ready - listening for calls ==="
```

### Layer 4 -- nginx Health Check

```bash
curl http://$GATEWAY_IP/healthz
# Expected: ok
```

### Layer 5 -- End-to-End

```bash
curl -X POST http://$GATEWAY_IP/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "What is 2+2?"}]}' \
  --max-time 180
```

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `502 Bad Gateway` | iii engine not running or port 3111 not listening | `systemctl status iii-engine` on daemon-vm |
| `504 Gateway Timeout` | nginx timeout shorter than inference time | Verify `proxy_read_timeout 180s` in `/etc/nginx/sites-available/iii` |
| `Invocation timeout after 30000ms` | `timeoutMs` missing in worker.ts | Verify `timeoutMs: 120000` in both `iii.trigger()` calls |
| Empty curl response | iii-http `default_timeout` too low | Verify `default_timeout: 120000` in `/opt/iii/config.yaml` |
| Worker shows `ECONNREFUSED` | daemon not ready when worker started | `systemctl restart caller-worker` or `inference-worker` |
| `HOME: parameter not set` | Startup script ran without HOME | Verify `export HOME=/root` before `curl install.iii.dev` in startup-daemon.sh |
| `IAM API disabled` error | Fresh GCP project, APIs not enabled | Terraform enables them automatically via `google_project_service` |

**Check all services at once:**

```bash
for vm in iii-daemon-vm gateway-vm caller-vm inference-vm; do
  echo "=== $vm ==="
  gcloud compute ssh $vm --tunnel-through-iap --zone=us-central1-a \
    --command="systemctl is-active iii-engine inference-worker caller-worker nginx 2>/dev/null | tr '\n' ' '" 2>/dev/null
  echo
done
```

---

## Design Decisions

**Cloud NAT instead of public IPs on worker VMs.**
Cloud NAT gives private VMs outbound internet access (pip, npm, HuggingFace)
without accepting any inbound connections. Worker VMs are unreachable from the
internet regardless of what ports their processes bind to.

**iii daemon on its own VM, not co-located with a worker.**
The daemon is the single coordination point for all RPC routing. Keeping it
isolated means a worker crash cannot take down the broker. Workers reconnect
automatically via `systemd Restart=always` and re-register their functions.

**config.yaml declares built-in workers only, not inference-worker or caller-worker.**
Per the iii docs, workers connect to the engine over WebSocket via `III_URL`.
`worker_path` in config.yaml is a local-development convenience that tells the
iii CLI to spawn the worker as a subprocess. In this deployment each worker runs
on its own VM and connects independently so no config entry is needed.

**e2-standard-2 for inference-vm.**
torch CPU build: ~1.5GB RAM. gemma-3-270m Q8 weights: ~270MB. Activation memory
during inference: ~1-2GB. Peak total: ~4GB. e2-micro (1GB) and e2-small (2GB)
OOM-kill the process. The source project's `iii.worker.yaml` has `memory: 8192`
as a hint. e2-standard-2 (8GB) matches this.

**max_new_tokens patched 32000 to 512.**
At ~10 tokens/second on CPU, 32000 tokens = ~53 minutes per request, longer than
any HTTP timeout. 512 tokens gives a useful response in approximately 1 minute.

**repetition_penalty=1.3 added to model.generate().**
Small models (270M parameters) fall into repetition loops without this. The
penalty divides the probability of any already-generated token by 1.3 on each
step, forcing the model to consider other tokens.

---

## Production Hardening

**Authentication.** The `/v1/chat/completions` endpoint has no auth. In production,
add an `Authorization: Bearer <token>` check in nginx via the `auth_request`
module, or put Cloud Armor in front of a Global HTTPS Load Balancer.

**TLS.** Currently plain HTTP. Add a Google-managed SSL certificate on a Global
HTTPS Load Balancer. The certificate itself is free.

**Single point of failure.** The iii daemon VM is the RPC broker for the entire
mesh. If the VM fails, all workers disconnect. `Restart=always` handles process
crashes but not VM failure. In production, run the daemon in a Managed Instance
Group with a health check, or move to GKE where it can be rescheduled
automatically.

**Secrets.** `III_URL` and `HF_TOKEN` are passed as GCP instance metadata,
readable by anyone with VM access. In production, store sensitive config in
Secret Manager and grant the service account `secretmanager.secretAccessor`.

**CORS.** `config.yaml` has `allowed_origins: ['*']`. Lock this to specific
origins before any public exposure.

**Observability.** The iii engine collects traces and metrics via
`iii-observability` but stores them in memory only. In production, export to
Cloud Trace and Cloud Monitoring. Add structured logging from each worker to
Cloud Logging.

---

## Scaling to a 100x Larger Model

A 270M parameter model runs on CPU with 8GB RAM. A 27B parameter model changes
every layer of this stack.

**Hardware.** You need a GPU. An A100 (80GB) or H100 is required for a 27B model
at full precision. GCP's `a2-highgpu-1g` costs approximately $3.67/hr. You would
provision it on demand for inference and shut it down when idle, rather than
running it continuously like this deployment does.

**Inference server.** Replace the `transformers` generate loop with vLLM or TGI
(Text Generation Inference). These support continuous batching where multiple
requests are processed simultaneously on one GPU. The current implementation
processes one request at a time and blocks the worker thread during generation.

**Model loading.** A 27B Q8 model is ~27GB on disk. Loading it takes 3 to 5
minutes. You would store weights on a persistent disk attached to the inference
VM, or in Cloud Storage with a warm-up script. You would never terminate the
inference VM between requests since cold-start time is too expensive.

**The iii architecture helps here.** The RPC interface between caller-worker and
inference-worker is a clean abstraction boundary. You can replace the inference
implementation (bigger model, vLLM backend, batching) without changing the
caller-worker or the HTTP API contract. The routing layer stays the same. You can
also run multiple inference-vm replicas and the iii engine will round-robin RPC
calls across all registered workers automatically.