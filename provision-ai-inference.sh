#!/usr/bin/env bash
#
# Golden Image Provisioning Script — ai-inference VM template
# Target: Debian 13 (Trixie) on Proxmox VE (Q35/OVMF, GPU passthrough)
#
# PREREQUISITES:
#   1. Create VM in Proxmox (see comments below for qm commands)
#   2. Install Debian 13 using guided partitioning → "All files in one partition"
#      This creates: sda1 (EFI ~512M), sda2 (/ ~94G), sda3 (swap ~5G)
#   3. During install: set root password, skip non-root user, select SSH server only
#   4. Boot into fresh Debian, copy this script, run as root
#
# PROXMOX VM CREATION (run on the hypervisor before Debian install):
#   qm create 200 --name ai-inference-v2 --ostype l26 --machine q35 --bios ovmf \
#     --cpu host --cores 8 --sockets 1 --numa 1 \
#     --memory 65536 --balloon 0 \
#     --efidisk0 data:0,efitype=4m,pre-enrolled-keys=0 \
#     --scsi0 data:100,discard=on,ssd=1,iothread=1 \
#     --scsihw virtio-scsi-single \
#     --net0 virtio,bridge=vmbr0 \
#     --hostpci0 05:00.0,pcie=1 \
#     --hostpci1 0b:00.0,pcie=1 \
#     --agent enabled=1 \
#     --cdrom local:iso/debian-13.4.0-amd64-netinst.iso \
#     --boot order='ide2;scsi0'
#
#   After Debian install, remove the ISO:
#     qm set 200 --delete ide2 --boot order=scsi0
#
# USAGE:
#   scp provision-ai-inference.sh root@<vm-ip>:/root/
#   ssh root@<vm-ip>
#   chmod +x /root/provision-ai-inference.sh
#   /root/provision-ai-inference.sh
#
#   After completion: reboot, verify nvidia-smi + Docker GPU, then template:
#     qm template 200
#
# WHAT GETS INSTALLED:
#   - NVIDIA driver 550 (DKMS), CUDA 12.4 runtime, nvidia-persistenced
#   - Docker CE with NVIDIA default runtime
#   - Ollama (LLM inference, port 11434)
#   - ComfyUI (image generation, port 8188) + FLUX.1-schnell model
#   - Open WebUI (chat interface, port 3000)
#   - Tailscale (installed, not joined)
#   - Static IP, SSH key auth, host key regen on clone boot
#
set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
STATIC_IP="10.42.0.100"
GATEWAY="10.42.0.1"
DNS="10.42.0.1"
INTERFACE="ens18"
DOCKER_DATA_ROOT="/home/docker"

# SSH public keys (the hypervisor host + workstation)
HYPERVISOR_PUBKEY="ssh-rsa AAAA...REPLACE_WITH_YOUR_PUBKEY... user@host"
WORKSTATION_PUBKEY="ssh-ed25519 AAAA...REPLACE_WITH_YOUR_PUBKEY... user@host"

log() { echo -e "\n===> $1\n"; }

# ============================================================================
# 1. Base system
# ============================================================================
log "Updating base system"
apt-get update
apt-get upgrade -y

log "Installing base packages"
apt-get install -y \
    build-essential dkms linux-headers-"$(uname -r)" \
    git curl wget htop tmux gnupg lsb-release \
    python3 python3-pip python3-venv \
    ca-certificates \
    qemu-guest-agent

systemctl enable --now qemu-guest-agent

# ============================================================================
# 2. NVIDIA Driver (from Debian repos, DKMS)
# ============================================================================
log "Installing NVIDIA driver"

