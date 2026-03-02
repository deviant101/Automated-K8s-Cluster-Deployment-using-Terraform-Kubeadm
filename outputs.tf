output "master_public_ip" {
  description = "Public IP of the Kubernetes master node"
  value       = module.master_vm.public_ip
}

output "master_private_ip" {
  description = "Private IP of the Kubernetes master node"
  value       = module.master_vm.private_ip
}

output "worker_public_ips" {
  description = "Public IPs of all worker nodes"
  value       = [for vm in module.worker_vm : vm.public_ip]
}

output "worker_private_ips" {
  description = "Private IPs of all worker nodes"
  value       = [for vm in module.worker_vm : vm.private_ip]
}

output "ssh_master" {
  description = "SSH command to connect to the master node"
  value       = "ssh ${var.admin_username}@${module.master_vm.public_ip}"
}

output "ssh_workers" {
  description = "SSH commands to connect to each worker node"
  value       = [for vm in module.worker_vm : "ssh ${var.admin_username}@${vm.public_ip}"]
}
