# openshift-gpu-mig (example Coder template)

One template for CPU and GPU workspaces on OpenShift. Users pick **No GPU**, a
**MIG slice** (e.g. `1g.10gb`), or optionally a **full GPU**, and can change it
on restart. Stopping a workspace deletes the pod, freeing the slice;
`/home/coder` persists on a PVC.

## Prerequisites (cluster admin)

1. Node Feature Discovery + NVIDIA GPU Operator installed with a `ClusterPolicy`.
2. MIG configured on GPU nodes: `spec.mig.strategy` set (`mixed` or `single`),
   nodes labelled with a profile, e.g.
   `oc label node <node> nvidia.com/mig.config=all-1g.10gb --overwrite`.
3. Check what each node actually advertises, and make sure the Terraform
   variables `gpu_profiles`, `mig_strategy`, and `gpu_product` (see
   Terraform variables below) are set to match exactly. Kubernetes does
   exact string matching on the resource name — no match means no error,
   just a workspace pod stuck `Pending` forever.
   `oc describe node <gpu-node> | grep -E 'nvidia.com/(gpu|mig)'`
   - `mixed`: resources like `nvidia.com/mig-1g.10gb: 7`
   - `single`: `nvidia.com/gpu: 7` plus label `nvidia.com/gpu.product=<product>-MIG-1g.10gb`
4. Note the taint key on GPU nodes if tainted (default here: `nvidia.com/gpu`).
5. The provisioner ServiceAccount can create pods/PVCs in the workspace namespace.

## Disconnected Terraform providers

The provisioner runs `terraform init` for this template same as any other —
on a fully air-gapped cluster it can't reach `registry.terraform.io`, so give
it a filesystem mirror instead:

1. From a machine with internet access, mirror the two providers this
   template uses:
   ```bash
   terraform providers mirror -platform=linux_amd64 ./provider-mirror
   ```
2. Copy `./provider-mirror` somewhere the provisioner pod can read (an
   internal artefact store, a ConfigMap/PVC mounted into the pod, etc.).
3. Point Terraform at it via a CLI config file on the provisioner
   (`TF_CLI_CONFIG_FILE`, or the default `~/.terraformrc`):
   ```hcl
   provider_installation {
     filesystem_mirror {
       path    = "/path/to/provider-mirror"
       include = ["coder/coder", "hashicorp/kubernetes"]
     }
     direct {
       exclude = ["coder/coder", "hashicorp/kubernetes"]
     }
   }
   ```
4. Re-run `terraform init` / `coder templates push` — providers now resolve
   from the mirror. Re-mirror whenever `required_providers` versions change.

## Terraform variables (set by admins, at push time)

| Variable | Default | Set to |
|---|---|---|
| `namespace` | `coder-workspaces` | The OpenShift Project workspace pods run in |
| `image` | internal registry `ubi9-base-workspace` | Your CPU-only pod image, from your registry |
| `gpu_image` | internal registry `ubi9-cuda-workspace` | Your CUDA pod image, from your registry |
| `mig_strategy` | `mixed` | Your ClusterPolicy's `spec.mig.strategy` |
| `gpu_profiles` | `1g.10gb,2g.20gb,3g.40gb` | The MIG profiles your GPU nodes expose |
| `allow_full_gpu` | `false` | `true` to also offer a whole (non-MIG) GPU |
| `gpu_product` | `""` | `single` strategy only — your nodes' `nvidia.com/gpu.product` value, e.g. `NVIDIA-A100-SXM4-80GB` |
| `gpu_taint_key` | `nvidia.com/gpu` | The taint key on your GPU nodes |
| `cpu_node_selector` | `{}` | Node labels for your CPU-only node pool |

Profile names depend on the GPU model (A100 40GB: `1g.5gb`, `2g.10gb`,
`3g.20gb`; A100/H100 80GB: `1g.10gb`, `2g.20gb`, `3g.40gb`).