# Enable non-free-firmware if not already
if ! grep -q 'non-free-firmware' /etc/apt/sources.list.d/*.sources 2>/dev/null && \
   ! grep -q 'non-free-firmware' /etc/apt/sources.list 2>/dev/null; then
    sed -i 's/main$/main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources 2>/dev/null || \
    sed -i 's/main$/main contrib non-free non-free-firmware/' /etc/apt/sources.list 2>/dev/null
    apt-get update
fi

apt-get install -y nvidia-driver firmware-misc-nonfree

# Blacklist nouveau (should already be done by nvidia-driver)
cat > /etc/modprobe.d/blacklist-nouveau.conf << 'EOF'
blacklist nouveau
options nouveau modeset=0
EOF

# ============================================================================
# 3. CUDA Runtime (Debian packages — runtime only, no dev/nsight bloat)
# ============================================================================
log "Installing CUDA runtime libraries"

# Install the full toolkit then immediately strip the bloat.
# Debian 13 packages CUDA as a monolithic nvidia-cuda-toolkit;
# we install it, then remove the pieces we don't need.
apt-get install -y nvidia-cuda-toolkit

log "Removing CUDA bloat (nsight, dev packages, static libs)"
apt-get purge -y \
    nsight-compute nsight-compute-target \
    nsight-systems nsight-systems-target \
    nvidia-cuda-dev libcupti-dev \
    2>/dev/null || true

# Remove all static libraries (not needed for inference)
rm -f /usr/lib/x86_64-linux-gnu/*_static.a

# Mark critical runtime libs so autoremove never touches them
apt-mark manual \
    libnvidia-nvvm4 \
    nvidia-opencl-icd \
    nvidia-opencl-common \
    nvidia-driver \
    2>/dev/null || true

apt-get autoremove -y
apt-get clean

# ============================================================================
# 4. Docker CE
# ============================================================================
log "Installing Docker CE"

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

cat > /etc/apt/sources.list.d/docker.list << EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable
EOF

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Docker data-root on separate space + NVIDIA as default runtime
mkdir -p "${DOCKER_DATA_ROOT}"
cat > /etc/docker/daemon.json << EOF
{
  "data-root": "${DOCKER_DATA_ROOT}",
  "default-runtime": "nvidia",
  "runtimes": {
    "nvidia": {
      "path": "nvidia-container-runtime",
      "runtimeArgs": []
    }
  }
}
EOF

# ============================================================================
# 5. NVIDIA Container Toolkit
# ============================================================================
log "Installing NVIDIA Container Toolkit"

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt-get update
apt-get install -y nvidia-container-toolkit

systemctl enable docker
systemctl restart docker

# ============================================================================
# 6. Tailscale (installed, NOT joined — run `tailscale up` after clone)
# ============================================================================
log "Installing Tailscale"

curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg | \
    tee /usr/share/keyrings/tailscale-archive-keyring.gpg > /dev/null
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list | \
    tee /etc/apt/sources.list.d/tailscale.list

apt-get update
apt-get install -y tailscale
systemctl enable tailscaled

# ============================================================================
# 7. Caddy (HTTPS reverse proxy — terminates TLS for Open WebUI)
# ============================================================================
log "Installing Caddy reverse proxy"

apt-get install -y caddy

# Disable Apache if present (conflicts with Caddy on port 80)
if systemctl is-active --quiet apache2 2>/dev/null; then
    systemctl stop apache2
    systemctl disable apache2
fi

# Caddy config will be written after Tailscale join (needs hostname)
# See post-clone steps at bottom

# ============================================================================
# 8. Ollama (local LLM inference server — uses both T4s via layer splitting)
# ============================================================================
log "Installing Ollama"

curl -fsSL https://ollama.com/install.sh | sh

# Ollama defaults to localhost:11434. Enable it as a system service.
# The install script creates the systemd unit automatically.
systemctl enable ollama

# ============================================================================
# 8. ComfyUI (image generation — native install with FLUX.1-schnell)
# ============================================================================
log "Installing ComfyUI"

# Clone ComfyUI
git clone https://github.com/comfyanonymous/ComfyUI.git /opt/comfyui
cd /opt/comfyui

# Create venv and install dependencies
python3 -m venv venv
source venv/bin/activate
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124
pip install -r requirements.txt
deactivate

# Create systemd service
cat > /etc/systemd/system/comfyui.service << 'EOF'
[Unit]
Description=ComfyUI Image Generation Server
After=network.target nvidia-persistenced.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/comfyui
ExecStart=/opt/comfyui/venv/bin/python main.py --listen 0.0.0.0 --port 8188
Restart=on-failure
RestartSec=10
Environment=CUDA_VISIBLE_DEVICES=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable comfyui

# Download FLUX.1-schnell model files
# NOTE: FLUX.1-schnell is Apache 2.0 but HuggingFace requires auth.
#       Set HF_TOKEN env var before running, or download manually:
#         export HF_TOKEN="hf_your_token_here"
log "Downloading FLUX.1-schnell models (requires HF_TOKEN)"
mkdir -p /opt/comfyui/models/{unet,clip,vae}

if [ -n "${HF_TOKEN:-}" ]; then
    curl -L -H "Authorization: Bearer ${HF_TOKEN}" \
        -o /opt/comfyui/models/unet/flux1-schnell.safetensors \
        https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/flux1-schnell.safetensors

    curl -L -H "Authorization: Bearer ${HF_TOKEN}" \
        -o /opt/comfyui/models/clip/t5xxl_fp8_e4m3fn.safetensors \
        https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors

    curl -L -o /opt/comfyui/models/clip/clip_l.safetensors \
        https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors

    curl -L -H "Authorization: Bearer ${HF_TOKEN}" \
        -o /opt/comfyui/models/vae/ae.safetensors \
        https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/ae.safetensors
else
    echo "WARNING: HF_TOKEN not set — skipping FLUX model download."
    echo "After provisioning, run:  export HF_TOKEN=... && /root/download-flux.sh"
fi

# ============================================================================
# 9. Open WebUI (browser-based chat interface for Ollama + ComfyUI images)
# ============================================================================
log "Installing Open WebUI"

docker run -d \
    --name open-webui \
    --restart always \
    -p 3000:8080 \
    -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
    --add-host=host.docker.internal:host-gateway \
    -v open-webui:/app/backend/data \
    ghcr.io/open-webui/open-webui:main

# ============================================================================
# 10. Network — static IP
# ============================================================================
log "Configuring static network"

cat > /etc/network/interfaces << EOF
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

allow-hotplug ${INTERFACE}
iface ${INTERFACE} inet static
        address ${STATIC_IP}/24
        gateway ${GATEWAY}
        dns-nameservers ${DNS}
EOF

# ============================================================================
# 11. SSH setup
# ============================================================================
log "Configuring SSH"

mkdir -p /root/.ssh
chmod 700 /root/.ssh
cat > /root/.ssh/authorized_keys << EOF
${HYPERVISOR_PUBKEY}
${WORKSTATION_PUBKEY}
EOF
chmod 600 /root/.ssh/authorized_keys

# SSH host key regeneration on first boot (after cloning)
cat > /etc/rc.local << 'RCEOF'
#!/bin/bash
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
  dpkg-reconfigure openssh-server
  systemctl restart sshd
fi
RCEOF
chmod +x /etc/rc.local

# ============================================================================
# 12. NVIDIA persistence
# ============================================================================
log "Enabling NVIDIA persistence daemon"
systemctl enable nvidia-persistenced

# ============================================================================
# 13. Final cleanup & template prep
# ============================================================================
log "Final cleanup"

# Clean apt cache
apt-get clean
rm -rf /var/lib/apt/lists/*

# Clean logs
journalctl --vacuum-time=1d
find /var/log -type f -name "*.gz" -delete
find /var/log -type f -name "*.old" -delete
find /var/log -type f -name "*.[0-9]" -delete
cat /dev/null > /var/log/wtmp
cat /dev/null > /var/log/btmp

# Clear bash history
cat /dev/null > /root/.bash_history
unset HISTFILE

# Remove SSH host keys (will be regenerated on first clone boot via rc.local)
rm -f /etc/ssh/ssh_host_*

# Remove this script
rm -f /root/provision-ai-inference.sh

log "DONE — Provisioning complete!"
echo ""
echo "Next steps:"
echo "  1. Reboot:   shutdown -r now"
echo "  2. Verify:   nvidia-smi"
echo "  3. Verify:   docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi"
echo "  4. Verify:   curl http://localhost:11434/api/tags   (Ollama)"
echo "  5. Verify:   curl http://localhost:8188/system_stats (ComfyUI)"
echo "  6. Verify:   curl http://localhost:3000/api/config   (Open WebUI)"
echo "  7. Template: qm template <vmid>     (run on the hypervisor)"
echo ""
echo "After cloning:"
echo "  - hostnamectl set-hostname <name>"
echo "  - Update /etc/network/interfaces if changing from ${STATIC_IP}"
echo "  - tailscale up --accept-dns=false"
echo "    (Approve the auth URL in browser. Note the MagicDNS hostname.)"
echo "  - Set up HTTPS reverse proxy for Open WebUI:"
echo "      HOSTNAME=\$(tailscale status --json | python3 -c \"import sys,json; print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))\")"
echo "      tailscale cert \$HOSTNAME"
echo "      mkdir -p /etc/caddy/certs"
echo "      cp \${HOSTNAME}.crt /etc/caddy/certs/"
echo "      cp \${HOSTNAME}.key /etc/caddy/certs/"
echo "      chown caddy:caddy /etc/caddy/certs/*"
echo "      cat > /etc/caddy/Caddyfile << EOF"
echo "      \$HOSTNAME {"
echo "          tls /etc/caddy/certs/\${HOSTNAME}.crt /etc/caddy/certs/\${HOSTNAME}.key"
echo "          reverse_proxy localhost:3000"
echo "      }"
echo "      EOF"
echo "      systemctl restart caddy"
echo "  - ollama pull qwen2.5:14b   (or your preferred model)"
echo "  - Open https://\$HOSTNAME → create account → select model"
echo "  - Admin Panel → Settings → Images → ComfyUI → http://host.docker.internal:8188"
echo "  - Google OAuth (optional):"
echo "    Origin:   https://\$HOSTNAME"
echo "    Redirect: https://\$HOSTNAME/oauth/google/callback"
echo ""
