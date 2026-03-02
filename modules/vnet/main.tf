resource "azurerm_virtual_network" "vnet" {
  name                = var.vnet_name
  address_space       = var.vnet_address_space
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# Subnet dedicated to the Kubernetes control-plane (master) node
resource "azurerm_subnet" "master" {
  name                 = var.master_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.master_subnet_prefix]
}

# Subnet shared by all Kubernetes worker nodes
resource "azurerm_subnet" "worker" {
  name                 = var.worker_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.worker_subnet_prefix]
}
