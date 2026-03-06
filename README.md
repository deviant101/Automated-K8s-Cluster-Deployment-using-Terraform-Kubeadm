## Automated Kubernetes Cluster Deployment on Azure using Terraform, kubeadm, and Cilium

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.5-7B42BC?logo=terraform)
![Cilium](https://img.shields.io/badge/CNI-Cilium-F8C517?logo=cilium)
![Azure](https://img.shields.io/badge/Cloud-Azure-0078D4?logo=microsoftazure)

> Fully automated, zero-touch Kubernetes cluster deployment on Azure using Terraform, Kubeadm, Cilium, and cloud-init. One command: `terraform apply`.

**What gets automated:**
- Azure infrastructure (VNet, subnets, NSGs, VMs) provisioned by Terraform
- OS-level node preparation via cloud-init (containerd, kubeadm, kubelet, kubectl)
- Control-plane bootstrap via `kubeadm init`
- [Cilium](https://cilium.io) CNI deployed with full kube-proxy replacement (eBPF)
- Worker nodes joined automatically — no manual SSH required

---

## Architecture Diagram

```
                   ┌──────────────────────────────────────────────────────────────────────┐
                   │                Azure Virtual Network  10.0.0.0/16                    │
                   │                                                                      │
                   │  ┌────────────────────────────────┐   ┌───────────────────────────┐  │
                   │  │  master-subnet  10.0.1.0/24    │   │  worker-subnet 10.0.2.0/24│  │
                   │  │  NSG: master-nsg               │   │  NSG: worker-nsg          │  │
                   │  │                                │   │                           │  │
                   │  │  ┌──────────────────────────┐  │   │  ┌─────────────────────┐  │  │
                   │  │  │  k8s-master              │  │   │  │  k8s-worker-1       │  │  │
                   │  │  │  Standard_B2s            │  │   │  │  Standard_B2s       │  │  │
                   │  │  │  Ubuntu 22.04 LTS        │  │   │  │  Ubuntu 22.04 LTS   │  │  │
                   │  │  │  kubeadm control-plane   │  │   │  └─────────────────────┘  │  │
                   │  │  │  Cilium CNI agent        │  │   │                           │  │
                   │  │  │  Hubble observability    │  │   │  ┌─────────────────────┐  │  │
                   │  │  └──────────────────────────┘  │   │  │  k8s-worker-2       │  │  │
                   │  │                                │   │  │  Standard_B2s       │  │  │
                   │  └────────────────────────────────┘   │  │  Ubuntu 22.04 LTS   │  │  │
                   │                                       │  └─────────────────────┘  │  │
                   │                                       └───────────────────────────┘  │
                   └──────────────────────────────────────────────────────────────────────┘

  Pod network (VXLAN tunnel):  10.10.0.0/16   ← Cilium cluster-pool IPAM
  Service ClusterIP range:     10.96.0.0/12
```

---

## Resource Summary

| Resource | Name | Details |
|---|---|---|
| Resource Group | `farrukh-k8s-cluster-rg` | Contains all cluster resources |
| Virtual Network | `k8s-vnet` | `10.0.0.0/16` |
| Control-Plane Subnet | `master-subnet` | `10.0.1.0/24` |
| Worker Subnet | `worker-subnet` | `10.0.2.0/24` |
| NSG (control-plane) | `master-nsg` | Attached at subnet level |
| NSG (workers) | `worker-nsg` | Attached at subnet level |
| Control-Plane VM | `k8s-master` | `Standard_B2s`, Ubuntu 22.04 LTS Gen2 |
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

> **Minimum requirements note:** kubeadm requires at least 2 vCPU and 2 GB RAM per node. `Standard_B2s` (2 vCPU, 4 GB) meets these requirements. For production workloads consider `Standard_D4s_v5` (4 vCPU, 16 GB) for the control-plane.

---

## Network Security Groups

NSGs are enforced at the **subnet level**, meaning rules apply to every VM in the subnet without needing per-NIC configuration.

### Control-Plane NSG (`master-nsg`) — `master-subnet`

#### Inbound Rules

| Priority | Name | Port(s) | Protocol | Source | Purpose |
|---|---|---|---|---|---|
| 100 | Allow-SSH-Inbound | 22 | TCP | `*` | SSH management access |
| 110 | Allow-KubeAPI-Inbound | 6443 | TCP | `*` | Kubernetes API server (kubectl + all nodes) |
| 120 | Allow-etcd-Inbound | 2379–2380 | TCP | `10.0.1.0/24` (master subnet) | etcd client & peer communication |
| 130 | Allow-Kubelet-API-Inbound | 10250 | TCP | `10.0.0.0/16` (VNet) | Kubelet API (kube-apiserver ↔ kubelet) |
| 140 | Allow-KubeControllerManager-Inbound | 10257 | TCP | `10.0.1.0/24` (master subnet) | kube-controller-manager health/metrics |
| 150 | Allow-KubeScheduler-Inbound | 10259 | TCP | `10.0.1.0/24` (master subnet) | kube-scheduler health/metrics |
| 160 | Allow-Cilium-VXLAN-Inbound | 8472 | UDP | `10.0.0.0/16` (VNet) | Cilium VXLAN overlay tunnel (pod traffic) |
| 170 | Allow-Cilium-Health-Inbound | 4240 | TCP | `10.0.0.0/16` (VNet) | Cilium health check between nodes |
| 180 | Allow-Hubble-Server-Inbound | 4244 | TCP | `10.0.0.0/16` (VNet) | Hubble observability gRPC API |
| 190 | Allow-Cilium-ICMP-Health-Inbound | ICMP | ICMP | `10.0.0.0/16` (VNet) | Cilium node-to-node health probing |

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
| 120 | Allow-KubeProxy-Health-Inbound | 10256 | TCP | `10.0.0.0/16` (VNet) | kube-proxy/Cilium health check endpoint |
| 130 | Allow-NodePort-Inbound | 30000–32767 | TCP | `*` | Kubernetes NodePort services (external traffic) |
| 140 | Allow-Cilium-VXLAN-Inbound | 8472 | UDP | `10.0.0.0/16` (VNet) | Cilium VXLAN overlay tunnel (pod traffic) |
| 150 | Allow-Cilium-Health-Inbound | 4240 | TCP | `10.0.0.0/16` (VNet) | Cilium health check between nodes |
| 160 | Allow-Hubble-Server-Inbound | 4244 | TCP | `10.0.0.0/16` (VNet) | Hubble observability gRPC API |
| 170 | Allow-Cilium-ICMP-Health-Inbound | ICMP | ICMP | `10.0.0.0/16` (VNet) | Cilium node-to-node health probing |

#### Outbound Rules

| Priority | Name | Port(s) | Protocol | Destination | Purpose |
|---|---|---|---|---|---|
| 100 | Allow-All-Outbound | `*` | `*` | `*` | Allow all outbound traffic |

---

## Terraform Module Structure

```
.
├── main.tf                        # Provider, Resource Group, modules, NSG rules, bootstrap provisioners
├── variables.tf                   # All input variable declarations
├── outputs.tf                     # IPs, SSH commands, kubeconfig helpers
├── terraform.tfvars               # Variable values (edit before apply)
├── terraform.tfvars.example       # Template for new environments
├── join-command.sh                # Auto-generated during apply (kubeadm join cmd)
├── scripts/
│   ├── common-node-setup.sh       # Cloud-init: installs containerd, kubeadm, kubelet, kubectl
│   ├── master-init.sh             # kubeadm init + Cilium install (runs via remote-exec)
│   └── worker-join.sh             # kubeadm join helper (runs via remote-exec)
└── modules/
    ├── vnet/
    │   ├── main.tf                # azurerm_virtual_network + master & worker subnets
    │   ├── variables.tf
    │   └── outputs.tf
    ├── nsg/
    │   ├── main.tf                # azurerm_network_security_group + subnet association
    │   ├── variables.tf
    │   └── outputs.tf
    └── vm/
        ├── main.tf                # Public IP, NIC, azurerm_linux_virtual_machine (with custom_data)
        ├── variables.tf
        └── outputs.tf
```

---

## Automation Flow

Terraform automates the complete cluster lifecycle in three phases:

```
terraform apply
     │
     ├─ Phase 0: Infrastructure
     │      Azure Resource Group
     │      VNet + Subnets (master-subnet, worker-subnet)
     │      NSGs + Subnet Associations
     │      VMs with cloud-init (common-node-setup.sh via custom_data)
     │           └─ Runs on first boot (background):
     │                  disable swap, kernel modules, sysctl
     │                  install containerd (SystemdCgroup=true)
     │                  install kubeadm / kubelet / kubectl (pinned version)
     │
     ├─ Phase 1: Control-Plane Init  (null_resource.master_bootstrap)
     │      SSH into k8s-master
     │      Upload + run master-init.sh:
     │           wait for cloud-init sentinel (/var/lib/k8s-common-setup-done)
     │           kubeadm init --skip-phases=addon/kube-proxy
     │           configure kubectl for azureuser
     │           install Cilium CLI
     │           cilium install --set kubeProxyReplacement=true
     │           cilium status --wait
     │           write join-command.sh to ~/join-command.sh
     │
     ├─ Phase 2: Fetch Join Command  (null_resource.fetch_join_command)
     │      SCP ~/join-command.sh from master → local ./join-command.sh
     │
     └─ Phase 3: Worker Join  (null_resource.worker_join × N)
            SSH into each k8s-worker-N (in parallel)
            Upload join-command.sh + worker-join.sh
            run worker-join.sh:
                 wait for cloud-init sentinel
                 sudo bash join-command.sh
```

---

## Key Variables

| Variable | Default | Description |
|---|---|---|
| `kubernetes_version` | `1.32` | Minor version — controls apt repo and image tags |
| `kubernetes_pkg_version` | `""` | Exact apt pkg version (e.g. `1.32.3-1.1`). Empty = latest patch |
| `pod_cidr` | `10.10.0.0/16` | Pod network CIDR (must not overlap VNet or service CIDR) |
| `service_cidr` | `10.96.0.0/12` | Service ClusterIP CIDR |
| `cilium_version` | `1.17.2` | Cilium CNI version to install |
| `worker_count` | `2` | Number of worker nodes |
| `ssh_private_key_path` | — | Path to SSH private key (used by provisioners) |

---

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5.0
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed and authenticated
- An SSH key pair — both the public key (for VMs) and private key (for Terraform provisioners)
- `scp` available on the machine running Terraform (used to fetch the join command)

---

## Deployment Steps

### 1. Authenticate to Azure

```bash
az login
az account set --subscription "<your-subscription-id>"
```

### 2. Generate an SSH key pair (if you don't have one)

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa_azure -N ""
```

### 3. Update `terraform.tfvars`

At minimum, verify these values match your environment:

```hcl
resource_group_name  = "farrukh-k8s-cluster-rg"
location             = "East US"
ssh_public_key_path  = "~/.ssh/id_rsa_azure.pub"
ssh_private_key_path = "~/.ssh/id_rsa_azure"
kubernetes_version   = "1.32"
cilium_version       = "1.17.2"
worker_count         = 2
```

### 4. Initialise Terraform

```bash
terraform init
```

### 5. Review the Plan

```bash
terraform plan
```

### 6. Apply — Full Automated Deployment

```bash
terraform apply
```

Type `yes` when prompted.

**Expected duration:** ~15–25 minutes total:
- VMs + networking: ~5 min
- cloud-init (common node setup): ~5–8 min per node (runs in background)
- Master bootstrap (kubeadm init + Cilium): ~5–8 min
- Worker join: ~2–3 min per worker

### 7. Retrieve Outputs

```bash
terraform output
```

### 8. Download the kubeconfig and verify the cluster

```bash
# Download kubeconfig
scp -i ~/.ssh/id_rsa_azure azureuser@<master_public_ip>:/home/azureuser/admin.kubeconfig ./kubeconfig

# Or use the helper output:
$(terraform output -raw get_kubeconfig)

# Verify cluster nodes
KUBECONFIG=./kubeconfig kubectl get nodes -o wide

# Check Cilium status
KUBECONFIG=./kubeconfig cilium status
```

Expected output:
```
NAME           STATUS   ROLES           AGE   VERSION   INTERNAL-IP   OS-IMAGE
k8s-master     Ready    control-plane   10m   v1.32.x   10.0.1.4      Ubuntu 22.04 LTS
k8s-worker-1   Ready    <none>          5m    v1.32.x   10.0.2.4      Ubuntu 22.04 LTS
k8s-worker-2   Ready    <none>          5m    v1.32.x   10.0.2.5      Ubuntu 22.04 LTS
```

---

## Troubleshooting

### Check cloud-init progress on a node

```bash
ssh -i ~/.ssh/id_rsa_azure azureuser@<node_ip> 'sudo tail -f /var/log/k8s-common-setup.log'
```

### Check master bootstrap log

```bash
ssh -i ~/.ssh/id_rsa_azure azureuser@<master_ip> 'sudo tail -f /var/log/k8s-master-init.log'
```

### Check kubeadm init log

```bash
ssh -i ~/.ssh/id_rsa_azure azureuser@<master_ip> 'sudo cat /var/log/kubeadm-init.log'
```

### Check Cilium status

```bash
ssh -i ~/.ssh/id_rsa_azure azureuser@<master_ip> \
  'KUBECONFIG=/etc/kubernetes/admin.conf sudo -E cilium status'
```

### Check worker join log

```bash
ssh -i ~/.ssh/id_rsa_azure azureuser@<worker_ip> 'sudo cat /var/log/k8s-worker-join.log'
```

---

## SSH Access

```bash
# Master node
ssh -i ~/.ssh/id_rsa_azure azureuser@$(terraform output -raw master_public_ip)

# Worker nodes
ssh -i ~/.ssh/id_rsa_azure azureuser@$(terraform output -json worker_public_ips | jq -r '.[0]')
ssh -i ~/.ssh/id_rsa_azure azureuser@$(terraform output -json worker_public_ips | jq -r '.[1]')
```

---

## Teardown

To destroy all provisioned resources:

```bash
# Clean up the local join command file first
rm -f ./join-command.sh ./kubeconfig

terraform destroy
```

> **Warning:** This permanently deletes all VMs, disks, NSGs, and the VNet. Ensure no persistent data remains on the nodes before running this command.

