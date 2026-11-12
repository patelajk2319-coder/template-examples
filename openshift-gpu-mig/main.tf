# =============================================================================
# openshift-gpu-mig: example Coder workspace template for OpenShift
# =============================================================================

terraform {
  required_providers {
    coder      = { source = "coder/coder", version = ">= 2.4.0" }
    kubernetes = { source = "hashicorp/kubernetes" }
  }
}

provider "coder" {}

# In-cluster config: uses the provisioner's ServiceAccount.
provider "kubernetes" {}

# ── Template variables (set by the template admin at push time) ─────────────
variable "namespace" {
  type        = string
  description = "Namespace (Project) for workspace pods. Must already exist."
  default     = "coder-workspaces"
}

variable "image" {
  type        = string
  description = "Workspace image for CPU-only workspaces (from your internal registry)."
  default     = "image-registry.openshift-image-registry.svc:5000/coder-workspaces/ubi9-base-workspace:latest"
}

variable "gpu_image" {
  type        = string
  description = "CUDA-enabled workspace image used when a GPU or MIG slice is selected."
  default     = "image-registry.openshift-image-registry.svc:5000/coder-workspaces/ubi9-cuda-workspace:latest"
}

# single = uniform (every slice on a GPU is the same profile)
# mixed  = heterogeneous (different slice sizes on the same GPU)
variable "mig_strategy" {
  type        = string
  description = "NVIDIA GPU Operator ClusterPolicy spec.mig.strategy: mixed or single."
  default     = "mixed"
  validation {
    condition     = contains(["mixed", "single"], var.mig_strategy)
    error_message = "mig_strategy must be mixed or single."
  }
}

variable "gpu_profiles" {
  type        = string
  description = "Comma-separated MIG profiles users may pick. Must match the profiles on your GPU nodes (oc describe node <gpu-node> | grep nvidia.com/mig)."
  default     = "1g.10gb,2g.20gb,3g.40gb"
}

variable "allow_full_gpu" {
  type        = bool
  description = "Offer a whole (non-MIG) GPU option."
  default     = false
}

variable "gpu_product" {
  type        = string
  description = "Only for mig_strategy=single: value of the nvidia.com/gpu.product label without the -MIG-<profile> suffix, e.g. NVIDIA-A100-SXM4-80GB."
  default     = ""
}

variable "gpu_taint_key" {
  type        = string
  description = "Taint key on GPU nodes that GPU workspaces must tolerate."
  default     = "nvidia.com/gpu"
}

