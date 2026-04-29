#!/usr/bin/env bash
#
# the hypervisor-side setup for Voice VM 103
# Run this ON HYPERVISOR (HYPERVISOR_IP) — not on the VM itself.
#
# This script has two phases:
#   Phase 1: Create VM 103 and prep for Debian install
#   Phase 2: Apply Proxmox firewall rules (run AFTER VM is provisioned)
#
# USAGE:
#   Phase 1 (create VM):
#     ./setup-voice-vm.sh create
#
#   Phase 2 (firewall, after VM provisioning is done):
#     ./setup-voice-vm.sh firewall
#
set -euo pipefail

VMID=103
VMNAME="voice"
VMIP="10.42.0.103"
HYPERVISOR_IP="HYPERVISOR_IP"
OPNSENSE_IP="10.42.0.1"
OLLAMA_IP="10.42.0.100"
LANGGRAPH_IP="10.42.0.102"
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
        --memory 8192 \
        --efidisk0 data:0,efitype=4m,pre-enrolled-keys=0 \
        --scsi0 data:20,discard=on,ssd=1,iothread=1 \
        --scsihw virtio-scsi-single \
        --net0 virtio,bridge=vmbr0,firewall=1 \
        --agent enabled=1 \
        --cdrom "${ISO}" \
        --boot order='ide2;scsi0' \
        --onboot 1 \
        --startup order=4,up=90

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
    echo "       scp /root/provision-voice.sh root@${VMIP}:/root/"
    echo "       ssh root@${VMIP}"
    echo "       chmod +x /root/provision-voice.sh"
    echo "       /root/provision-voice.sh"
    echo ""
    echo "  7. After provisioning, apply firewall rules:"
    echo "       ./setup-voice-vm.sh firewall"
    echo ""
}

# ============================================================================
# Phase 2: Firewall rules
# ============================================================================
phase_firewall() {
    log "Applying Proxmox firewall rules for VM ${VMID}"

    FWDIR="/etc/pve/firewall"
    FWFILE="${FWDIR}/${VMID}.fw"

    mkdir -p "${FWDIR}"

    cat > "${FWFILE}" << EOF
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT

[RULES]
# Allow SSH from the hypervisor only
IN ACCEPT -source ${HYPERVISOR_IP} -p tcp -dport 22

# No SIP/RTP ports needed — Twilio connects via Tailscale Funnel (outbound WireGuard)
# Allow responses from Ollama/Whisper (VM 201) and LangGraph (VM 102)
IN ACCEPT -source ${OLLAMA_IP} -p tcp
IN ACCEPT -source ${LANGGRAPH_IP} -p tcp

# Block outbound to the hypervisor and OPNsense (except DNS)
OUT ACCEPT -dest ${OPNSENSE_IP} -p udp -dport 53
OUT DROP -dest ${OPNSENSE_IP}
OUT DROP -dest ${HYPERVISOR_IP}
EOF

    log "Firewall rules written to ${FWFILE}"
    echo ""
    echo "VM ${VMID} firewall active:"
    echo "  IN:  SSH from the hypervisor only. No SIP/RTP ports (uses Tailscale Funnel)."
    echo "  OUT: DNS to OPNsense, all else except the hypervisor/OPNsense"
    echo ""
}

# ============================================================================
# Main
# ============================================================================
case "${1:-}" in
    create)   phase_create ;;
    firewall) phase_firewall ;;
    *)
        echo "Usage: $0 {create|firewall}"
        echo "  create   - Create VM ${VMID} on Proxmox"
        echo "  firewall - Apply firewall rules (run after provisioning)"
        exit 1
        ;;
esac
