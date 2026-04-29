#!/usr/bin/env bash
#
# Sovereign AI Node — Proxmox Cloud-Init VM Creator
# Zero-touch: downloads Debian 13 cloud image → creates VM → cloud-init → runs install.sh
#
# Run this ON THE PROXMOX HOST (e.g., the hypervisor HYPERVISOR_IP).
#
# USAGE:
#   ./create-node.sh sovereign-node.env              # Full pipeline
#   ./create-node.sh sovereign-node.env --create-only # Just create VM, don't provision
#   ./create-node.sh sovereign-node.env --firewall    # Apply firewall rules only
#
# WHAT IT DOES:
#   1. Downloads debian-13-generic-amd64.qcow2 (cloud-init enabled)
#   2. Creates a Proxmox VM (Q35/OVMF, virtio-scsi)
#   3. Imports the cloud image as the boot disk
#   4. Resizes disk to target size
#   5. Attaches cloud-init drive (user, network, SSH keys — no manual install)
#   6. Optionally passes through GPU(s)
#   7. Boots the VM — cloud-init handles first-boot config
#   8. Waits for SSH, copies install.sh + env file, runs provisioning
#
# REPLACES: setup-*-vm.sh + manual Debian ISO install + provision-*.sh copy/run
#
# PREREQUISITES:
#   - Proxmox VE 8.x+ (tested on 9.1.6)
#   - sovereign-node.env configured for this node
#   - install.sh in the same directory
#   - For GPU passthrough: IOMMU enabled, vfio-pci bound to target GPUs
#
set -euo pipefail

# Guard: must be run with bash, not sh/dash
if [ -z "${BASH_VERSION:-}" ]; then
    echo "[FAIL] This script requires bash. Run: bash $0 $*" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Debian 13 Trixie Generic Cloud Image (cloud-init enabled, hypervisor-agnostic)
CLOUD_IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
CLOUD_IMAGE_DIR="/var/lib/vz/template/cloud"
CLOUD_IMAGE_FILE="debian-13-generic-amd64.qcow2"

# ============================================================================
# Helpers
# ============================================================================
log()  { echo -e "\n===> $1\n"; }
info() { echo "  [INFO] $1"; }
warn() { echo "  [WARN] $1" >&2; }
fail() { echo "  [FAIL] $1" >&2; exit 1; }

# ============================================================================
# Load config
# ============================================================================
load_config() {
    local config_file="${1}"
    [ -f "${config_file}" ] || fail "Config file not found: ${config_file}"
    set -a
    # shellcheck source=/dev/null
    source "${config_file}"
    set +a

    # Required fields
    [ -n "${VM_ID:-}" ]         || fail "VM_ID not set in config"
    [ -n "${NODE_HOSTNAME:-}" ] || fail "NODE_HOSTNAME not set in config"
    [ -n "${IP_ADDRESS:-}" ]    || fail "IP_ADDRESS not set in config"
    [ -n "${GATEWAY:-}" ]       || fail "GATEWAY not set in config"
    [ -n "${DNS:-}" ]           || fail "DNS not set in config"

    # Defaults
    VM_CORES="${VM_CORES:-4}"
    VM_SOCKETS="${VM_SOCKETS:-1}"
    VM_MEMORY="${VM_MEMORY:-16384}"
    VM_DISK_SIZE="${VM_DISK_SIZE:-92G}"
    VM_STORAGE="${VM_STORAGE:-data}"
    VM_BRIDGE="${VM_BRIDGE:-vmbr0}"
    VM_STARTUP_ORDER="${VM_STARTUP_ORDER:-}"
    VM_ONBOOT="${VM_ONBOOT:-1}"
    ROOT_PASSWORD="${ROOT_PASSWORD:- }"
    GPU_PASSTHROUGH="${GPU_PASSTHROUGH:-}"

    info "Config loaded: VM ${VM_ID} (${NODE_HOSTNAME}) at ${IP_ADDRESS}"
}

