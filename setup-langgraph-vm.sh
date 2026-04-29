#!/usr/bin/env bash
#
# the hypervisor-side setup for LangGraph Dev VM 102
# Run this ON HYPERVISOR (HYPERVISOR_IP) — not on the VM itself.
#
# This script has two phases:
#   Phase 1: Create VM 102 and prep for Debian install
#   Phase 2: Apply Proxmox firewall rules (run AFTER VM is provisioned)
#
# USAGE:
#   Phase 1 (create VM):
#     ./setup-langgraph-vm.sh create
#
#   Phase 2 (firewall, after VM provisioning is done):
#     ./setup-langgraph-vm.sh firewall
#
set -euo pipefail

VMID=102
VMNAME="langgraph-dev"
VMIP="10.42.0.102"
HYPERVISOR_IP="HYPERVISOR_IP"
OPNSENSE_IP="10.42.0.1"
OLLAMA_IP="10.42.0.100"
ISO="local:iso/debian-13.4.0-amd64-netinst.iso"

log() { echo -e "\n===> $1\n"; }

# ============================================================================
# Phase 1: Create VM
# ============================================================================
phase_create() {
    log "Checking if VM ${VMID} already exists"
    if qm status ${VMID} &>/dev/null; then
        echo "ERROR: VM ${VMID} already exists. Delete it first or choose a different ID."
        echo "  qm stop ${VMID}; qm destroy ${VMID}"
        exit 1
    fi

    log "Checking for Debian ISO"
    if ! ls /var/lib/vz/template/iso/debian-13.4.0-amd64-netinst.iso &>/dev/null; then
        echo "ERROR: Debian ISO not found at /var/lib/vz/template/iso/"
        echo "Download it first:"
        echo "  cd /var/lib/vz/template/iso/"
        echo "  wget https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.4.0-amd64-netinst.iso"
        exit 1
    fi

    log "Creating VM ${VMID} (${VMNAME})"
    qm create ${VMID} \
        --name ${VMNAME} \
        --ostype l26 \
        --machine q35 \
        --bios ovmf \
        --cpu host \
        --cores 4 \
        --sockets 1 \
        --memory 32768 \
        --efidisk0 data:0,efitype=4m,pre-enrolled-keys=0 \
        --scsi0 data:40,discard=on,ssd=1,iothread=1 \
        --scsihw virtio-scsi-single \
        --net0 virtio,bridge=vmbr0,firewall=1 \
        --agent enabled=1 \
        --cdrom "${ISO}" \
        --boot order='ide2;scsi0' \
        --onboot 1 \
        --startup order=3,up=60

    log "VM ${VMID} created successfully"
    echo ""
    echo "============================================================"
    echo " VM ${VMID} (${VMNAME}) is ready for Debian install"
    echo "============================================================"
    echo ""
    echo "  1. Start the VM:"
    echo "       qm start ${VMID}"
    echo ""
    echo "  2. Open the Proxmox console (noVNC):"
    echo "       https://${HYPERVISOR_IP}:8006 → VM ${VMID} → Console"
    echo ""
    echo "  3. Install Debian 13:"
    echo "       - Guided partitioning → 'All files in one partition'"
    echo "       - Root password: <set during Debian install>"
    echo "       - Skip non-root user creation"
    echo "       - Software: SSH server only (uncheck everything else)"
    echo ""
    echo "  4. After install completes and VM reboots:"
    echo "       qm set ${VMID} --delete ide2 --boot order=scsi0"
    echo ""
    echo "  5. Set static IP via console (if needed):"
    echo "       Log in as root, then:"
    echo "         cat > /etc/network/interfaces << 'EOF'"
    echo "         source /etc/network/interfaces.d/*"
    echo "         auto lo"
    echo "         iface lo inet loopback"
    echo "         allow-hotplug ens18"
    echo "         iface ens18 inet static"
    echo "                 address ${VMIP}/24"
    echo "                 gateway ${OPNSENSE_IP}"
    echo "                 dns-nameservers ${OPNSENSE_IP}"
    echo "         EOF"
    echo "         systemctl restart networking"
    echo ""
    echo "  6. Copy and run the provisioning script:"
    echo "       scp /root/provision-langgraph.sh root@${VMIP}:/root/"
    echo "       ssh root@${VMIP} 'chmod +x /root/provision-langgraph.sh && /root/provision-langgraph.sh'"
    echo ""
    echo "  7. After provisioning, apply firewall:"
    echo "       ./setup-langgraph-vm.sh firewall"
    echo ""
}

