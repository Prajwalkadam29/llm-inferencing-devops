terraform {
  required_version = ">= 1.3"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# ─────────────────────────────────────────────────────────────────
# Enable required GCP APIs
# On a fresh project these are disabled by default, causing
# terraform apply to fail with 403 errors on IAM/compute resources.
# disable_on_destroy = false — don't disable APIs when tearing down.
# ─────────────────────────────────────────────────────────────────
resource "google_project_service" "required_apis" {
  for_each = toset([
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "iap.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ─────────────────────────────────────────────────────────────────
# VPC
# Custom-mode so we control every subnet explicitly.
# GCP's default auto-mode VPC pre-creates subnets in every region —
# too broad. We want exactly one subnet, one region, full control.
# ─────────────────────────────────────────────────────────────────
resource "google_compute_network" "vpc" {
  name                    = "iii-vpc"
  auto_create_subnetworks = false
  description             = "Private network for the iii worker mesh"
  depends_on              = [google_project_service.required_apis]
}

# ─────────────────────────────────────────────────────────────────
# Subnet — all four VMs live here
# private_ip_google_access lets VMs reach Google APIs
# (Cloud Logging, Monitoring) without a public IP.
# ─────────────────────────────────────────────────────────────────
resource "google_compute_subnetwork" "subnet" {
  name                     = "iii-subnet"
  network                  = google_compute_network.vpc.id
  region                   = var.region
  ip_cidr_range            = "10.0.1.0/24"
  private_ip_google_access = true
  description              = "Private subnet — only gateway-vm gets a public IP"
}

# ─────────────────────────────────────────────────────────────────
# Cloud Router — required plumbing for Cloud NAT
# ─────────────────────────────────────────────────────────────────
resource "google_compute_router" "router" {
  name    = "iii-router"
  network = google_compute_network.vpc.id
  region  = var.region
}

# ─────────────────────────────────────────────────────────────────
# Cloud NAT
# Gives private VMs outbound internet WITHOUT a public IP.
# Needed for: the iii install script, pip install, npm install,
# and HuggingFace model download on first boot.
#
# This is NOT port forwarding. NAT is strictly outbound-only —
# no inbound connection can ever reach a private VM through it.
# ─────────────────────────────────────────────────────────────────
resource "google_compute_router_nat" "nat" {
  name                               = "iii-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ─────────────────────────────────────────────────────────────────
# Firewall rules
# GCP default is DENY ALL inbound. We open exactly five paths.
# ─────────────────────────────────────────────────────────────────

# 1. HTTP from internet → gateway-vm only
# The "gateway" network tag targets only that one VM.
# All other VMs are invisible to the internet.
resource "google_compute_firewall" "allow_http_ingress" {
  name        = "allow-http-ingress"
  network     = google_compute_network.vpc.id
  direction   = "INGRESS"
  priority    = 1000
  description = "Internet → gateway-vm:80 (nginx). No other VM accepts public traffic."

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["gateway"]
}

# 2. RPC WebSocket — subnet → iii-daemon-vm:49134
# Workers on caller-vm and inference-vm connect here to the iii engine.
# The "iii-daemon" tag means only daemon-vm receives this traffic.
resource "google_compute_firewall" "allow_iii_rpc" {
  name        = "allow-iii-rpc"
  network     = google_compute_network.vpc.id
  direction   = "INGRESS"
  priority    = 1000
  description = "Subnet VMs → iii-daemon:49134 (RPC WebSocket). Workers connect here."

  allow {
    protocol = "tcp"
    ports    = ["49134"]
  }

  source_ranges = ["10.0.1.0/24"]
  target_tags   = ["iii-daemon"]
}

# 3. iii-http — gateway-vm → daemon-vm:3111
# nginx on gateway-vm reverse-proxies HTTP requests to iii-http.
# source_tags means only the gateway VM can open this connection.
resource "google_compute_firewall" "allow_iii_http" {
  name        = "allow-iii-http"
  network     = google_compute_network.vpc.id
  direction   = "INGRESS"
  priority    = 1000
  description = "gateway-vm → iii-daemon:3111 (iii-http). nginx proxies here."

  allow {
    protocol = "tcp"
    ports    = ["3111"]
  }

  source_tags = ["gateway"]
  target_tags = ["iii-daemon"]
}

# 4. IAP SSH — Google IAP range → all VMs
# 35.235.240.0/20 is Google's fixed IAP source CIDR.
# IAP tunnels SSH through Google's infra — no bastion or public IP needed.
# Without this rule you cannot SSH into any private VM at all.
resource "google_compute_firewall" "allow_iap_ssh" {
  name        = "allow-iap-ssh"
  network     = google_compute_network.vpc.id
  direction   = "INGRESS"
  priority    = 1000
  description = "Google IAP → all VMs:22. SSH without bastion or public IP."

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
}

# 5. Internal — all VMs can talk to each other on private IPs
# Needed so workers reach the daemon, and the gateway proxies to it.
resource "google_compute_firewall" "allow_internal" {
  name        = "allow-internal"
  network     = google_compute_network.vpc.id
  direction   = "INGRESS"
  priority    = 1000
  description = "Intra-subnet traffic across all VMs on private IPs."

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = ["10.0.1.0/24"]
}
