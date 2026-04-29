#!/usr/bin/env bash
#
# Sovereign AI Node — Installer
# One-command deployment of a private AI stack.
#
# USAGE:
#   ./install.sh                        # Interactive (prompts for config)
#   ./install.sh sovereign-node.env     # Config-driven (reads env file)
#
# WHAT GETS INSTALLED:
#   - Ollama (LLM inference, native systemd — direct GPU access)
#   - Open WebUI (chat interface, Docker)
#   - ComfyUI (image generation, native Python venv — direct GPU access)
#   - OpenClaw (agent framework, Docker) [when available]
#   - Tailscale (private remote access)
#   - Cloudflare Tunnel (public access, optional)
#
# ARCHITECTURE:
#   GPU workloads (Ollama, ComfyUI) run NATIVE — not in Docker.
#   This avoids cgroup/VRAM issues with enterprise GPUs (Tesla T4, L4, A100).
#   Non-GPU services (Open WebUI, OpenClaw) run in Docker Compose.
#
# SUPPORTED PLATFORMS:
#   - Bare-metal Linux (Debian 12+, Ubuntu 22.04+)
#   - Proxmox VM (Q35/OVMF, GPU passthrough)
#   - VMware ESXi VM (GPU passthrough)
#   - Cloud VM (AWS g4/p3, GCP A100/T4, Azure NC)
#   - Docker Compose on Mac/PC (CPU-only or Docker GPU runtime)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/sovereign-node-install.log"

# ============================================================================
# Helpers
# ============================================================================
log()  { echo -e "\n===> $1\n" | tee -a "${LOG_FILE}"; }
info() { echo "  [INFO] $1" | tee -a "${LOG_FILE}"; }
warn() { echo "  [WARN] $1" | tee -a "${LOG_FILE}" >&2; }
fail() { echo "  [FAIL] $1" | tee -a "${LOG_FILE}" >&2; exit 1; }

# ============================================================================
# Load config
# ============================================================================
load_config() {
    local config_file="${1:-}"

    if [ -n "${config_file}" ] && [ -f "${config_file}" ]; then
        log "Loading config from ${config_file}"
        set -a
        # shellcheck source=/dev/null
        source "${config_file}"
        set +a
    elif [ -f "${SCRIPT_DIR}/sovereign-node.env" ]; then
        log "Loading config from ${SCRIPT_DIR}/sovereign-node.env"
        set -a
        # shellcheck source=/dev/null
        source "${SCRIPT_DIR}/sovereign-node.env"
        set +a
    else
        fail "No config file found. Copy sovereign-node.env.example to sovereign-node.env and edit it."
    fi
}

# ============================================================================
# Platform detection
# ============================================================================
detect_platform() {
    if [ "${PLATFORM:-auto}" = "auto" ] || [ -z "${PLATFORM:-}" ]; then
        if [ -f /etc/pve/qemu-server ]; then
            PLATFORM="proxmox"
        elif command -v vmtoolsd &>/dev/null; then
            PLATFORM="vmware"
        elif [ -f /sys/class/dmi/id/product_name ] && grep -qi "amazon\|google\|microsoft" /sys/class/dmi/id/product_name 2>/dev/null; then
            PLATFORM="cloud"
        else
            PLATFORM="baremetal"
        fi
    fi
    info "Platform: ${PLATFORM}"
}

# ============================================================================
# NIC auto-detection
# ============================================================================
detect_nic() {
    if [ -z "${NIC_INTERFACE:-}" ]; then
        NIC_INTERFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
        if [ -z "${NIC_INTERFACE}" ]; then
            NIC_INTERFACE=$(ip -o link show | awk -F': ' '!/lo/{print $2; exit}')
        fi
    fi
    info "NIC: ${NIC_INTERFACE}"
}