## Pushing the template (admin)

A variables file keeps the values above explicit across versions:

```bash
cat > openshift-gpu-mig/vars.yaml <<'V'
namespace: coder-workspaces
mig_strategy: mixed
gpu_profiles: 1g.10gb,3g.40gb
V
```

Via the repo-root Taskfile (see top-level README; needs `.env` with
`CODER_URL`/`CODER_SESSION_TOKEN`):

```bash
task push TEMPLATE=openshift-gpu-mig VARS_FILE=openshift-gpu-mig/vars.yaml
```

Or directly with the Coder CLI from inside this directory:

```bash
coder templates push openshift-gpu-mig -d . --variables-file vars.yaml
```

## Workspace parameters (chosen by Coder users)

| Parameter | Options | Mutable |
|---|---|---|
| `gpu` | No GPU / a MIG slice from the `gpu_profiles` Terraform variable / Full GPU (if the `allow_full_gpu` Terraform variable is `true`) | Yes — change on restart |
| `cpu` | 2 / 4 / 8 cores | Yes |
| `memory` | 8 / 16 / 32 GB | Yes |
| `disk_size` | 10–500 GB, default 50 | No — fixed at create |

## Workspace images (restricted-v2)

OpenShift assigns a random UID in group 0, so the image must make
`/home/coder` and `/etc/passwd` group-writable (GID 0) and ship
`/usr/local/bin/uid_entrypoint` to add a passwd entry for that UID.

The CUDA driver comes from the node (GPU Operator) — the image only needs
user-space CUDA libraries at a version the node driver supports:

```dockerfile
# Mirror this base into your registry first; pick a CUDA version your driver supports.
FROM nvcr.io/nvidia/cuda:12.4.1-runtime-ubi9
RUN dnf install -y --nodocs git python3.11 python3.11-pip procps-ng && dnf clean all
RUN useradd --uid 1001 --create-home --shell /bin/bash coder \
 && chgrp -R 0 /home/coder && chmod -R g=u /home/coder && chmod g=u /etc/passwd
COPY uid_entrypoint.sh /usr/local/bin/uid_entrypoint
RUN chmod 0755 /usr/local/bin/uid_entrypoint
USER 1001
WORKDIR /home/coder
```

A working `uid_entrypoint.sh` is included in this directory — no external
dependency to fetch at build time.

Pre-install what users need (Python, PyTorch, Jupyter, IDE servers) — no root
on `restricted-v2`, and disconnected clusters can't fetch packages at
start-up unless pip/conda point at an internal mirror.

## Controlling GPU use

- **Who:** restrict this template (or a GPU-only copy) to a group via
  template permissions.
- **How many slices per team:** a ResourceQuota on each team namespace:
  ```yaml
  apiVersion: v1
  kind: ResourceQuota
  metadata:
    name: gpu-quota
    namespace: ws-ml-team
  spec:
    hard:
      requests.nvidia.com/mig-1g.10gb: "8"
      requests.nvidia.com/mig-3g.40gb: "2"
  ```
- **Idle slices:** a running workspace holds its slice even when idle — set a
  short autostop/activity bump on the template (autostop requirement on
  Premium) so idle GPU workspaces stop.
- **No free slice:** the pod stays Pending and the build fails after the pod
  creation timeout (10m here). Users retry or pick a smaller profile.

## Notes

- `automount_service_account_token = false` — workspaces get no Kubernetes API token.
- `/dev/shm` is memory-backed and sized to 1/4 of the memory limit, for
  PyTorch DataLoader workers.
- If agents reach coderd via an in-cluster URL instead of the external Access
  URL, apply the `replace()` on `coder_agent.main.init_script` from the
  reference architecture.
- No Coder registry modules are used, so pushing needs only the `coder/coder`
  and `hashicorp/kubernetes` providers. Add modules (code-server, JupyterLab,
  etc.) as needed and vendor them for air-gapped use.
