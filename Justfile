# Convenience wrappers around verda-vm-infra and verda-k8s-infra. Run
# `just <recipe>` from anywhere; paths below are relative to this Justfile,
# not your current directory.
#
# tfstate_path honors TF_VAR_tfstate_location from the environment if it's
# set, falling back to verda-vm-infra's own terraform.tfstate otherwise.
# Every recipe below uses this one value, so vm-init's backend and the
# k8s-* recipes' remote-state lookup always agree — but if you've exported
# TF_VAR_tfstate_location, that's what wins. Check `echo $TF_VAR_tfstate_location`
# before running vm-init/apply if you're not intentionally relocating state.

vm_dir := "verda-vm-infra"
k8s_dir := "verda-k8s-infra"
tfstate_path := env_var_or_default("TF_VAR_tfstate_location", justfile_directory() / vm_dir / "terraform.tfstate")

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
vm-apply: vm-init
    cd {{ vm_dir }} && terraform apply -auto-approve

# Destroy the VMs. Run k8s-destroy first if verda-k8s-infra has been applied.
vm-destroy: vm-init
    cd {{ vm_dir }} && terraform destroy -auto-approve

# Initialize verda-k8s-infra (run once per checkout).
k8s-init:
    cd {{ k8s_dir }} && terraform init

# Bootstrap/update RKE2 on the VMs over SSH (requires vm-apply to have run first).
k8s-apply: k8s-init
    #!/usr/bin/env bash
    set -euo pipefail
    export TF_VAR_tfstate_location="{{ tfstate_path }}"
    cd {{ k8s_dir }}
    terraform apply -auto-approve

# Remove RKE2 bootstrap bookkeeping from state (does not uninstall RKE2 itself — see README).
k8s-destroy: k8s-init
    #!/usr/bin/env bash
    set -euo pipefail
    export TF_VAR_tfstate_location="{{ tfstate_path }}"
    cd {{ k8s_dir }}
    terraform destroy -auto-approve

# Write ~/verda_kubeconfig.yaml for the running cluster.
generate: k8s-init
    #!/usr/bin/env bash
    set -euo pipefail
    export TF_VAR_tfstate_location="{{ tfstate_path }}"
    cd {{ k8s_dir }}
    eval "$(terraform output -raw kubeconfig_command)"
    echo "Wrote ~/verda_kubeconfig.yaml"
