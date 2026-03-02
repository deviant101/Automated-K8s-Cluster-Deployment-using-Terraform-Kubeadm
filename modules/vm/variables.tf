variable "resource_group_name" {
  description = "Name of the Azure resource group"
  type        = string
}

variable "location" {
  description = "Azure region for the VM and related resources"
  type        = string
}

variable "vm_name" {
  description = "Name of the virtual machine (also used as prefix for NIC and public IP)"
  type        = string
}

variable "vm_size" {
  description = "Azure VM SKU/size (e.g. Standard_D2s_v3)"
  type        = string
}

variable "subnet_id" {
  description = "Resource ID of the subnet in which the VM NIC will be placed"
  type        = string
}

variable "admin_username" {
  description = "Username for the VM admin/SSH account"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key content (not a path) to authorise for the admin user"
  type        = string
}

variable "os_disk_size_gb" {
  description = "Size of the OS disk in GB"
  type        = number
  default     = 50
}

variable "private_ip_allocation" {
  description = "Private IP allocation method: Dynamic or Static"
  type        = string
  default     = "Dynamic"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