variable "cpu_node_selector" {
  type        = map(string)
  description = "Node labels for CPU-only workspaces, e.g. { \"node-role.kubernetes.io/workspaces\" = \"\" }."
  default     = {}
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# ── Parameters (chosen by the user) ────────────────────────────────────────
data "coder_parameter" "gpu" {
  name         = "gpu"
  display_name = "GPU"
  description  = "GPU allocation. Held only while the workspace is running; change it on restart."
  type         = "string"
  default      = "none"
  mutable      = true
  icon         = "/icon/nvidia.svg"
  option {
    name  = "No GPU"
    value = "none"
  }
  dynamic "option" {
    for_each = local.gpu_profiles
    content {
      name  = "MIG slice ${option.value}"
      value = option.value
    }
  }
  dynamic "option" {
    for_each = var.allow_full_gpu ? ["full"] : []
    content {
      name  = "Full GPU"
      value = "full"
    }
  }
}

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU cores"
  type         = "number"
  default      = "4"
  mutable      = true
  icon         = "/icon/memory.svg"
  option {
    name  = "2 cores"
    value = "2"
  }
  option {
    name  = "4 cores"
    value = "4"
  }
  option {
    name  = "8 cores"
    value = "8"
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory (GB)"
  type         = "number"
  default      = "16"
  mutable      = true
  icon         = "/icon/memory.svg"
  option {
    name  = "8 GB"
    value = "8"
  }
  option {
    name  = "16 GB"
    value = "16"
  }
  option {
    name  = "32 GB"
    value = "32"
  }
}

data "coder_parameter" "disk_size" {
  name         = "disk_size"
  display_name = "Home disk (GB)"
  description  = "Persistent /home/coder volume. Cannot change after create."
  type         = "number"
  default      = "50"
  mutable      = false
  icon         = "/icon/database.svg"
  validation {
    min = 10
    max = 500
  }
}

# Presets: one-click sizes on the create page.
data "coder_workspace_preset" "cpu_dev" {
  name = "CPU dev"
  parameters = {
    gpu    = "none"
    cpu    = "4"
    memory = "16"
  }
}

data "coder_workspace_preset" "gpu_small" {
  count = length(local.gpu_profiles) > 0 ? 1 : 0
  name  = "GPU small (${local.gpu_profiles[0]})"
  parameters = {
    gpu    = local.gpu_profiles[0]
    cpu    = "4"
    memory = "16"
  }
}

# ── Derived GPU settings ────────────────────────────────────────────────────
locals {
  gpu_profiles = compact([for p in split(",", var.gpu_profiles) : trimspace(p)])
  gpu_choice   = data.coder_parameter.gpu.value
  gpu_enabled  = local.gpu_choice != "none"
  is_mig       = local.gpu_enabled && local.gpu_choice != "full"

  # mixed: resource name carries the profile (nvidia.com/mig-1g.10gb).
  # single, or full GPU: always nvidia.com/gpu; the node_selector below picks the profile.
  gpu_resource = (local.is_mig && var.mig_strategy == "mixed"
    ? "nvidia.com/mig-${local.gpu_choice}"
  : "nvidia.com/gpu")

  # single strategy: pick the node by its product label (profile baked into the value).
  # Otherwise just land on any node advertising a GPU.
  gpu_node_selector = (var.mig_strategy == "single" && var.gpu_product != ""
    ? { "nvidia.com/gpu.product" = local.is_mig ? "${var.gpu_product}-MIG-${local.gpu_choice}" : var.gpu_product }
  : { "nvidia.com/gpu.present" = "true" })

  node_selector = local.gpu_enabled ? local.gpu_node_selector : var.cpu_node_selector

  limits = merge(
    {
      cpu    = data.coder_parameter.cpu.value
      memory = "${data.coder_parameter.memory.value}Gi"
    },
    local.gpu_enabled ? { (local.gpu_resource) = "1" } : {}
  )

  labels = {
    "app.kubernetes.io/name"     = "coder-workspace"
    "app.kubernetes.io/instance" = "coder-${data.coder_workspace.me.id}"
    "app.kubernetes.io/part-of"  = "coder"
    "com.coder.workspace.owner"  = data.coder_workspace_owner.me.name
  }
}

# ── Agent ───────────────────────────────────────────────────────────────────
resource "coder_agent" "main" {
  arch = "amd64"
  os   = "linux"

  startup_script = <<-EOT
    #!/bin/bash
    touch ~/.bashrc
    if command -v nvidia-smi >/dev/null 2>&1; then nvidia-smi -L || true; fi
  EOT

  env = {
    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email
  }

  metadata {
    display_name = "CPU"
    key          = "cpu"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }
  metadata {
    display_name = "Memory"
    key          = "mem"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }
  metadata {
    display_name = "GPU"
    key          = "gpu"
    script       = "nvidia-smi -L 2>/dev/null | tail -n 1 | cut -c1-60 || echo none"
    interval     = 60
    timeout      = 5
  }

  display_apps {
    vscode       = true
    web_terminal = true
    ssh_helper   = false
  }
}

# ── Kubernetes resources ────────────────────────────────────────────────────
resource "kubernetes_persistent_volume_claim_v1" "home" {
  metadata {
    name      = "coder-${data.coder_workspace.me.id}-home"
    namespace = var.namespace
    labels    = local.labels
  }
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = { storage = "${data.coder_parameter.disk_size.value}Gi" }
    }
  }
  lifecycle { ignore_changes = all }
}

resource "kubernetes_pod_v1" "workspace" {
  count = data.coder_workspace.me.start_count

  metadata {
    name      = "coder-${data.coder_workspace.me.id}"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    # Workspaces never need the Kubernetes API.
    automount_service_account_token = false
    node_selector                   = local.node_selector

    dynamic "toleration" {
      for_each = local.gpu_enabled ? [1] : []
      content {
        key      = var.gpu_taint_key
        operator = "Exists"
        effect   = "NoSchedule"
      }
    }

    container {
      name              = "dev"
      image             = local.gpu_enabled ? var.gpu_image : var.image
      image_pull_policy = "IfNotPresent"
      # uid_entrypoint adds a passwd entry for the OpenShift-assigned UID.
      command = ["/usr/local/bin/uid_entrypoint", "sh", "-c", coder_agent.main.init_script]

      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }

      resources {
        requests = {
          cpu = "500m"
          # Half the memory limit, min 2Gi, so the scheduler can bin-pack idle workspaces.
          memory = "${max(2, floor(data.coder_parameter.memory.value / 2))}Gi"
        }
        # GPU / MIG is requested via limits (requests default to the same).
        limits = local.limits
      }

      volume_mount {
        name       = "home"
        mount_path = "/home/coder"
      }
      # Larger /dev/shm for PyTorch DataLoader workers (counts against memory).
      volume_mount {
        name       = "dshm"
        mount_path = "/dev/shm"
      }
    }

    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim_v1.home.metadata[0].name
      }
    }
    volume {
      name = "dshm"
      empty_dir {
        medium = "Memory"
        # Quarter of the memory limit, min 1Gi.
        size_limit = "${max(1, floor(data.coder_parameter.memory.value / 4))}Gi"
      }
    }
  }

  # A pod waits here if no matching slice is free; the build fails after this.
  timeouts {
    create = "10m"
  }
}
