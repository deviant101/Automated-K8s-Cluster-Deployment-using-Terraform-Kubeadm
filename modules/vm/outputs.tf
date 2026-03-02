output "vm_id" {
  description = "Resource ID of the virtual machine"
  value       = azurerm_linux_virtual_machine.vm.id
}

output "public_ip" {
  description = "Public IP address assigned to the VM"
  value       = azurerm_public_ip.pip.ip_address
}

output "private_ip" {
  description = "Private IP address of the VM NIC within the subnet"
  value       = azurerm_network_interface.nic.private_ip_address
}
