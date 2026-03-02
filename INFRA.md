# Kubernetes Cluster Infrastructure — Azure Setup via Kubeadm

## Overview

This document describes the Azure infrastructure provisioned by Terraform to host a self-managed Kubernetes cluster bootstrapped with **kubeadm**.

The cluster consists of **3 Virtual Machines** (1 master + 2 workers) deployed in a single Virtual Network with dedicated subnets and subnet-level Network Security Groups for each tier.

---

## Architecture Diagram

```
                                  Azure Virtual Network (10.0.0.0/16)
                ┌───────────────────────────────────────────────────────────────────┐
                │                                                                   │
                │   ┌─────────────────────────────┐   ┌──────────────────────────┐  │
                │   │   master-subnet             │   │   worker-subnet          │  │
                │   │   10.0.1.0/24               │   │   10.0.2.0/24            │  │
                │   │   NSG: master-nsg           │   │   NSG: worker-nsg        │  │
                │   │                             │   │                          │  │
                │   │  ┌───────────────────────┐  │   │  ┌────────────────────┐  │  │
                │   │  │  k8s-master           │  │   │  │  k8s-worker-1      │  │  │
                │   │  │  Standard_D2s_v3      │  │   │  │  Standard_D2s_v3   │  │  │
                │   │  │  Ubuntu 22.04 LTS     │  │   │  │  Ubuntu 22.04 LTS  │  │  │
                │   │  └───────────────────────┘  │   │  └────────────────────┘  │  │
                │   │                             │   │                          │  │
                │   └─────────────────────────────┘   │  ┌────────────────────┐  │  │
                │                                     │  │  k8s-worker-2      │  │  │
                │                                     │  │  Standard_D2s_v3   │  │  │
                │                                     │  │  Ubuntu 22.04 LTS  │  │  │
                │                                     │  └────────────────────┘  │  │
                │                                     └──────────────────────────┘  │
                └───────────────────────────────────────────────────────────────────┘
```

---

## Resource Summary

| Resource | Name | Details |
|---|---|---|
| Resource Group | `k8s-cluster-rg` | Contains all cluster resources |
| Virtual Network | `k8s-vnet` | `10.0.0.0/16` |
| Master Subnet | `master-subnet` | `10.0.1.0/24` |
| Worker Subnet | `worker-subnet` | `10.0.2.0/24` |
| NSG (master) | `master-nsg` | Attached at subnet level |
| NSG (worker) | `worker-nsg` | Attached at subnet level |
| Master VM | `k8s-master` | `Standard_B2s`, Ubuntu 22.04 LTS Gen2 |
| Worker VM 1 | `k8s-worker-1` | `Standard_B2s`, Ubuntu 22.04 LTS Gen2 |
| Worker VM 2 | `k8s-worker-2` | `Standard_B2s`, Ubuntu 22.04 LTS Gen2 |

---

## Virtual Machine Specifications

| Property | Value |
|---|---|
| VM Size | `Standard_B2s` — 2 vCPU, 4 GB RAM |
| OS Image | Ubuntu Server 22.04 LTS Gen2 |
| OS Disk | 50 GB Premium SSD (`Premium_LRS`) |
| Authentication | SSH key only (password auth disabled) |
| Public IP | Static, Standard SKU (per VM) |

> **Minimum requirements note:** kubeadm requires at least 2 vCPU and 2 GB RAM per node. `Standard_B2s` (2 vCPU, 4 GB) is used for cost-efficiency while meeting the CPU minimum.

---

## Network Security Groups

NSGs are enforced at the **subnet level**, meaning rules apply to every VM in the subnet without needing per-NIC configuration.

### Master Node NSG (`master-nsg`) — `master-subnet`

#### Inbound Rules

| Priority | Name | Port(s) | Protocol | Source | Purpose |
|---|---|---|---|---|---|
| 100 | Allow-SSH-Inbound | 22 | TCP | `*` | SSH management access |
| 110 | Allow-KubeAPI-Inbound | 6443 | TCP | `*` | Kubernetes API server (kubectl + all nodes) |
| 120 | Allow-etcd-Inbound | 2379–2380 | TCP | `10.0.1.0/24` (master subnet) | etcd client & peer communication |
| 130 | Allow-Kubelet-API-Inbound | 10250 | TCP | `10.0.0.0/16` (VNet) | Kubelet API (kube-apiserver ↔ kubelet) |
| 140 | Allow-KubeControllerManager-Inbound | 10257 | TCP | `10.0.1.0/24` (master subnet) | kube-controller-manager health/metrics |
| 150 | Allow-KubeScheduler-Inbound | 10259 | TCP | `10.0.1.0/24` (master subnet) | kube-scheduler health/metrics |
| 160 | Allow-Flannel-VXLAN-Inbound | 8472 | UDP | `10.0.0.0/16` (VNet) | Flannel VXLAN pod overlay network |

#### Outbound Rules