# ============================================================================
# Phase 1: Download cloud image
# ============================================================================
download_image() {
    mkdir -p "${CLOUD_IMAGE_DIR}"
    local image_path="${CLOUD_IMAGE_DIR}/${CLOUD_IMAGE_FILE}"

    if [ -f "${image_path}" ]; then
        info "Cloud image already exists: ${image_path}"
        # Check age — re-download if older than 30 days
        local age_days
        age_days=$(( ($(date +%s) - $(stat -c %Y "${image_path}" 2>/dev/null || stat -f %m "${image_path}")) / 86400 ))
        if [ "${age_days}" -gt 30 ]; then
            log "Cloud image is ${age_days} days old — re-downloading"
            rm -f "${image_path}"
        else
            info "Image is ${age_days} days old (< 30), using cached copy"
            return
        fi
    fi

    log "Downloading Debian 13 Trixie Generic Cloud Image"
    wget --progress=bar:force -O "${image_path}" "${CLOUD_IMAGE_URL}"

    # Verify we got a valid qcow2
    if ! qemu-img info "${image_path}" 2>/dev/null | grep -q 'qcow2'; then
        rm -f "${image_path}"
        fail "Downloaded file is not a valid qcow2 image"
    fi

    info "Image downloaded: ${image_path} ($(du -h "${image_path}" | cut -f1))"
}

# ============================================================================
# Phase 2: Create VM
# ============================================================================
create_vm() {
    log "Creating VM ${VM_ID} (${NODE_HOSTNAME})"

    if qm status "${VM_ID}" &>/dev/null; then
        fail "VM ${VM_ID} already exists. Delete it first:\n  qm stop ${VM_ID} && qm destroy ${VM_ID} --purge"
    fi

    local image_path="${CLOUD_IMAGE_DIR}/${CLOUD_IMAGE_FILE}"

    # Create the VM shell (no disks yet)
    local create_args=(
        "${VM_ID}"
        --name "${NODE_HOSTNAME}"
        --ostype l26
        --machine q35
        --bios ovmf
        --cpu host
        --cores "${VM_CORES}"
        --sockets "${VM_SOCKETS}"
        --memory "${VM_MEMORY}"
        --balloon 0
        --efidisk0 "${VM_STORAGE}:0,efitype=4m,pre-enrolled-keys=0"
        --scsihw virtio-scsi-single
        --net0 "virtio,bridge=${VM_BRIDGE},firewall=1"
        --agent enabled=1
        --onboot "${VM_ONBOOT}"
        --serial0 socket
        --vga serial0
    )

    # Startup order (if set)
    if [ -n "${VM_STARTUP_ORDER}" ]; then
        create_args+=(--startup "${VM_STARTUP_ORDER}")
    fi

    qm create "${create_args[@]}"

    # Import cloud image as the boot disk
    log "Importing cloud image as boot disk"
    qm set "${VM_ID}" --scsi0 "${VM_STORAGE}:0,import-from=${image_path},discard=on,iothread=1,ssd=1"

    # Resize disk to target size
    log "Resizing boot disk to ${VM_DISK_SIZE}"
    qm resize "${VM_ID}" scsi0 "${VM_DISK_SIZE}"

    # Set boot order to scsi0
    qm set "${VM_ID}" --boot order=scsi0

    # GPU passthrough (if configured)
    if [ -n "${GPU_PASSTHROUGH}" ]; then
        log "Configuring GPU passthrough"
        local gpu_index=0
        IFS=',' read -ra GPU_ADDRS <<< "${GPU_PASSTHROUGH}"
        for addr in "${GPU_ADDRS[@]}"; do
            addr=$(echo "${addr}" | xargs)  # trim whitespace
            qm set "${VM_ID}" --hostpci${gpu_index} "${addr},pcie=1"
            info "  hostpci${gpu_index}: ${addr}"
            gpu_index=$((gpu_index + 1))
        done
        # NUMA for multi-GPU
        if [ "${gpu_index}" -gt 1 ]; then
            qm set "${VM_ID}" --numa 1
        fi
    fi

    info "VM ${VM_ID} created"
}

