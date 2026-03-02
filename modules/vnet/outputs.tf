output "vnet_id" {
  description = "Resource ID of the virtual network"
  value       = azurerm_virtual_network.vnet.id
}

output "master_subnet_id" {
  description = "Resource ID of the master (control-plane) subnet"
  value       = azurerm_subnet.master.id
}

output "worker_subnet_id" {
  description = "Resource ID of the worker nodes subnet"
  value       = azurerm_subnet.worker.id
}
