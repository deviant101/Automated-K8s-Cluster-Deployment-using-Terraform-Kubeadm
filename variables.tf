variable "resource_group_name" {
  description = "Name of the Azure resource group that holds all cluster resources"
  type        = string
}

variable "location" {
  description = "Azure region (e.g. 'East US', 'westeurope')"
  type        = string
}

# ─── Networking ───────────────────────────────────────────────────────────────

variable "vnet_name" {
  description = "Name of the VNet shared by the entire cluster"
  type        = string
}

variable "vnet_address_space" {
  description = "Address space for the VNet, e.g. [\"10.0.0.0/16\"]"
  type        = list(string)
}

variable "master_subnet_name" {
  description = "Name of the control-plane subnet"
  type        = string
}

variable "master_subnet_prefix" {
  description = "CIDR block for the master subnet, e.g. 10.0.1.0/24"
  type        = string
}

variable "worker_subnet_name" {
  description = "Name of the worker-nodes subnet"
  type        = string
}

variable "worker_subnet_prefix" {
  description = "CIDR block for the worker subnet, e.g. 10.0.2.0/24"
  type        = string
}

# ─── Virtual Machines ─────────────────────────────────────────────────────────

variable "admin_username" {
  description = "Admin (SSH) username for all VMs"
  type        = string
}

variable "ssh_public_key_path" {
  description = "Local filesystem path to the SSH public key file"
  type        = string
}

variable "master_vm_size" {
  description = "Azure VM SKU for the master node (min 2 vCPU / 2 GB RAM recommended by kubeadm)"
  type        = string
}

variable "worker_vm_size" {
  description = "Azure VM SKU for worker nodes"
  type        = string
}

variable "os_disk_size_gb" {
  description = "OS disk size in GB for all VMs"
  type        = number
  default     = 50
}

# ─── Tags ─────────────────────────────────────────────────────────────────────

variable "tags" {
  description = "Common tags applied to every resource"
  type        = map(string)
  default     = {}
}