# ============================================================================
# Phase 3: Configure cloud-init
# ============================================================================
configure_cloudinit() {
    log "Configuring cloud-init"

    # Add cloud-init drive
    qm set "${VM_ID}" --ide2 "${VM_STORAGE}:cloudinit"

    # Prepare SSH public keys file for cloud-init
    local ssh_keys_file
    ssh_keys_file=$(mktemp /tmp/ci-sshkeys-XXXXXX.pub)
    if [ -n "${SSH_AUTHORIZED_KEYS:-}" ]; then
        echo "${SSH_AUTHORIZED_KEYS}" > "${ssh_keys_file}"
    fi
    # Always add the hypervisor host key if it exists
    if [ -f /root/.ssh/id_rsa.pub ]; then
        cat /root/.ssh/id_rsa.pub >> "${ssh_keys_file}"
    fi
    # Deduplicate
    if [ -s "${ssh_keys_file}" ]; then
        sort -u "${ssh_keys_file}" -o "${ssh_keys_file}"
    fi

    # Set cloud-init parameters
    qm set "${VM_ID}" \
        --ciuser root \
        --cipassword "${ROOT_PASSWORD}" \
        --ipconfig0 "ip=${IP_ADDRESS}/24,gw=${GATEWAY}" \
        --nameserver "${DNS}" \
        --searchdomain "local"

    if [ -s "${ssh_keys_file}" ]; then
        qm set "${VM_ID}" --sshkeys "${ssh_keys_file}"
    fi

    rm -f "${ssh_keys_file}"

    info "Cloud-init configured: root@${IP_ADDRESS}, SSH keys injected"
}

# ============================================================================
# Phase 4: Boot and wait for SSH
# ============================================================================
boot_and_wait() {
    log "Starting VM ${VM_ID}"
    qm start "${VM_ID}"

    log "Waiting for VM to boot and cloud-init to complete"
    info "This usually takes 30-90 seconds..."

    local max_wait=180
    local elapsed=0
    local interval=5

    while [ ${elapsed} -lt ${max_wait} ]; do
        if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o BatchMode=yes \
             "root@${IP_ADDRESS}" "cloud-init status --wait 2>/dev/null; echo ready" 2>/dev/null | grep -q ready; then
            info "VM is up and cloud-init is done (${elapsed}s)"
            return 0
        fi
        sleep ${interval}
        elapsed=$((elapsed + interval))
        printf "  [%3ds] Waiting for SSH on %s...\r" "${elapsed}" "${IP_ADDRESS}"
    done
    echo ""
    fail "VM did not become reachable via SSH within ${max_wait}s. Check Proxmox console."
}

# ============================================================================
# Phase 5: Provision the node
# ============================================================================
provision() {
    local install_script="${SCRIPT_DIR}/install.sh"
    local config_file="${1}"

    [ -f "${install_script}" ] || fail "install.sh not found at ${install_script}"

    log "Copying installer and config to VM"
    scp -o StrictHostKeyChecking=no \
        "${install_script}" "${config_file}" \
        "root@${IP_ADDRESS}:/root/"

    local remote_config
    remote_config="/root/$(basename "${config_file}")"

    log "Running installer on VM ${VM_ID} (${NODE_HOSTNAME})"
    info "This will take 10-30 minutes depending on model size and network speed."
    info "You can also monitor from another terminal:"
    info "  ssh root@${IP_ADDRESS} tail -f /var/log/sovereign-node-install.log"
    echo ""

    ssh -o StrictHostKeyChecking=no "root@${IP_ADDRESS}" \
        "chmod +x /root/install.sh && /root/install.sh ${remote_config}"

    info "Provisioning complete!"
}

