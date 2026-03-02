terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# ─────────────────────────────────────────────────────────────────────────────
# Resource Group
# ─────────────────────────────────────────────────────────────────────────────
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# VNet + Subnets
# ─────────────────────────────────────────────────────────────────────────────
module "vnet" {
  source = "./modules/vnet"

  resource_group_name  = azurerm_resource_group.rg.name
  location             = azurerm_resource_group.rg.location
  vnet_name            = var.vnet_name
  vnet_address_space   = var.vnet_address_space
  master_subnet_name   = var.master_subnet_name
  master_subnet_prefix = var.master_subnet_prefix
  worker_subnet_name   = var.worker_subnet_name
  worker_subnet_prefix = var.worker_subnet_prefix
  tags                 = var.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# NSG — Master / Control-Plane Subnet
# ─────────────────────────────────────────────────────────────────────────────
#
# Required ports (kubeadm / Kubernetes control-plane):
#   22        – SSH management access
#   6443      – kube-apiserver  (all nodes + kubectl clients)
#   2379-2380 – etcd client/peer API  (master-internal only)
#   10250     – Kubelet API   (kube-apiserver → kubelet on master)
#   10257     – kube-controller-manager (master-internal)
#   10259     – kube-scheduler         (master-internal)
#   8472 UDP  – Flannel VXLAN overlay  (all cluster nodes)
# ─────────────────────────────────────────────────────────────────────────────

module "master_nsg" {
  source = "./modules/nsg"

  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  nsg_name            = "master-nsg"
  subnet_id           = module.vnet.master_subnet_id
  tags                = var.tags

  security_rules = [
    # ── Inbound ──────────────────────────────────────────────────────────
    {
      name                       = "Allow-SSH-Inbound"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "22"
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    },
    {
      # All nodes and external kubectl clients need to reach the API server
      name                       = "Allow-KubeAPI-Inbound"
      priority                   = 110
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "6443"
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    },
    {
      # etcd is reachable only from within the master subnet (control-plane HA)
      name                       = "Allow-etcd-Inbound"
      priority                   = 120
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "2379-2380"
      source_address_prefix      = var.master_subnet_prefix
      destination_address_prefix = "*"
    },
    {
      # kube-apiserver calls kubelet on every node — workers also call back to master kubelet
      name                       = "Allow-Kubelet-API-Inbound"
      priority                   = 130
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "10250"
      source_address_prefix      = var.vnet_address_space[0]
      destination_address_prefix = "*"
    },
    {
      # kube-controller-manager health/metrics – internal to control plane
      name                       = "Allow-KubeControllerManager-Inbound"
      priority                   = 140
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "10257"
      source_address_prefix      = var.master_subnet_prefix
      destination_address_prefix = "*"
    },
    {
      # kube-scheduler health/metrics – internal to control plane
      name                       = "Allow-KubeScheduler-Inbound"
      priority                   = 150
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "10259"
      source_address_prefix      = var.master_subnet_prefix
      destination_address_prefix = "*"
    },
    {
      # Flannel VXLAN overlay – needed for pod-to-pod traffic across nodes
      name                       = "Allow-Flannel-VXLAN-Inbound"
      priority                   = 160
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Udp"
      source_port_range          = "*"
      destination_port_range     = "8472"
      source_address_prefix      = var.vnet_address_space[0]
      destination_address_prefix = "*"
    },
    # ── Outbound ─────────────────────────────────────────────────────────
    {
      name                       = "Allow-All-Outbound"
      priority                   = 100
      direction                  = "Outbound"
      access                     = "Allow"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "*"
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    },
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# NSG — Worker Nodes Subnet
# ─────────────────────────────────────────────────────────────────────────────
#
# Required ports (kubeadm / Kubernetes worker nodes):
#   22          – SSH management access
#   10250       – Kubelet API  (kube-apiserver on master → kubelet on worker)
#   10256       – kube-proxy health check
#   30000-32767 – NodePort services  (external traffic)
#   8472 UDP    – Flannel VXLAN overlay  (all cluster nodes)
# ─────────────────────────────────────────────────────────────────────────────

module "worker_nsg" {
  source = "./modules/nsg"

  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  nsg_name            = "worker-nsg"
  subnet_id           = module.vnet.worker_subnet_id
  tags                = var.tags

  security_rules = [
    # ── Inbound ──────────────────────────────────────────────────────────
    {
      name                       = "Allow-SSH-Inbound"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "22"
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    },
    {
      # kube-apiserver on master communicates with kubelet on workers
      name                       = "Allow-Kubelet-API-Inbound"
      priority                   = 110
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "10250"
      source_address_prefix      = var.master_subnet_prefix
      destination_address_prefix = "*"
    },
    {
      # kube-proxy health check endpoint
      name                       = "Allow-KubeProxy-Health-Inbound"
      priority                   = 120
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "10256"
      source_address_prefix      = var.vnet_address_space[0]
      destination_address_prefix = "*"
    },
    {
      # NodePort services – internet-facing applications hosted on workers
      name                       = "Allow-NodePort-Inbound"
      priority                   = 130
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "30000-32767"
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    },
    {
      # Flannel VXLAN overlay traffic between all cluster nodes
      name                       = "Allow-Flannel-VXLAN-Inbound"
      priority                   = 140
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Udp"
      source_port_range          = "*"
      destination_port_range     = "8472"
      source_address_prefix      = var.vnet_address_space[0]
      destination_address_prefix = "*"
    },
    # ── Outbound ─────────────────────────────────────────────────────────
    {
      name                       = "Allow-All-Outbound"
      priority                   = 100
      direction                  = "Outbound"
      access                     = "Allow"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "*"
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    },
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Virtual Machines
# ─────────────────────────────────────────────────────────────────────────────

module "master_vm" {
  source = "./modules/vm"

  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  vm_name             = "k8s-master"
  vm_size             = var.master_vm_size
  subnet_id           = module.vnet.master_subnet_id
  admin_username      = var.admin_username
  ssh_public_key      = file(var.ssh_public_key_path)
  os_disk_size_gb     = var.os_disk_size_gb
  tags                = merge(var.tags, { Role = "master" })

  depends_on = [module.master_nsg]
}

# Two worker nodes share the worker subnet (count = 2)
module "worker_vm" {
  source = "./modules/vm"
  count  = 2

  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  vm_name             = "k8s-worker-${count.index + 1}"
  vm_size             = var.worker_vm_size
  subnet_id           = module.vnet.worker_subnet_id
  admin_username      = var.admin_username
  ssh_public_key      = file(var.ssh_public_key_path)
  os_disk_size_gb     = var.os_disk_size_gb
  tags                = merge(var.tags, { Role = "worker", Index = tostring(count.index + 1) })

  depends_on = [module.worker_nsg]
}
