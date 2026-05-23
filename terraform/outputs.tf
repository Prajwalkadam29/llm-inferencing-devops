output "vpc_name" {
  description = "VPC name"
  value       = google_compute_network.vpc.name
}

output "subnet_cidr" {
  description = "Private subnet CIDR"
  value       = google_compute_subnetwork.subnet.ip_cidr_range
}

output "gateway_external_ip" {
  description = "Public IP of gateway-vm — use this in curl commands"
  value       = google_compute_instance.gateway.network_interface[0].access_config[0].nat_ip
}

output "daemon_internal_ip" {
  description = "Private IP of iii-daemon-vm — workers connect to ws://<this>:49134"
  value       = google_compute_instance.daemon.network_interface[0].network_ip
}

output "caller_internal_ip" {
  description = "Private IP of caller-vm"
  value       = google_compute_instance.caller.network_interface[0].network_ip
}

output "inference_internal_ip" {
  description = "Private IP of inference-vm"
  value       = google_compute_instance.inference.network_interface[0].network_ip
}

output "curl_command" {
  description = "End-to-end test — run after all services are up (~8 min after apply)"
  value       = "curl -X POST http://${google_compute_instance.gateway.network_interface[0].access_config[0].nat_ip}/v1/chat/completions -H 'Content-Type: application/json' -d '{\"messages\":[{\"role\":\"user\",\"content\":\"What is 2+2?\"}]}' --max-time 180"
}
