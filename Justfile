# Convenience wrappers around verda-vm-infra and verda-k8s-infra. Run
# `just <recipe>` from anywhere; paths below are relative to this Justfile,
# not your current directory.
#
# tfstate_path honors TF_VAR_tfstate_location from the environment if it's
# set, falling back to verda-vm-infra's own terraform.tfstate otherwise.
# vm-init's backend and verda-k8s-infra's remote-state lookup (used only
# for argocd_admin_password_command) both use this one value — but if
# you've exported TF_VAR_tfstate_location, that's what wins. Check
# `echo $TF_VAR_tfstate_location` before running vm-init/apply if you're
# not intentionally relocating state.
#
# kubeconfig_path is the same idea for the kubeconfig verda-vm-infra
# generates while bootstrapping RKE2: verda-k8s-infra's helm provider
# (which installs Argo CD) reads it from there.

vm_dir := "verda-vm-infra"
k8s_dir := "verda-k8s-infra"
tfstate_path := env_var_or_default("TF_VAR_tfstate_location", justfile_directory() / vm_dir / "terraform.tfstate")
kubeconfig_path := env_var_or_default("TF_VAR_kubeconfig_path", justfile_directory() / vm_dir / ".terraform-kubeconfig.yaml")

# Initialize both repos.
init: vm-init k8s-init

# Apply both repos in order: create/update the VMs and bootstrap RKE2+Cilium onto them, then install Argo CD.
apply: vm-apply k8s-apply

# Destroy both repos in reverse order: uninstall Argo CD, then tear down the VMs (which also removes RKE2).
destroy: k8s-destroy vm-destroy

# Initialize verda-vm-infra (safe to re-run any time; always targets the same path).
vm-init:
    cd {{ vm_dir }} && terraform init -reconfigure -backend-config="path={{ tfstate_path }}"

# Create/update the VMs, and bootstrap RKE2+Cilium onto them.
vm-apply: vm-init
    cd {{ vm_dir }} && terraform apply -auto-approve

# Destroy the VMs (and, with them, RKE2). Run k8s-destroy first if verda-k8s-infra has been applied.
vm-destroy: vm-init
    cd {{ vm_dir }} && terraform destroy -auto-approve

# Write ~/verda_kubeconfig.yaml and ~/verda_gateway_hosts for the running cluster, and print credentials + the /etc/hosts line.
generate: vm-init
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{ vm_dir }}
    # `terraform output -raw` on an output that can't resolve (e.g. no
    # cp1_ip because nothing is actually applied) prints nothing and still
    # exits 0 — no error to catch. Left unchecked, `eval "$(...)"` would
    # then no-op and this recipe would print "Wrote ..." while silently
    # leaving a stale ~/verda_kubeconfig.yaml (pointing at a possibly
    # since-destroyed cluster) in place. Check for emptiness explicitly.
    CMD="$(terraform output -raw kubeconfig_command)"
    if [ -z "$CMD" ]; then
        echo "Error: kubeconfig_command is empty — is verda-vm-infra actually applied? Run 'just vm-apply' first." >&2
        exit 1
    fi
    eval "$CMD"
    echo "Wrote ~/verda_kubeconfig.yaml"

    WORKER_IP="$(terraform output -raw worker1_ip)"
    if [ -z "$WORKER_IP" ]; then
        echo "Error: worker1_ip is empty — is verda-vm-infra actually applied? Run 'just vm-apply' first." >&2
        exit 1
    fi
    HOSTS_LINE="$WORKER_IP longhorn.lab openbao.lab grafana.lab prometheus.lab"
    echo "$HOSTS_LINE" > ~/verda_gateway_hosts
    echo "Wrote ~/verda_gateway_hosts. Add this to /etc/hosts to resolve the Gateway API hostnames:"
    echo "  $HOSTS_LINE"
    echo "  (sudo tee -a /etc/hosts < ~/verda_gateway_hosts)"
    echo

    # Best-effort credential lookup: each of these depends on something
    # that may not exist yet (verda-k8s-infra applied, kube-prometheus-stack
    # synced, OpenBao ever unsealed) — none of that should abort the rest
    # of this recipe, so every lookup below is allowed to fail quietly and
    # fall back to a placeholder instead.
    echo "Credentials:"
    ARGOCD_PASS=""
    ARGOCD_CMD="$(cd "{{ justfile_directory() / k8s_dir }}" && TF_VAR_tfstate_location="{{ tfstate_path }}" terraform output -raw argocd_admin_password_command 2>/dev/null || true)"
    if [ -n "$ARGOCD_CMD" ]; then
        ARGOCD_PASS="$(eval "$ARGOCD_CMD" 2>/dev/null || true)"
    fi
    printf '%-10s %s\n' "Argo CD" "admin / ${ARGOCD_PASS:-<not available — is verda-k8s-infra applied?>}"

    GRAFANA_PASS=""
    if command -v kubectl >/dev/null 2>&1; then
        GRAFANA_PASS="$(kubectl --kubeconfig ~/verda_kubeconfig.yaml -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    fi
    printf '%-10s %s\n' "Grafana" "admin / ${GRAFANA_PASS:-<not available — is kube-prometheus-stack synced?>}"

    OPENBAO_TOKEN=""
    if [ -f ~/.openbao-unseal-keys ]; then
        OPENBAO_TOKEN="$(sed -n 's/^# Root token: //p' ~/.openbao-unseal-keys | head -1)"
    fi
    printf '%-10s %s\n' "OpenBao" "root token: ${OPENBAO_TOKEN:-<not available — run 'just unseal' first>}"