# ============================================================================
# GPU detection and model selection
# ============================================================================
detect_gpu() {
    GPU_DETECTED="false"
    GPU_NAME=""
    GPU_VRAM_MB=0
    GPU_TOTAL_VRAM_MB=0
    DETECTED_GPU_COUNT=0

    if command -v nvidia-smi &>/dev/null; then
        DETECTED_GPU_COUNT=$(nvidia-smi --query-gpu=count --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")
        if [ "${DETECTED_GPU_COUNT}" -gt 0 ]; then
            GPU_DETECTED="true"
            GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
            GPU_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
            GPU_TOTAL_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | awk '{s+=$1} END {print s}')
            info "GPU detected: ${DETECTED_GPU_COUNT}x ${GPU_NAME} (${GPU_VRAM_MB} MB each, ${GPU_TOTAL_VRAM_MB} MB total)"
        fi
    fi

    if [ "${GPU_DETECTED}" = "false" ]; then
        warn "No NVIDIA GPU detected. Ollama will use CPU (slower)."
        warn "ComfyUI image generation will be disabled."
        COMFYUI_ENABLED="false"
    fi

    # Auto-select model based on total VRAM
    if [ "${MODEL_NAME:-auto}" = "auto" ]; then
        if [ "${GPU_TOTAL_VRAM_MB}" -ge 49152 ]; then
            MODEL_NAME="qwen2.5:72b"
        elif [ "${GPU_TOTAL_VRAM_MB}" -ge 24576 ]; then
            MODEL_NAME="qwen2.5:32b"
        elif [ "${GPU_TOTAL_VRAM_MB}" -ge 12288 ]; then
            MODEL_NAME="qwen2.5:14b"
        elif [ "${GPU_TOTAL_VRAM_MB}" -ge 6144 ]; then
            MODEL_NAME="qwen2.5:7b"
        else
            MODEL_NAME="qwen2.5:3b"
        fi
        info "Auto-selected model: ${MODEL_NAME} (based on ${GPU_TOTAL_VRAM_MB} MB VRAM)"
    fi
}

# ============================================================================
# Pre-flight checks
# ============================================================================
preflight() {
    log "Running pre-flight checks"

    [ "$(id -u)" -eq 0 ] || fail "Must run as root"

    if ! command -v apt-get &>/dev/null; then
        fail "Only Debian/Ubuntu supported. apt-get not found."
    fi

    # Check minimum RAM (8GB)
    local ram_kb
    ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    if [ "${ram_kb}" -lt 8000000 ]; then
        warn "Less than 8GB RAM detected (${ram_kb} KB). Performance may be poor."
    fi

    info "Root: yes"
    info "OS: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2)"
    info "RAM: $((ram_kb / 1024)) MB"
}

# ============================================================================
# Base packages
# ============================================================================
install_base() {
    log "Installing base packages"
    apt-get update
    apt-get upgrade -y
    apt-get install -y \
        build-essential \
        git curl wget htop tmux gnupg lsb-release \
        ca-certificates \
        python3 python3-pip python3-venv \
        sqlite3

    # QEMU guest agent (VMs only)
    if [ "${PLATFORM}" = "proxmox" ] || [ "${PLATFORM}" = "vmware" ]; then
        apt-get install -y qemu-guest-agent
        systemctl enable --now qemu-guest-agent 2>/dev/null || true
    fi
}

