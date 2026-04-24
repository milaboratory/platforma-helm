variable "project_id" {
  type        = string
  description = "GCP project ID to deploy into."
}

variable "region" {
  type        = string
  description = "GCP region for regional resources."
  default     = "europe-west1"
}

variable "zone_suffix" {
  type        = string
  description = "Zone suffix (a/b/c/d) within the region, used for zonal resources (Filestore Zonal, persistent disks). Cannot be changed after initial deployment without data migration."
  default     = "b"

  validation {
    condition     = can(regex("^[a-d]$", var.zone_suffix))
    error_message = "zone_suffix must be one of: a, b, c, d."
  }
}

variable "cluster_name" {
  type        = string
  description = "GKE cluster name. Lowercase alphanumeric + hyphens, 1-25 chars."
  default     = "platforma-cluster"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,24}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric with hyphens, 1-25 chars, starting with a letter or digit."
  }
}

variable "vpc_name" {
  type        = string
  description = "VPC network name."
  default     = "platforma-vpc"
}

variable "subnet_nodes_cidr" {
  type        = string
  description = "Primary CIDR for the GKE node subnet."
  default     = "10.0.0.0/20"
}

variable "subnet_pods_cidr" {
  type        = string
  description = "Secondary CIDR for pod IPs (VPC-native GKE)."
  default     = "10.1.0.0/16"
}

variable "subnet_services_cidr" {
  type        = string
  description = "Secondary CIDR for Kubernetes service IPs."
  default     = "10.2.0.0/20"
}

variable "system_pool_machine_type" {
  type        = string
  description = "Machine type for system node pool (Platforma server, Kueue, controllers)."
  default     = "n2d-standard-4"
}

variable "system_pool_node_count" {
  type        = number
  description = "Number of nodes in the system pool (fixed, not autoscaled)."
  default     = 2
}

variable "ui_pool_machine_type" {
  type        = string
  description = "Machine type for UI node pool."
  default     = "n2d-standard-4"
}

variable "ui_pool_max_nodes" {
  type        = number
  description = "Max nodes in the UI pool (scales from 0)."
  default     = 4
}

variable "batch_pool_machine_type" {
  type        = string
  description = "Machine type for batch node pool."
  default     = "n2d-standard-16"
}

variable "batch_pool_max_nodes" {
  type        = number
  description = "Max nodes in the batch pool (scales from 0)."
  default     = 4
}

variable "batch_pool_disk_size_gb" {
  type        = number
  description = "Boot disk size for batch nodes. Counts against Persistent Disk SSD quota."
  default     = 100
}

variable "kueue_max_job_cpu" {
  type        = number
  description = "Max vCPU per single job. Must fit in batch machine type after GKE daemonset overhead (~1.5 vCPU)."
  default     = 62
}

variable "kueue_max_job_memory" {
  type        = string
  description = "Max memory per single job. Must fit in batch machine type after overhead (~10 GiB)."
  default     = "500Gi"
}

variable "kueue_batch_queue_cpu" {
  type        = number
  description = "ClusterQueue CPU quota for the batch pool (total across parallel jobs)."
  default     = 256
}

variable "kueue_batch_queue_memory" {
  type        = string
  description = "ClusterQueue memory quota for the batch pool."
  default     = "2048Gi"
}

variable "filestore_tier" {
  type        = string
  description = "Filestore tier. ZONAL (SSD, 1 TiB min) is the recommended production default — HDD does not handle real bioinformatics load. BASIC_SSD (2.5 TiB min), REGIONAL (multi-zone SSD, 1 TiB min) and ENTERPRISE are SSD alternatives. BASIC_HDD (1 TiB min) is kept for testing only; not suitable for production workloads."
  default     = "ZONAL"

  validation {
    condition     = contains(["ZONAL", "BASIC_SSD", "BASIC_HDD", "REGIONAL", "ENTERPRISE"], var.filestore_tier)
    error_message = "filestore_tier must be one of: ZONAL, BASIC_SSD, BASIC_HDD, REGIONAL, ENTERPRISE."
  }
}

variable "workspace_capacity_gb" {
  type        = number
  description = "Filestore capacity in GiB (min 1024 for ZONAL; resize later via gcloud)."
  default     = 1024

  validation {
    condition     = var.workspace_capacity_gb >= 1024
    error_message = "workspace_capacity_gb must be >= 1024 (1 TiB)."
  }
}

variable "workspace_share_name" {
  type        = string
  description = "Filestore file share name (mount path on the instance)."
  default     = "platforma"
}

variable "gcs_bucket_name" {
  type        = string
  description = "Primary GCS bucket name. Empty = auto-generate 'platforma-<cluster>-<random>'."
  default     = ""
}

variable "platforma_namespace" {
  type        = string
  description = "Kubernetes namespace for Platforma. Used in Workload Identity trust bindings."
  default     = "platforma"
}

variable "helm_release_name" {
  type        = string
  description = "Helm release name for Platforma. K8s service accounts will be named <release>-platforma and <release>-platforma-jobs."
  default     = "platforma"
}

variable "kueue_version" {
  type        = string
  description = "Kueue Helm chart version."
  default     = "0.16.1"
}

variable "appwrapper_version" {
  type        = string
  description = "AppWrapper release tag (used in install.yaml URL)."
  default     = "v1.2.0"
}

variable "license_key" {
  type        = string
  description = "Platforma license key (MI_LICENSE)."
  sensitive   = true
}

variable "platforma_chart_version" {
  type        = string
  description = "Platforma chart version (empty = use chart default)."
  default     = ""
}

variable "ingress_enabled" {
  type        = bool
  description = "Enable ingress. Spike default: false (use kubectl port-forward)."
  default     = false
}

variable "admin_username" {
  type        = string
  description = "Default admin username for htpasswd auth."
  default     = "platforma"
}
