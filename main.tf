terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    # null provider — used for remote-exec provisioners that bootstrap the cluster
    null = {
      source  = "hashicorp/null"
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
# Required ports (kubeadm / Kubernetes control-plane + Cilium CNI):
#   22        – SSH management access
#   6443      – kube-apiserver  (all nodes + kubectl clients)
#   2379-2380 – etcd client/peer API  (control-plane internal only)
#   10250     – Kubelet API   (kube-apiserver → kubelet)
#   10257     – kube-controller-manager (control-plane internal)
#   10259     – kube-scheduler         (control-plane internal)
#   8472 UDP  – Cilium VXLAN overlay tunnel (all cluster nodes)
#   4240 TCP  – Cilium health check endpoint (all cluster nodes)
#   4244 TCP  – Hubble server (observability — within VNet)
#   ICMP      – Cilium node-to-node health probing
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
      # Cilium VXLAN overlay tunnel — pod-to-pod traffic between all cluster nodes
      name                       = "Allow-Cilium-VXLAN-Inbound"
      priority                   = 160
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Udp"
      source_port_range          = "*"
      destination_port_range     = "8472"
      source_address_prefix      = var.vnet_address_space[0]
      destination_address_prefix = "*"
    },
    {
      # Cilium health check — cilium-health agent probes between all nodes
      name                       = "Allow-Cilium-Health-Inbound"
      priority                   = 170
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "4240"
      source_address_prefix      = var.vnet_address_space[0]
      destination_address_prefix = "*"
    },
    {
      # Hubble server — Cilium observability gRPC API (within VNet only)
      name                       = "Allow-Hubble-Server-Inbound"
      priority                   = 180
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "4244"
      source_address_prefix      = var.vnet_address_space[0]
      destination_address_prefix = "*"
    },
    {
      # Cilium node-to-node ICMP health probes
      name                       = "Allow-Cilium-ICMP-Health-Inbound"
      priority                   = 190
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Icmp"
      source_port_range          = "*"
      destination_port_range     = "*"
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
# Required ports (kubeadm / Kubernetes worker nodes + Cilium CNI):
#   22          – SSH management access
#   10250       – Kubelet API  (kube-apiserver on master → kubelet on worker)
#   10256       – kube-proxy health check (or Cilium replacement)
#   30000-32767 – NodePort services  (external traffic ingress)
#   8472 UDP    – Cilium VXLAN overlay tunnel (all cluster nodes)
#   4240 TCP    – Cilium health check endpoint (all cluster nodes)
#   4244 TCP    – Hubble server (observability — within VNet)
#   ICMP        – Cilium node-to-node health probing
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
      # kube-proxy health check endpoint (or Cilium's replacement)
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
      # NodePort services – internet-facing workloads hosted on workers
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
      # Cilium VXLAN overlay tunnel — pod-to-pod traffic between all cluster nodes
      name                       = "Allow-Cilium-VXLAN-Inbound"
      priority                   = 140
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Udp"
      source_port_range          = "*"
      destination_port_range     = "8472"
      source_address_prefix      = var.vnet_address_space[0]
      destination_address_prefix = "*"
    },
    {
      # Cilium health check — cilium-health agent probes between all nodes
      name                       = "Allow-Cilium-Health-Inbound"
      priority                   = 150
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "4240"
      source_address_prefix      = var.vnet_address_space[0]
      destination_address_prefix = "*"
    },
    {
      # Hubble server — Cilium observability gRPC API (within VNet only)
      name                       = "Allow-Hubble-Server-Inbound"
      priority                   = 160
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "4244"
      source_address_prefix      = var.vnet_address_space[0]
      destination_address_prefix = "*"
    },
    {
      # Cilium node-to-node ICMP health probes
      name                       = "Allow-Cilium-ICMP-Health-Inbound"
      priority                   = 170
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Icmp"
      source_port_range          = "*"
      destination_port_range     = "*"
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
# cloud-init — common node preparation script (runs on every VM at first boot)
# templatefile() substitutes the Kubernetes version variables into the script
# before base64-encoding it for Azure custom_data.
# ─────────────────────────────────────────────────────────────────────────────
locals {
  master_cloud_init = base64encode(templatefile("${path.module}/scripts/common-node-setup.sh", {
    k8s_version = var.kubernetes_version
    k8s_minor   = var.kubernetes_pkg_version
    node_role   = "master"
  }))

  worker_cloud_init = base64encode(templatefile("${path.module}/scripts/common-node-setup.sh", {
    k8s_version = var.kubernetes_version
    k8s_minor   = var.kubernetes_pkg_version
    node_role   = "worker"
  }))
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
  custom_data         = local.master_cloud_init
  tags                = merge(var.tags, { Role = "master" })

  depends_on = [module.master_nsg]
}

# Worker nodes — count driven by var.worker_count (default 2)
module "worker_vm" {
  source = "./modules/vm"
  count  = var.worker_count

  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  vm_name             = "k8s-worker-${count.index + 1}"
  vm_size             = var.worker_vm_size
  subnet_id           = module.vnet.worker_subnet_id
  admin_username      = var.admin_username
  ssh_public_key      = file(var.ssh_public_key_path)
  os_disk_size_gb     = var.os_disk_size_gb
  custom_data         = local.worker_cloud_init
  tags                = merge(var.tags, { Role = "worker", Index = tostring(count.index + 1) })

  depends_on = [module.worker_nsg]
}

# ─────────────────────────────────────────────────────────────────────────────
# Cluster Bootstrap — Phase 1: Control-Plane Init
# ─────────────────────────────────────────────────────────────────────────────
# Uploads master-init.sh and runs it on the master VM via SSH.
# The script:
#   1. Waits for cloud-init (common-node-setup.sh) to complete
#   2. Runs kubeadm init (with --skip-phases=addon/kube-proxy for Cilium)
#   3. Installs the Cilium CLI and deploys Cilium as the CNI
#   4. Writes the kubeadm join command to ~/join-command.sh
# ─────────────────────────────────────────────────────────────────────────────
resource "null_resource" "master_bootstrap" {
  # Re-run if the master VM is recreated
  triggers = {
    master_vm_id = module.master_vm.vm_id
  }

  connection {
    type        = "ssh"
    host        = module.master_vm.public_ip
    user        = var.admin_username
    private_key = file(var.ssh_private_key_path)
    timeout     = "20m"
  }

  # Upload the master bootstrap script
  provisioner "file" {
    source      = "${path.module}/scripts/master-init.sh"
    destination = "/home/${var.admin_username}/master-init.sh"
  }

  # Execute the bootstrap script as root
  provisioner "remote-exec" {
    inline = [
      "chmod +x /home/${var.admin_username}/master-init.sh",
      "sudo bash /home/${var.admin_username}/master-init.sh '${var.pod_cidr}' '${var.service_cidr}' '${var.kubernetes_version}' '${var.admin_username}' '${var.cilium_version}' 2>&1 | tee /home/${var.admin_username}/master-init.log",
    ]
  }

  depends_on = [module.master_vm]
}

# ─────────────────────────────────────────────────────────────────────────────
# Cluster Bootstrap — Phase 2: Fetch Join Command to Local Machine
# ─────────────────────────────────────────────────────────────────────────────
# SCPs the join-command.sh generated on the master to the local workspace
# so it can be distributed to worker nodes in the next phase.
# ─────────────────────────────────────────────────────────────────────────────
resource "null_resource" "fetch_join_command" {
  triggers = {
    master_bootstrap_id = null_resource.master_bootstrap.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      scp -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -i "${var.ssh_private_key_path}" \
          "${var.admin_username}@${module.master_vm.public_ip}:/home/${var.admin_username}/join-command.sh" \
          "${path.module}/join-command.sh"
    EOT
  }

  depends_on = [null_resource.master_bootstrap]
}

# ─────────────────────────────────────────────────────────────────────────────
# Cluster Bootstrap — Phase 3: Join Worker Nodes
# ─────────────────────────────────────────────────────────────────────────────
# For each worker VM:
#   1. Uploads the join-command.sh (fetched from master) via file provisioner
#   2. Uploads worker-join.sh helper script
#   3. Executes worker-join.sh which waits for cloud-init, then runs kubeadm join
# ─────────────────────────────────────────────────────────────────────────────
resource "null_resource" "worker_join" {
  count = var.worker_count

  triggers = {
    worker_vm_id        = module.worker_vm[count.index].vm_id
    master_bootstrap_id = null_resource.master_bootstrap.id
  }

  connection {
    type        = "ssh"
    host        = module.worker_vm[count.index].public_ip
    user        = var.admin_username
    private_key = file(var.ssh_private_key_path)
    timeout     = "20m"
  }

  # Upload the join command generated by the master
  provisioner "file" {
    source      = "${path.module}/join-command.sh"
    destination = "/home/${var.admin_username}/join-command.sh"
  }

  # Upload the worker join helper script
  provisioner "file" {
    source      = "${path.module}/scripts/worker-join.sh"
    destination = "/home/${var.admin_username}/worker-join.sh"
  }

  # Execute the join
  provisioner "remote-exec" {
    inline = [
      "chmod +x /home/${var.admin_username}/worker-join.sh",
      "sudo bash /home/${var.admin_username}/worker-join.sh '${var.admin_username}' 2>&1 | tee /home/${var.admin_username}/worker-join.log",
    ]
  }

  depends_on = [
    module.worker_vm,
    null_resource.fetch_join_command,
  ]
}
