#!/usr/bin/env bash
#
# LangGraph Dev VM Provisioning Script — VM 102
# Target: Debian 13 (Trixie) on Proxmox VE (Q35/OVMF, no GPUs)
#
# PREREQUISITES:
#   1. Create VM 102 on the hypervisor (run setup-langgraph-vm.sh create on the hypervisor first)
#   2. Install Debian 13 via Proxmox noVNC console:
#      - Guided partitioning → "All files in one partition"
#      - Root password: <set during Debian install>
#      - Skip non-root user creation
#      - Select SSH server only (no desktop)
#   3. After Debian install, on the hypervisor:
#        qm set 102 --delete ide2 --boot order=scsi0
#   4. Set static IP via console (if DHCP didn't assign one):
#        vi /etc/network/interfaces  (see NETWORK section below)
#        systemctl restart networking
#   5. Copy this script from the hypervisor and run as root:
#        scp /root/provision-langgraph.sh root@10.42.0.102:/root/
#        ssh root@10.42.0.102
#        chmod +x /root/provision-langgraph.sh
#        /root/provision-langgraph.sh
#
# WHAT GETS INSTALLED:
#   - Python 3.12+ with LangGraph, LangChain, langchain-openai
#   - SQLite (persistence/checkpointing for LangGraph agents)
#   - Docker CE (for tools LangGraph agents may call)
#   - Tailscale (installed, not joined)
#   - Static IP 10.42.0.102/24, SSH key auth
#
# WHAT IS NOT INSTALLED (no GPUs on this VM):
#   - No NVIDIA drivers, CUDA, nvidia-container-toolkit
#   - No Ollama, ComfyUI, Open WebUI (those live on VM 201)
#
# INFERENCE BACKEND:
#   LangGraph agents call Ollama on VM 201 (10.42.0.100:11434)
#   via the OpenAI-compatible API at http://10.42.0.100:11434/v1
#
# PURPOSE:
#   Gerald's personal agentic dev accelerator.
#   NOT part of the shipped product. Never goes to customers.
#
set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
STATIC_IP="10.42.0.102"
GATEWAY="10.42.0.1"
DNS="10.42.0.1"
INTERFACE="ens18"
OLLAMA_ENDPOINT="http://10.42.0.100:11434"
OLLAMA_MODEL="qwen2.5:14b"
LANGGRAPH_DIR="/opt/langgraph"

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
    build-essential \
    git curl wget htop tmux gnupg lsb-release \
    ca-certificates \
    python3 python3-pip python3-venv \
    sqlite3 libsqlite3-dev \
    qemu-guest-agent

systemctl enable --now qemu-guest-agent

# ============================================================================
# 2. Docker CE (for tools LangGraph agents may call)
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

systemctl enable docker
systemctl start docker

# ============================================================================
# 3. Tailscale (installed, NOT joined — run `tailscale up` after provisioning)
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
# 4. LangGraph Python environment
# ============================================================================
log "Setting up LangGraph Python environment"

mkdir -p ${LANGGRAPH_DIR}
python3 -m venv ${LANGGRAPH_DIR}/venv

# Activate venv and install packages
source ${LANGGRAPH_DIR}/venv/bin/activate

pip install --upgrade pip
pip install \
    langgraph \
    langchain \
    langchain-community \
    langchain-openai \
    langgraph-checkpoint-sqlite \
    httpx \
    pydantic

deactivate

# ============================================================================
# 5. LangGraph configuration and example agent
# ============================================================================
log "Creating LangGraph configuration"

# Environment file for LangGraph — points at local Ollama
cat > ${LANGGRAPH_DIR}/.env << EOF
# LangGraph Dev Environment
# Inference backend: Ollama on VM 201 (OpenAI-compatible API)
OPENAI_API_BASE=${OLLAMA_ENDPOINT}/v1
OPENAI_API_KEY=ollama-no-key-needed
OPENAI_MODEL_NAME=${OLLAMA_MODEL}

# SQLite checkpoint database (persistence across restarts/power cuts)
LANGGRAPH_CHECKPOINT_DB=${LANGGRAPH_DIR}/checkpoints.db

# For langchain tracing (optional, local only)
LANGCHAIN_TRACING_V2=false
EOF

# Example agent to verify the stack works
cat > ${LANGGRAPH_DIR}/test_agent.py << 'PYEOF'
"""
Minimal LangGraph agent to verify Ollama connectivity and SQLite persistence.
Run: /opt/langgraph/venv/bin/python /opt/langgraph/test_agent.py
"""
import os
import sqlite3
from dotenv import load_dotenv

