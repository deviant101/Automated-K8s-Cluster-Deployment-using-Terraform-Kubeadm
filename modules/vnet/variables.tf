variable "resource_group_name" {
  description = "Name of the Azure resource group"
  type        = string
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
}

variable "vnet_name" {
  description = "Name of the virtual network"
  type        = string
}

variable "vnet_address_space" {
  description = "Address space for the VNet (CIDR list)"
  type        = list(string)
}

variable "master_subnet_name" {
  description = "Name of the master/control-plane subnet"
  type        = string
}

variable "master_subnet_prefix" {
  description = "CIDR prefix for the master subnet"
  type        = string
}

variable "worker_subnet_name" {
  description = "Name of the worker nodes subnet"
  type        = string
}

variable "worker_subnet_prefix" {
  description = "CIDR prefix for the worker subnet"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
