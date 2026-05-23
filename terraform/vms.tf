# ─────────────────────────────────────────────────────────────────
# Latest Debian 12 image — smaller than Ubuntu, stable on GCP
# ─────────────────────────────────────────────────────────────────
data "google_compute_image" "debian" {
  family  = "debian-12"
  project = "debian-cloud"
}

# ─────────────────────────────────────────────────────────────────
# Service Account — shared by all VMs
# Minimal permissions: write logs, write metrics.
# ─────────────────────────────────────────────────────────────────
resource "google_service_account" "iii_sa" {
  account_id   = "iii-worker-sa"
  display_name = "iii Worker Service Account"
  depends_on   = [google_project_service.required_apis]
}

resource "google_project_iam_member" "logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.iii_sa.email}"
  depends_on = [google_project_service.required_apis]
}

resource "google_project_iam_member" "monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.iii_sa.email}"
  depends_on = [google_project_service.required_apis]
}

resource "google_project_iam_member" "iap_tunnel" {
  project = var.project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = "serviceAccount:${google_service_account.iii_sa.email}"
  depends_on = [google_project_service.required_apis]
}

# ─────────────────────────────────────────────────────────────────
# VM 1: iii-daemon-vm
# Runs the iii engine. Must be created FIRST — worker VMs need its
# private IP to set III_URL before they boot.
#
# The engine is responsible for:
#   - accepting WebSocket connections from workers on :49134
#   - routing RPC calls between registered functions
#   - serving iii-http on :3111 (proxied by nginx on gateway-vm)
#   - running iii-state (SQLite KV) and iii-queue (built-in)
#
# e2-small (2 vCPU, 2GB RAM): sufficient for the engine itself,
# which is lightweight — it routes messages, it doesn't compute.
# ─────────────────────────────────────────────────────────────────
resource "google_compute_instance" "daemon" {
  name         = "iii-daemon-vm"
  machine_type = "e2-small"
  zone         = var.zone
  tags         = ["iii-daemon"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.debian.self_link
      size  = 20  # extra headroom for SQLite state store
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    # No access_config block = no public IP
  }

  service_account {
    email  = google_service_account.iii_sa.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    startup-script = file("${path.module}/../scripts/startup-daemon.sh")
  }

  description = "iii engine. RPC broker :49134, iii-http :3111, iii-state, iii-queue. Private only."
}

# ─────────────────────────────────────────────────────────────────
# VM 2: gateway-vm
# The ONLY VM with a public IP. nginx reverse-proxies :80 to
# iii-http on daemon-vm:3111.
# Deployed after daemon so we can inject daemon's private IP.
# ─────────────────────────────────────────────────────────────────
resource "google_compute_instance" "gateway" {
  name         = "gateway-vm"
  machine_type = "e2-micro"
  zone         = var.zone
  tags         = ["gateway"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.debian.self_link
      size  = 10
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    access_config {}  # gives this VM a public IP
  }

  service_account {
    email  = google_service_account.iii_sa.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    # Daemon private IP injected so the startup script can write
    # the nginx proxy_pass directive correctly at boot time.
    daemon_internal_ip = google_compute_instance.daemon.network_interface[0].network_ip
    startup-script     = file("${path.module}/../scripts/startup-gateway.sh")
  }

  depends_on  = [google_compute_instance.daemon]
  description = "nginx reverse proxy. Only VM with a public IP."
}

# ─────────────────────────────────────────────────────────────────
# VM 3: caller-vm
# Runs caller-worker (TypeScript/Node.js).
# Connects to iii engine via III_URL=ws://<daemon-ip>:49134.
# Registers: inference::get_response, http::run_inference_over_http
#
# e2-micro (1 vCPU, 1GB RAM): tsx is lightweight, this is enough.
# ─────────────────────────────────────────────────────────────────
resource "google_compute_instance" "caller" {
  name         = "caller-vm"
  machine_type = "e2-micro"
  zone         = var.zone
  tags         = ["iii-worker"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.debian.self_link
      size  = 10
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
  }

  service_account {
    email  = google_service_account.iii_sa.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    # III_URL tells the worker where the iii engine WebSocket is.
    # Per the iii docs: "The connection string is the only coupling
    # between a worker and the iii instance it joins."
    iii_url        = "ws://${google_compute_instance.daemon.network_interface[0].network_ip}:49134"
    startup-script = file("${path.module}/../scripts/startup-caller.sh")
  }

  depends_on  = [google_compute_instance.daemon]
  description = "caller-worker (TypeScript). HTTP→RPC bridge. Connects to engine via III_URL."
}

# ─────────────────────────────────────────────────────────────────
# VM 4: inference-vm
# Runs inference-worker (Python + torch + gemma-3-270m).
# Registers: inference::run_inference
#
# WHY e2-standard-2 (2 vCPU, 8GB RAM):
#   torch CPU build alone: ~1.5GB RAM
#   gemma-3-270m Q8 GGUF weights: ~270MB
#   activation/KV cache during inference: ~1-2GB
#   Total peak: ~4GB — e2-micro (1GB) and e2-small (2GB) OOM-kill.
#   e2-standard-2 (8GB) gives comfortable headroom.
#   This matches the iii.worker.yaml hint: memory: 8192 MiB.
#
# WHY 30GB disk:
#   torch + transformers + deps: ~3GB
#   model GGUF file: ~270MB
#   Python venv overhead: ~500MB
#   OS + wiggle room: ~10GB
# ─────────────────────────────────────────────────────────────────
resource "google_compute_instance" "inference" {
  name         = "inference-vm"
  machine_type = "e2-standard-2"
  zone         = var.zone
  tags         = ["iii-worker"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.debian.self_link
      size  = 30
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
  }

  service_account {
    email  = google_service_account.iii_sa.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    iii_url        = "ws://${google_compute_instance.daemon.network_interface[0].network_ip}:49134"
    hf_token       = var.hf_token
    startup-script = file("${path.module}/../scripts/startup-inference.sh")
  }

  depends_on  = [google_compute_instance.daemon]
  description = "inference-worker (Python). Loads gemma-3-270m Q8, handles inference::run_inference."
}