# ============================================================================
# NVIDIA drivers (if GPU detected but driver not installed)
# ============================================================================
install_nvidia() {
    if [ "${GPU_DETECTED}" = "false" ]; then
        info "No GPU — skipping NVIDIA driver install"
        return
    fi

    if command -v nvidia-smi &>/dev/null; then
        info "NVIDIA driver already installed: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
        return
    fi

    log "Installing NVIDIA drivers"

    # Tesla T4/L4/A100 require proprietary firmware blobs from non-free-firmware.
    # Debian 13 cloud images ship with only "main" — add contrib + non-free repos.
    if ! grep -rq 'non-free-firmware' /etc/apt/sources.list.d/ 2>/dev/null && \
       ! grep -q 'non-free-firmware' /etc/apt/sources.list 2>/dev/null; then
        info "Enabling non-free-firmware repository (required for Tesla/enterprise GPUs)"
        sed -i 's/main$/main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources 2>/dev/null || \
        sed -i 's/main$/main contrib non-free non-free-firmware/' /etc/apt/sources.list 2>/dev/null
        apt-get update
    fi

    apt-get install -y linux-headers-"$(uname -r)" dkms firmware-misc-nonfree

    # Install NVIDIA driver + CUDA from Debian repos
    apt-get install -y nvidia-driver nvidia-smi

    # CUDA runtime (strip bloat: no nsight, no dev headers, no static libs)
    apt-get install -y nvidia-cuda-toolkit
    apt-get purge -y nsight-compute nsight-compute-target \
        nsight-systems nsight-systems-target nvidia-cuda-dev libcupti-dev 2>/dev/null || true
    rm -f /usr/lib/x86_64-linux-gnu/*_static.a
    apt-mark manual libnvidia-nvvm4 nvidia-opencl-icd nvidia-driver 2>/dev/null || true
    apt-get autoremove -y

    # Blacklist nouveau
    cat > /etc/modprobe.d/blacklist-nouveau.conf << 'NOUVEAU'
blacklist nouveau
options nouveau modeset=0
NOUVEAU

    # NVIDIA persistence daemon
    systemctl enable nvidia-persistenced 2>/dev/null || true

    info "NVIDIA driver installed. A reboot may be required."
}

# ============================================================================
# Docker CE
# ============================================================================
install_docker() {
    if command -v docker &>/dev/null; then
        info "Docker already installed: $(docker --version)"
    else
        log "Installing Docker CE"

        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        local codename
        codename=$(. /etc/os-release && echo "${VERSION_CODENAME}")
        cat > /etc/apt/sources.list.d/docker.list << EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${codename} stable
EOF

        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi

    # Configure daemon.json
    local daemon_json="/etc/docker/daemon.json"
    if [ "${GPU_DETECTED}" = "true" ]; then
        log "Installing NVIDIA Container Toolkit"

        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
            gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null || true
        curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
            sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
            tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
        apt-get update
        apt-get install -y nvidia-container-toolkit

        cat > "${daemon_json}" << EOF
{
  "data-root": "${DOCKER_DATA_ROOT:-/var/lib/docker}",
  "default-runtime": "nvidia",
  "runtimes": {
    "nvidia": {
      "path": "nvidia-container-runtime",
      "runtimeArgs": []
    }
  }
}
EOF
    else
        if [ "${DOCKER_DATA_ROOT:-/var/lib/docker}" != "/var/lib/docker" ]; then
            cat > "${daemon_json}" << EOF
{
  "data-root": "${DOCKER_DATA_ROOT}"
}
EOF
        fi
    fi

    systemctl enable docker
    systemctl restart docker
}

# ============================================================================
# Ollama (native systemd — NOT in Docker)
# ============================================================================
install_ollama() {
    log "Installing Ollama"

    if command -v ollama &>/dev/null; then
        info "Ollama already installed: $(ollama --version 2>/dev/null || echo 'unknown')"
    else
        curl -fsSL https://ollama.com/install.sh | sh
    fi

    # Configure Ollama to listen on all interfaces
    local ollama_service="/etc/systemd/system/ollama.service"
    if [ -f "${ollama_service}" ]; then
        if ! grep -q "OLLAMA_HOST=0.0.0.0" "${ollama_service}"; then
            sed -i '/^\[Service\]/a Environment="OLLAMA_HOST=0.0.0.0:'"${OLLAMA_PORT}"'"' "${ollama_service}"
        fi

        # Pin GPU(s) for Ollama
        if [ "${GPU_DETECTED}" = "true" ] && [ -n "${OLLAMA_CUDA_DEVICES:-}" ]; then
            if ! grep -q "CUDA_VISIBLE_DEVICES" "${ollama_service}"; then
                sed -i '/^\[Service\]/a Environment="CUDA_VISIBLE_DEVICES='"${OLLAMA_CUDA_DEVICES}"'"' "${ollama_service}"
            fi
        fi
    fi

    systemctl daemon-reload
    systemctl enable ollama
    systemctl restart ollama

    # Wait for Ollama to come up
    info "Waiting for Ollama to start..."
    local retries=30
    while [ ${retries} -gt 0 ]; do
        if curl -sf "http://127.0.0.1:${OLLAMA_PORT}/api/tags" &>/dev/null; then
            break
        fi
        sleep 2
        retries=$((retries - 1))
    done

    if [ ${retries} -eq 0 ]; then
        warn "Ollama did not start within 60s. Check: systemctl status ollama"
    else
        info "Ollama is running on port ${OLLAMA_PORT}"
    fi

    # Pull the selected model
    log "Pulling model: ${MODEL_NAME}"
    ollama pull "${MODEL_NAME}"
}

# ============================================================================
# ComfyUI (native Python venv — NOT in Docker)
# ============================================================================
install_comfyui() {
    if [ "${COMFYUI_ENABLED:-true}" != "true" ]; then
        info "ComfyUI disabled — skipping"
        return
    fi

    log "Installing ComfyUI"

    local comfyui_dir="/opt/comfyui"
    if [ -d "${comfyui_dir}" ]; then
        info "ComfyUI already installed at ${comfyui_dir}"
    else
        git clone https://github.com/comfyanonymous/ComfyUI.git "${comfyui_dir}"
        python3 -m venv "${comfyui_dir}/venv"
        source "${comfyui_dir}/venv/bin/activate"
        pip install --upgrade pip
        pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124
        pip install -r "${comfyui_dir}/requirements.txt"
        deactivate
    fi

    # systemd service for ComfyUI
    cat > /etc/systemd/system/comfyui.service << EOF
[Unit]
Description=ComfyUI Image Generation
After=network.target

[Service]
Type=simple
WorkingDirectory=${comfyui_dir}
Environment=CUDA_VISIBLE_DEVICES=${COMFYUI_CUDA_DEVICES:-1}
ExecStart=${comfyui_dir}/venv/bin/python main.py --listen 0.0.0.0 --port ${COMFYUI_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable comfyui

    # Download FLUX.1-schnell if HF_TOKEN provided
    if [ -n "${HF_TOKEN:-}" ]; then
        log "Downloading FLUX.1-schnell models (requires HF token)"
        local models_dir="${comfyui_dir}/models"
        mkdir -p "${models_dir}/unet" "${models_dir}/clip" "${models_dir}/vae"

        # Download with auth
        curl -fSL -H "Authorization: Bearer ${HF_TOKEN}" \
            "https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/flux1-schnell.safetensors" \
            -o "${models_dir}/unet/flux1-schnell.safetensors" || warn "Failed to download FLUX.1-schnell unet"

        curl -fSL \
            "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors" \
            -o "${models_dir}/clip/t5xxl_fp8_e4m3fn.safetensors" || warn "Failed to download t5xxl"

        curl -fSL \
            "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors" \
            -o "${models_dir}/clip/clip_l.safetensors" || warn "Failed to download clip_l"

        curl -fSL \
            "https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/ae.safetensors" \
            -o "${models_dir}/vae/ae.safetensors" || warn "Failed to download VAE"
    else
        warn "No HF_TOKEN set — skipping FLUX.1-schnell model download."
        warn "Set HF_TOKEN in sovereign-node.env to enable image generation."
    fi

    systemctl start comfyui
    info "ComfyUI started on port ${COMFYUI_PORT}"
}

# ============================================================================
# Open WebUI (Docker — no GPU needed)
# ============================================================================
install_open_webui() {
    log "Installing Open WebUI"

    if docker ps -a --format '{{.Names}}' | grep -q '^open-webui$'; then
        info "Open WebUI container already exists"
        docker start open-webui 2>/dev/null || true
    else
        docker run -d \
            --name open-webui \
            --restart always \
            -p "${WEBUI_PORT}:8080" \
            -e OLLAMA_BASE_URL="http://host.docker.internal:${OLLAMA_PORT}" \
            --add-host=host.docker.internal:host-gateway \
            -v open-webui:/app/backend/data \
            ghcr.io/open-webui/open-webui:main
    fi

    info "Open WebUI running on port ${WEBUI_PORT}"
}

# ============================================================================
# Tailscale
# ============================================================================
install_tailscale() {
    log "Installing Tailscale"

    if command -v tailscale &>/dev/null; then
        info "Tailscale already installed"
    else
        curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg | \
            tee /usr/share/keyrings/tailscale-archive-keyring.gpg > /dev/null
        curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list | \
            tee /etc/apt/sources.list.d/tailscale.list
        apt-get update
        apt-get install -y tailscale
    fi

    systemctl enable tailscaled

    if [ -n "${TAILSCALE_AUTH_KEY:-}" ]; then
        tailscale up --authkey="${TAILSCALE_AUTH_KEY}" --hostname="${NODE_HOSTNAME}"
        info "Tailscale joined automatically"
    else
        info "Tailscale installed but not joined. Run: tailscale up"
    fi
}

# ============================================================================
# Cloudflare Tunnel (optional)
# ============================================================================
install_cloudflare() {
    if [ "${CLOUDFLARE_ENABLED:-false}" != "true" ]; then
        info "Cloudflare Tunnel disabled — skipping"
        return
    fi

    log "Installing Cloudflare Tunnel"

    if ! command -v cloudflared &>/dev/null; then
        curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
        dpkg -i /tmp/cloudflared.deb
        rm /tmp/cloudflared.deb
    fi

    if [ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]; then
        cloudflared service install "${CLOUDFLARE_TUNNEL_TOKEN}"
        info "Cloudflare Tunnel installed and running"
    else
        warn "CLOUDFLARE_TUNNEL_TOKEN not set. Configure manually: cloudflared tunnel login"
    fi
}

# ============================================================================
# Network — static IP
# ============================================================================
configure_network() {
    if [ "${NETWORK_MODE:-dhcp}" = "dhcp" ]; then
        info "Network: DHCP (no changes)"
        return
    fi

    log "Configuring static IP: ${IP_ADDRESS}"

    cat > /etc/network/interfaces << EOF
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

allow-hotplug ${NIC_INTERFACE}
iface ${NIC_INTERFACE} inet static
        address ${IP_ADDRESS}/24
        gateway ${GATEWAY}
        dns-nameservers ${DNS}
EOF

    info "Static IP configured. Will take effect on reboot."
}

# ============================================================================
# SSH keys
# ============================================================================
configure_ssh() {
    if [ -z "${SSH_AUTHORIZED_KEYS:-}" ] || [ "${SSH_AUTHORIZED_KEYS}" = $'\n' ]; then
        info "No SSH keys provided — skipping"
        return
    fi

    log "Configuring SSH authorized keys"

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    # Append to existing keys (don't overwrite)
    echo "${SSH_AUTHORIZED_KEYS}" >> /root/.ssh/authorized_keys
    # Deduplicate
    sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys

    info "SSH keys configured"
}

# ============================================================================
# Summary
# ============================================================================
print_summary() {
    local ip="${IP_ADDRESS:-$(hostname -I | awk '{print $1}')}"

    log "DONE — Sovereign AI Node deployed!"
    echo ""
    echo "============================================================"
    echo " ${CUSTOMER_NAME}"
    echo " Sovereign AI Node — ${NODE_HOSTNAME}"
    echo "============================================================"
    echo ""
    echo "  Platform:  ${PLATFORM}"
    echo "  GPU:       ${DETECTED_GPU_COUNT}x ${GPU_NAME:-CPU only}"
    echo "  Model:     ${MODEL_NAME}"
    echo "  License:   ${LICENSE_TIER}"
    echo ""
    echo "  Services:"
    echo "    Open WebUI (chat):     http://${ip}:${WEBUI_PORT}"
    echo "    Ollama API:            http://${ip}:${OLLAMA_PORT}"
    if [ "${COMFYUI_ENABLED:-true}" = "true" ]; then
        echo "    ComfyUI (images):      http://${ip}:${COMFYUI_PORT}"
    fi
    echo ""
    echo "  Next steps:"
    echo "    1. Open http://${ip}:${WEBUI_PORT} in your browser"
    echo "    2. Create an admin account"
    echo "    3. Select model: ${MODEL_NAME}"
    echo "    4. Start chatting — all inference is private and local"
    echo ""
    if [ -z "${TAILSCALE_AUTH_KEY:-}" ]; then
        echo "    5. Join Tailscale for remote access:"
        echo "         tailscale up"
    fi
    echo ""
    echo "  Logs: ${LOG_FILE}"
    echo ""
}

# ============================================================================
# Cloud-init cleanup (disable after first provision to prevent re-run)
# ============================================================================
finalize_cloudinit() {
    if command -v cloud-init &>/dev/null; then
        log "Disabling cloud-init (provisioning complete)"
        cloud-init clean --logs 2>/dev/null || true
        touch /etc/cloud/cloud-init.disabled
        info "cloud-init disabled. Remove /etc/cloud/cloud-init.disabled to re-enable."
    fi
}

# ============================================================================
# Main
# ============================================================================
main() {
    mkdir -p "$(dirname "${LOG_FILE}")"
    echo "=== Sovereign AI Node Install — $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" > "${LOG_FILE}"

    load_config "${1:-}"
    preflight
    detect_platform
    detect_nic
    detect_gpu

    install_base
    install_nvidia
    install_docker
    install_ollama
    install_comfyui
    install_open_webui
    install_tailscale
    install_cloudflare
    configure_network
    configure_ssh
    finalize_cloudinit
    print_summary
}

main "$@"