# Initialize verda-k8s-infra (run once per checkout).
k8s-init:
    cd {{ k8s_dir }} && terraform init

# Install/update Argo CD, then unseal OpenBao and wire it up as ESO's backend (both automatic; a missing HF token just skips that one step — see configure-vllm-secret).
k8s-apply: k8s-init
    #!/usr/bin/env bash
    set -euo pipefail
    export TF_VAR_tfstate_location="{{ tfstate_path }}"
    export TF_VAR_kubeconfig_path="{{ kubeconfig_path }}"
    cd {{ k8s_dir }}
    terraform apply -auto-approve
    cd {{ justfile_directory() }}
    {{ k8s_dir }}/scripts/unseal-openbao.sh
    {{ k8s_dir }}/scripts/configure-vllm-secret.sh

# Uninstall Argo CD.
k8s-destroy: k8s-init
    #!/usr/bin/env bash
    set -euo pipefail
    export TF_VAR_tfstate_location="{{ tfstate_path }}"
    export TF_VAR_kubeconfig_path="{{ kubeconfig_path }}"
    cd {{ k8s_dir }}
    terraform destroy -auto-approve

# Unseal OpenBao using keys from ~/.openbao-unseal-keys (lab convenience — see verda-k8s-infra's README).
unseal:
    {{ k8s_dir }}/scripts/unseal-openbao.sh

# Wire OpenBao up as External Secrets Operator's backend for the vLLM Hugging Face token. Already runs automatically on 'just k8s-apply' — this is for reruns, e.g. 'HF_TOKEN=hf_xxx just configure-vllm-secret' once you have a token.
configure-vllm-secret:
    {{ k8s_dir }}/scripts/configure-vllm-secret.sh

# Print NodePort and Gateway API endpoints for Argo CD, Grafana, Prometheus, OpenBao, Longhorn UI and Hubble UI.
endpoints:
    #!/usr/bin/env bash
    set -euo pipefail
    export TF_VAR_tfstate_location="{{ tfstate_path }}"
    IP="$(cd {{ vm_dir }} && terraform output -raw cp1_ip)"
    echo "Using cp1's IP ($IP) — any node's IP works, NodePorts/Gateway bind on every node."
    echo
    printf '%-12s %s\n' "Argo CD"     "https://$IP:30443  (admin / terraform output -raw argocd_admin_password_command, in verda-k8s-infra)"
    printf '%-12s %s\n' "Grafana"     "http://$IP:30091   (admin / see verda-k8s-infra README for the password-fetch command)"
    printf '%-12s %s\n' "Prometheus"  "http://$IP:30090"
    printf '%-12s %s\n' "OpenBao"     "http://$IP:30092   (root token in ~/.openbao-unseal-keys — just unseal)"
    printf '%-12s %s\n' "Longhorn UI" "http://$IP:30093"
    printf '%-12s %s\n' "Hubble UI"   "http://$IP:30094   (Cilium's live network flow/service map)"
    echo
    echo "Same four apps, also reachable one port at a time via Gateway API"
    echo "(Verda intercepts 80/443 on every node's public IP at its own edge,"
    echo "so the Gateway is exposed as a NodePort instead, same as everything"
    echo "else above — the actual port is whatever Kubernetes assigned, read"
    echo "live below). 'just generate' writes ~/verda_gateway_hosts with the"
    echo "hostname mapping; append it to /etc/hosts on the machine you're"
    echo "browsing from:"
    echo "  sudo tee -a /etc/hosts < ~/verda_gateway_hosts"
    echo
    if [ -f ~/verda_kubeconfig.yaml ] && command -v kubectl >/dev/null 2>&1; then
        GW_PORT="$(kubectl --kubeconfig ~/verda_kubeconfig.yaml -n kube-system get svc cilium-gateway-lab-gateway -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
    else
        GW_PORT=""
    fi
    if [ -z "$GW_PORT" ]; then
        echo "(Couldn't read the Gateway's NodePort — need a local kubectl and"
        echo " ~/verda_kubeconfig.yaml from 'just generate'. Once you have both:)"
        echo "  kubectl --kubeconfig ~/verda_kubeconfig.yaml -n kube-system get svc cilium-gateway-lab-gateway"
    else
        printf '%-12s %s\n' "Longhorn UI" "http://longhorn.lab:$GW_PORT/"
        printf '%-12s %s\n' "OpenBao"     "http://openbao.lab:$GW_PORT/"
        printf '%-12s %s\n' "Grafana"     "http://grafana.lab:$GW_PORT/"
        printf '%-12s %s\n' "Prometheus"  "http://prometheus.lab:$GW_PORT/"
    fi
