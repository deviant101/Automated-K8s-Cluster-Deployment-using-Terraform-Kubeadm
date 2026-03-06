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
  description = "Local filesystem path to the SSH public key file (.pub)"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Local filesystem path to the SSH private key (used by Terraform provisioners)"
  type        = string
}

variable "worker_count" {
  description = "Number of worker nodes to create"
  type        = number
  default     = 2
}

variable "master_vm_size" {
  description = "Azure VM SKU for the master node (min 2 vCPU / 2 GB RAM required by kubeadm)"
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

# ─── Kubernetes ───────────────────────────────────────────────────────────────

variable "kubernetes_version" {
  description = "Kubernetes minor version to install, e.g. \"1.32\" (controls kubeadm/kubelet/kubectl apt repo)"
  type        = string
  default     = "1.32"
}

variable "kubernetes_pkg_version" {
  description = "Exact apt package version string for kubeadm/kubelet/kubectl, e.g. \"1.32.3-1.1\". Leave empty to install the latest in the minor stream."
  type        = string
  default     = ""
}

variable "pod_cidr" {
  description = "CIDR range for Kubernetes pod networking (must not overlap with vnet_address_space or service_cidr)"
  type        = string
  default     = "10.10.0.0/16"
}

variable "service_cidr" {
  description = "CIDR range for Kubernetes Service ClusterIPs"
  type        = string
  default     = "10.96.0.0/12"
}

variable "cilium_version" {
  description = "Cilium CNI version to install via cilium CLI, e.g. \"1.17.2\""
  type        = string
  default     = "1.17.2"
}

# ─── Tags ─────────────────────────────────────────────────────────────────────

variable "tags" {
  description = "Common tags applied to every resource"
  type        = map(string)
  default     = {}
}
