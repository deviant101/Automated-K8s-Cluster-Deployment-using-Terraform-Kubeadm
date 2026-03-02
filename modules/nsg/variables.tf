variable "resource_group_name" {
  description = "Name of the Azure resource group"
  type        = string
}

variable "location" {
  description = "Azure region for the NSG"
  type        = string
}

variable "nsg_name" {
  description = "Name of the Network Security Group"
  type        = string
}

variable "subnet_id" {
  description = "Resource ID of the subnet to associate this NSG with"
  type        = string
}

variable "security_rules" {
  description = "List of inbound/outbound security rules for the NSG"
  type = list(object({
    name                       = string
    priority                   = number
    direction                  = string # "Inbound" or "Outbound"
    access                     = string # "Allow" or "Deny"
    protocol                   = string # "Tcp", "Udp", "Icmp", or "*"
    source_port_range          = string
    destination_port_range     = string
    source_address_prefix      = string
    destination_address_prefix = string
  }))
  default = []
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