load_dotenv("/opt/langgraph/.env")

from langchain_openai import ChatOpenAI
from langgraph.graph import StateGraph, START, END
from langgraph.checkpoint.sqlite import SqliteSaver
from typing import TypedDict, Annotated
from operator import add


class State(TypedDict):
    messages: Annotated[list, add]


def chat_node(state: State) -> dict:
    llm = ChatOpenAI(
        base_url=os.environ["OPENAI_API_BASE"],
        api_key=os.environ["OPENAI_API_KEY"],
        model=os.environ["OPENAI_MODEL_NAME"],
        temperature=0.7,
    )
    last_msg = state["messages"][-1]
    response = llm.invoke(last_msg)
    return {"messages": [response.content]}


# Build graph
builder = StateGraph(State)
builder.add_node("chat", chat_node)
builder.add_edge(START, "chat")
builder.add_edge("chat", END)

# SQLite persistence
db_path = os.environ.get("LANGGRAPH_CHECKPOINT_DB", "/opt/langgraph/checkpoints.db")
conn = sqlite3.connect(db_path, check_same_thread=False)

with SqliteSaver(conn) as checkpointer:
    graph = builder.compile(checkpointer=checkpointer)

    config = {"configurable": {"thread_id": "test-thread-1"}}
    result = graph.invoke(
        {"messages": ["Hello! Confirm you are running locally on Ollama. What model are you?"]},
        config=config,
    )

    print("\n=== LangGraph Test Agent ===")
    print(f"Response: {result['messages'][-1]}")
    print(f"Checkpoint DB: {db_path}")
    print(f"DB size: {os.path.getsize(db_path)} bytes")
    print("=== SUCCESS: LangGraph + Ollama + SQLite working ===\n")

conn.close()
PYEOF

# Install python-dotenv for the test agent
source ${LANGGRAPH_DIR}/venv/bin/activate
pip install python-dotenv
deactivate

# ============================================================================
# 6. Shell convenience — activate LangGraph env
# ============================================================================
log "Setting up shell convenience"

cat >> /root/.bashrc << 'EOF'

# LangGraph dev environment
alias lg='source /opt/langgraph/venv/bin/activate && cd /opt/langgraph'
alias lg-test='/opt/langgraph/venv/bin/python /opt/langgraph/test_agent.py'

# Load LangGraph env vars on login
if [ -f /opt/langgraph/.env ]; then
    set -a
    source /opt/langgraph/.env
    set +a
fi
EOF

# ============================================================================
# 7. Network — static IP
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
# 8. SSH setup
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
# 9. Final cleanup
# ============================================================================
log "Final cleanup"

apt-get clean
rm -rf /var/lib/apt/lists/*

journalctl --vacuum-time=1d
find /var/log -type f -name "*.gz" -delete
find /var/log -type f -name "*.old" -delete
find /var/log -type f -name "*.[0-9]" -delete

log "DONE — LangGraph Dev VM provisioned!"
echo ""
echo "============================================================"
echo " Next steps (run manually):"
echo "============================================================"
echo ""
echo "  1. Reboot:   shutdown -r now"
echo ""
echo "  2. SSH back in from the hypervisor:  ssh root@${STATIC_IP}"
echo ""
echo "  3. Join Tailscale (optional):"
echo "       tailscale up"
echo ""
echo "  4. Test LangGraph + Ollama connection:"
echo "       lg-test"
echo "       # or: /opt/langgraph/venv/bin/python /opt/langgraph/test_agent.py"
echo ""
echo "  5. Activate LangGraph environment:"
echo "       lg"
echo "       # Activates venv + cd /opt/langgraph"
echo ""
echo "  6. On the hypervisor — apply firewall:"
echo "       ./setup-langgraph-vm.sh firewall"
echo ""
echo "  7. Verify firewall from this VM:"
echo "       curl -sk --connect-timeout 5 https://HYPERVISOR_IP:8006"
echo "       # Should timeout (blocked)"
echo ""
echo "       curl -s http://10.42.0.100:11434/api/tags"
echo "       # Should return models (allowed)"
echo ""
echo "  LangGraph files: ${LANGGRAPH_DIR}/"
echo "  Python venv:     ${LANGGRAPH_DIR}/venv/"
echo "  Checkpoint DB:   ${LANGGRAPH_DIR}/checkpoints.db"
echo "  Config:          ${LANGGRAPH_DIR}/.env"
echo ""