| Priority | Name | Port(s) | Protocol | Destination | Purpose |
|---|---|---|---|---|---|
| 100 | Allow-All-Outbound | `*` | `*` | `*` | Allow all outbound traffic |

---

### Worker Nodes NSG (`worker-nsg`) — `worker-subnet`

#### Inbound Rules

| Priority | Name | Port(s) | Protocol | Source | Purpose |
|---|---|---|---|---|---|
| 100 | Allow-SSH-Inbound | 22 | TCP | `*` | SSH management access |
| 110 | Allow-Kubelet-API-Inbound | 10250 | TCP | `10.0.1.0/24` (master subnet) | Kubelet API (kube-apiserver → worker kubelet) |
| 120 | Allow-KubeProxy-Health-Inbound | 10256 | TCP | `10.0.0.0/16` (VNet) | kube-proxy health check endpoint |
| 130 | Allow-NodePort-Inbound | 30000–32767 | TCP | `*` | Kubernetes NodePort services (external traffic) |
| 140 | Allow-Flannel-VXLAN-Inbound | 8472 | UDP | `10.0.0.0/16` (VNet) | Flannel VXLAN pod overlay network |

#### Outbound Rules

| Priority | Name | Port(s) | Protocol | Destination | Purpose |
|---|---|---|---|---|---|
| 100 | Allow-All-Outbound | `*` | `*` | `*` | Allow all outbound traffic |

---

## Terraform Module Structure

```
.
├── main.tf                  # Provider, Resource Group, module invocations, NSG rules
├── variables.tf             # All input variable declarations
├── outputs.tf               # Public/private IPs + SSH connection commands
├── terraform.tfvars         # Default variable values (edit before apply)
└── modules/
    ├── vnet/
    │   ├── main.tf          # azurerm_virtual_network + master & worker subnets
    │   ├── variables.tf
    │   └── outputs.tf
    ├── nsg/
    │   ├── main.tf          # azurerm_network_security_group + subnet association
    │   ├── variables.tf
    │   └── outputs.tf
    └── vm/
        ├── main.tf          # Public IP, NIC, azurerm_linux_virtual_machine
        ├── variables.tf
        └── outputs.tf
```

### Module Responsibilities

| Module | Responsibilities |
|---|---|
| `modules/vnet` | Creates the VNet and both subnets |
| `modules/nsg` | Creates an NSG with dynamic rules and associates it with a given subnet |
| `modules/vm` | Creates a Public IP, NIC, and Linux VM with SSH key auth |

---

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5.0
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed and authenticated
- An existing SSH key pair on the machine running Terraform

---

## Deployment Steps

### 1. Authenticate to Azure

```bash
az login
az account set --subscription "<your-subscription-id>"
```

### 2. Update `terraform.tfvars`

Edit `terraform.tfvars` to match your environment:

```hcl
location            = "East US"            # Azure region
resource_group_name = "k8s-cluster-rg"
admin_username      = "azureuser"
ssh_public_key_path = "~/.ssh/id_rsa.pub"  # path to your SSH public key
master_vm_size      = "Standard_D2s_v3"
worker_vm_size      = "Standard_D2s_v3"
```

### 3. Initialise Terraform

```bash
terraform init
```

### 4. Review the Plan

```bash
terraform plan
```

### 5. Apply

```bash
terraform apply
```

Type `yes` when prompted. Provisioning typically takes 3–5 minutes.

### 6. Retrieve Outputs

```bash
terraform output
```

Example output:

```
master_public_ip  = "20.x.x.x"
master_private_ip = "10.0.1.4"

worker_public_ips  = ["20.x.x.y", "20.x.x.z"]
worker_private_ips = ["10.0.2.4", "10.0.2.5"]

ssh_master  = "ssh azureuser@20.x.x.x"
ssh_workers = ["ssh azureuser@20.x.x.y", "ssh azureuser@20.x.x.z"]
```

---

## SSH Access

```bash
# Master node
ssh azureuser@<master_public_ip>

# Worker node 1
ssh azureuser@<worker1_public_ip>

# Worker node 2
ssh azureuser@<worker2_public_ip>
```

> **Tip:** Use `terraform output ssh_master` and `terraform output ssh_workers` for the exact commands after apply.

---

## Next Steps — Kubernetes Bootstrap (kubeadm)

Once all three VMs are running, proceed with the following on each node:

1. **All nodes** — Install container runtime (containerd), kubelet, kubeadm, kubectl
2. **Master node** — Run `kubeadm init` and configure `kubectl`
3. **Master node** — Deploy a CNI plugin (e.g. Flannel: `kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml`)
4. **Worker nodes** — Run the `kubeadm join` command printed by `kubeadm init`

---

## Teardown

To destroy all provisioned resources:

```bash
terraform destroy
```

> **Warning:** This permanently deletes all VMs, disks, NSGs, and the VNet. Ensure no persistent data remains on the nodes before running this command.
