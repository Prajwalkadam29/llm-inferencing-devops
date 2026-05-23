variable "project_id" {
  description = "Your GCP project ID (visible in the GCP console top bar)"
  type        = string
}

variable "region" {
  description = "GCP region for all resources"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone inside the region"
  type        = string
  default     = "us-central1-a"
}

variable "hf_token" {
  description = "HuggingFace read token for faster model downloads"
  type        = string
  sensitive   = true
}
