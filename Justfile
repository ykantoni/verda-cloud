# Convenience wrappers around verda-vm-infra and verda-k8s-infra. Run
# `just <recipe>` from anywhere; paths below are relative to this Justfile,
# not your current directory.
#
# This Justfile computes where verda-vm-infra's state lives itself, every
# time, and exports that into the k8s recipes — so a stale
# TF_VAR_tfstate_location left over in your shell can no longer disagree
# with where the state actually is.

vm_dir := "verda-vm-infra"
k8s_dir := "verda-k8s-infra"
tfstate_path := justfile_directory() / vm_dir / "terraform.tfstate"

# Initialize both repos.
init: vm-init k8s-init

# Apply both repos in order: create/update the VMs, then bootstrap RKE2 onto them.
apply: vm-apply k8s-apply

# Destroy both repos in reverse order: tear down the RKE2 bootstrap bookkeeping, then the VMs.
destroy: k8s-destroy vm-destroy

# Initialize verda-vm-infra (safe to re-run any time; always targets the same path).
vm-init:
    cd {{ vm_dir }} && terraform init -reconfigure -backend-config="path={{ tfstate_path }}"

# Create/update the VMs.
vm-apply:
    cd {{ vm_dir }} && terraform apply

# Destroy the VMs. Run k8s-destroy first if verda-k8s-infra has been applied.
vm-destroy:
    cd {{ vm_dir }} && terraform destroy

# Initialize verda-k8s-infra (run once per checkout).
k8s-init:
    cd {{ k8s_dir }} && terraform init

# Bootstrap/update RKE2 on the VMs over SSH (requires vm-apply to have run first).
k8s-apply:
    #!/usr/bin/env bash
    set -euo pipefail
    export TF_VAR_tfstate_location="{{ tfstate_path }}"
    cd {{ k8s_dir }}
    terraform apply

# Remove RKE2 bootstrap bookkeeping from state (does not uninstall RKE2 itself — see README).
k8s-destroy:
    #!/usr/bin/env bash
    set -euo pipefail
    export TF_VAR_tfstate_location="{{ tfstate_path }}"
    cd {{ k8s_dir }}
    terraform destroy

# Write ~/kubeconfig.yaml for the running cluster.
k8s-config:
    #!/usr/bin/env bash
    set -euo pipefail
    export TF_VAR_tfstate_location="{{ tfstate_path }}"
    cd {{ k8s_dir }}
    eval "$(terraform output -raw kubeconfig_command)"
    echo "Wrote ~/kubeconfig.yaml"
