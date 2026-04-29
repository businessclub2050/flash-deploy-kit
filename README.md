# flash-deploy-kit

Modular provisioning scripts for repeatable, opinionated AI and OS deployments on bare metal and Proxmox VMs.

No Ansible, no Terraform overhead — just clean, well-documented Bash that does exactly what it says. Each script is a complete, standalone provisioner for one purpose. Copy it to a fresh VM, run it as root, walk away.

## Scripts

| Script | What It Builds |
|--------|---------------|
| `provision-ai-inference.sh` | Full AI inference VM: NVIDIA drivers, CUDA, Docker, Ollama, Open WebUI, ComfyUI on Debian 13 |
| `provision-langgraph.sh` | LangGraph agent development environment |
| `provision-nemoclaw.sh` | AI gateway node: k3s, OpenClaw, LiteLLM proxy, Langfuse observability stack |
| `provision-voice.sh` | Voice processing node: Whisper ASR, voice server |
| `setup-nemoclaw-vm.sh` | Base VM configuration for nemoclaw node |
| `setup-voice-vm.sh` | Base VM configuration for voice node |
| `create-node.sh` | Proxmox VM creation helper |
| `deploy-whisper.sh` | Whisper model deployment |

## Design Philosophy

- **One script = one purpose.** No shared state, no hidden dependencies between scripts.
- **Idempotent where possible.** Safe to re-run on a partially provisioned machine.
- **Documented inline.** Every non-obvious step has a comment explaining *why*, not just *what*.
- **Proxmox-native.** Scripts include the `qm` commands for VM creation — start from zero.

## Usage

```bash
# On a fresh Debian 13 VM with GPU passthrough:
curl -O https://raw.githubusercontent.com/businessclub2050/flash-deploy-kit/main/provision-ai-inference.sh
chmod +x provision-ai-inference.sh
bash provision-ai-inference.sh
```

## Prerequisites

- Proxmox VE 8+ (for GPU passthrough setups)
- Debian 13 (Trixie) base install — minimal, SSH only
- Root access
- For GPU nodes: IOMMU enabled, NVIDIA GPU in PCIe passthrough

## Environment Configuration

Copy `sovereign-node.env.example` to `.env` and fill in your values before running GPU or network-dependent scripts.

```bash
cp sovereign-node.env.example .env
# Edit .env with your values
source .env
bash provision-ai-inference.sh
```

## Tested On

- HPE DL380 Gen9 running Proxmox VE 9.x
- Debian 13 Trixie (amd64)
- NVIDIA Tesla T4 (x2)
- Docker CE 29.x · k3s · Ollama 0.19+

## License

MIT