# ============================================================================
# Phase 6: Apply Proxmox firewall
# ============================================================================
apply_firewall() {
    log "Applying Proxmox firewall rules for VM ${VM_ID}"

    local fw_dir="/etc/pve/firewall"
    local fw_file="${fw_dir}/${VM_ID}.fw"

    mkdir -p "${fw_dir}"
    cat > "${fw_file}" << EOF
[OPTIONS]
enable: 1
policy_in: ACCEPT
policy_out: ACCEPT

[RULES]
# Allow DNS to gateway/router
OUT ACCEPT -dest ${DNS} -proto udp -dport 53 -log nolog
OUT ACCEPT -dest ${DNS} -proto tcp -dport 53 -log nolog

# Block VM from accessing router management (web UI, SSH, etc.)
OUT DROP -dest ${GATEWAY} -log nolog

# Block VM from accessing Proxmox host
OUT DROP -dest $(hostname -I | awk '{print $1}') -log nolog

# Allow Proxmox host to SSH into VM
IN ACCEPT -source $(hostname -I | awk '{print $1}') -proto tcp -dport 22 -log nolog
EOF

    info "Firewall rules written to ${fw_file}"
    info "Rules: DNS allow → router DROP → host DROP → SSH in from host"
}

# ============================================================================
# Summary
# ============================================================================
print_summary() {
    echo ""
    echo "============================================================"
    echo " Sovereign AI Node — VM ${VM_ID} (${NODE_HOSTNAME})"
    echo "============================================================"
    echo ""
    echo "  IP:        ${IP_ADDRESS}"
    echo "  SSH:       ssh root@${IP_ADDRESS}"
    echo "  Console:   https://$(hostname -I | awk '{print $1}'):8006 → VM ${VM_ID}"
    echo ""
    echo "  Services:"
    echo "    Open WebUI:  http://${IP_ADDRESS}:${WEBUI_PORT:-3000}"
    echo "    Ollama API:  http://${IP_ADDRESS}:${OLLAMA_PORT:-11434}"
    if [ "${COMFYUI_ENABLED:-true}" = "true" ]; then
        echo "    ComfyUI:     http://${IP_ADDRESS}:${COMFYUI_PORT:-8188}"
    fi
    echo ""
    echo "  Cloud image:  ${CLOUD_IMAGE_DIR}/${CLOUD_IMAGE_FILE}"
    echo "  Firewall:     /etc/pve/firewall/${VM_ID}.fw"
    echo ""
    if [ -z "${TAILSCALE_AUTH_KEY:-}" ]; then
        echo "  Next: ssh root@${IP_ADDRESS} 'tailscale up'"
    fi
    echo ""
}

# ============================================================================
# Main
# ============================================================================
usage() {
    echo "Usage: $0 <config-file.env> [--create-only | --firewall | --provision-only]"
    echo ""
    echo "  (no flag)        Full pipeline: download → create → cloud-init → boot → provision → firewall"
    echo "  --create-only    Create VM and configure cloud-init, but don't boot or provision"
    echo "  --firewall       Apply Proxmox firewall rules only (VM must exist)"
    echo "  --provision-only Boot existing VM, copy files, run install.sh"
    exit 1
}

main() {
    local config_file="${1:-}"
    local mode="${2:---full}"

    [ -n "${config_file}" ] || usage
    [ -f "${config_file}" ] || fail "Config file not found: ${config_file}"

    load_config "${config_file}"

    case "${mode}" in
        --create-only)
            download_image
            create_vm
            configure_cloudinit
            info "VM ${VM_ID} created. Start with: qm start ${VM_ID}"
            ;;
        --firewall)
            apply_firewall
            ;;
        --provision-only)
            boot_and_wait
            provision "${config_file}"
            apply_firewall
            print_summary
            ;;
        --full|*)
            download_image
            create_vm
            configure_cloudinit
            boot_and_wait
            provision "${config_file}"
            apply_firewall
            print_summary
            ;;
    esac
}

main "$@"
