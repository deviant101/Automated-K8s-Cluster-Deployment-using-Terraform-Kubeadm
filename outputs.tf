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
  value       = "ssh -i ${var.ssh_private_key_path} ${var.admin_username}@${module.master_vm.public_ip}"
}

output "ssh_workers" {
  description = "SSH commands to connect to each worker node"
  value       = [for vm in module.worker_vm : "ssh -i ${var.ssh_private_key_path} ${var.admin_username}@${vm.public_ip}"]
}

output "get_kubeconfig" {
  description = "Command to download the kubeconfig from the master to your local machine"
  value       = "scp -i ${var.ssh_private_key_path} ${var.admin_username}@${module.master_vm.public_ip}:/home/${var.admin_username}/admin.kubeconfig ./kubeconfig"
}

output "kubectl_get_nodes" {
  description = "Command to verify all cluster nodes after downloading the kubeconfig"
  value       = "KUBECONFIG=./kubeconfig kubectl get nodes -o wide"
}

output "cilium_status" {
  description = "SSH command to check Cilium status on the master"
  value       = "ssh -i ${var.ssh_private_key_path} ${var.admin_username}@${module.master_vm.public_ip} 'KUBECONFIG=/etc/kubernetes/admin.conf sudo -E cilium status'"
}

output "master_init_log" {
  description = "SSH command to tail the master bootstrap log"
  value       = "ssh -i ${var.ssh_private_key_path} ${var.admin_username}@${module.master_vm.public_ip} 'sudo tail -f /var/log/k8s-master-init.log'"
}