# ============================================================================
# Phase 2: Proxmox Firewall
# ============================================================================
phase_firewall() {
    log "Checking if VM ${VMID} exists"
    if ! qm status ${VMID} &>/dev/null; then
        echo "ERROR: VM ${VMID} does not exist. Run 'create' phase first."
        exit 1
    fi

    # Ensure datacenter firewall is enabled (required for per-VM rules to work)
    log "Ensuring datacenter firewall is enabled"
    CLUSTER_FW="/etc/pve/firewall/cluster.fw"
    if [ ! -f "${CLUSTER_FW}" ]; then
        cat > "${CLUSTER_FW}" << 'EOF'
[OPTIONS]
enable: 1
policy_in: ACCEPT
policy_out: ACCEPT

[RULES]
EOF
        echo "Created ${CLUSTER_FW} with datacenter firewall enabled"
    elif ! grep -q "^enable: 1" "${CLUSTER_FW}"; then
        echo "WARNING: Datacenter firewall may not be enabled."
        echo "Check ${CLUSTER_FW} and ensure [OPTIONS] has 'enable: 1'"
        echo "Continuing anyway..."
    fi

    log "Creating firewall rules for VM ${VMID}"
    mkdir -p /etc/pve/firewall
    cat > "/etc/pve/firewall/${VMID}.fw" << EOF
[OPTIONS]
enable: 1
policy_in: ACCEPT
policy_out: ACCEPT

[RULES]
# Allow DNS to OPNsense (needed for apt, pip, etc.)
OUT ACCEPT -dest ${OPNSENSE_IP} -p udp -dport 53 -log nolog
OUT ACCEPT -dest ${OPNSENSE_IP} -p tcp -dport 53 -log nolog
# Block VM from reaching OPNsense (web UI, SSH, everything else)
OUT DROP -dest ${OPNSENSE_IP} -log nolog
# Block VM from reaching the hypervisor (hypervisor)
OUT DROP -dest ${HYPERVISOR_IP} -log nolog
# Allow the hypervisor to SSH into VM for management
IN ACCEPT -source ${HYPERVISOR_IP} -p tcp -dport 22 -log nolog
EOF

    log "Firewall rules written to /etc/pve/firewall/${VMID}.fw"
    cat "/etc/pve/firewall/${VMID}.fw"

    # Ensure net0 has firewall=1
    log "Ensuring firewall is enabled on VM ${VMID} net0"
    VMCONF="/etc/pve/qemu-server/${VMID}.conf"
    if grep -q "net0:.*firewall=1" "${VMCONF}"; then
        echo "net0 already has firewall=1"
    elif grep -q "net0:.*firewall=0" "${VMCONF}"; then
        sed -i 's/firewall=0/firewall=1/' "${VMCONF}"
        echo "Updated net0 firewall=0 → firewall=1"
    elif grep -q "^net0:" "${VMCONF}"; then
        sed -i 's/^net0:\(.*\)/net0:\1,firewall=1/' "${VMCONF}"
        echo "Added firewall=1 to net0"
    fi

    log "Firewall configured"
    echo ""
    echo "============================================================"
    echo " Firewall active for VM ${VMID}"
    echo "============================================================"
    echo ""
    echo "  Rules:"
    echo "    - OUT ACCEPT → ${OPNSENSE_IP}:53  (DNS only)"
    echo "    - OUT DROP → ${OPNSENSE_IP}  (VM cannot reach OPNsense)"
    echo "    - OUT DROP → ${HYPERVISOR_IP}  (VM cannot reach the hypervisor)"
    echo "    - IN ACCEPT ← ${HYPERVISOR_IP}:22  (the hypervisor can SSH to VM)"
    echo "    - Everything else: ACCEPT (internet, Ollama on ${OLLAMA_IP})"
    echo ""
    echo "  Verify from VM ${VMID} (ssh root@${VMIP}):"
    echo "    curl -sk --connect-timeout 5 https://${HYPERVISOR_IP}:8006"
    echo "    # Expected: timeout (BLOCKED)"
    echo ""
    echo "    curl -s http://${OLLAMA_IP}:11434/api/tags"
    echo "    # Expected: {\"models\":[...]} (ALLOWED)"
    echo ""
    echo "    dig google.com @${OPNSENSE_IP}"
    echo "    # Expected: DNS response (ALLOWED)"
    echo ""
    echo "  Verify from the hypervisor:"
    echo "    ssh root@${VMIP} 'hostname'"
    echo "    # Expected: langgraph-dev (ALLOWED)"
    echo ""
}

# ============================================================================
# Main
# ============================================================================
case "${1:-}" in
    create)
        phase_create
        ;;
    firewall)
        phase_firewall
        ;;
    *)
        echo "Usage: $0 {create|firewall}"
        echo ""
        echo "  create    — Create VM ${VMID} and prep for Debian install"
        echo "  firewall  — Apply Proxmox firewall rules (after VM is provisioned)"
        exit 1
        ;;
esac
